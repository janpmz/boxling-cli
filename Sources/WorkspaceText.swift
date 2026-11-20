import Foundation

// The guest uses only the Debian tools already required by Boxling. Document
// contents travel through the file protocol and a private transfer, never argv.
private let textPathSetup = #"""
set -eu
mybox_parent=$(printf '%b.' "$1")
mybox_name=$(printf '%b.' "$2")
mybox_parent=${mybox_parent%.}
mybox_name=${mybox_name%.}
cd -P -- "$mybox_parent"
[ "$PWD" = "$mybox_parent" ] || { echo 'Choose a real folder inside /workspace, not a symlink.' >&2; exit 1; }
mybox_target=./$mybox_name
[ ! -L "$mybox_target" ] || { echo 'The editor does not follow symbolic links.' >&2; exit 1; }
if [ -e "$mybox_target" ] && [ ! -f "$mybox_target" ]; then
    echo 'Choose a regular text file.' >&2; exit 1
fi
"""#

private func textPathArguments(_ value: String) throws -> [String] {
    let path = try WorkspacePaths.absolute(value)
    guard path != "/workspace" else { throw WorkspaceFileError("Choose a file inside /workspace.") }
    let name = try WorkspacePaths.name((path as NSString).lastPathComponent)
    return [(path as NSString).deletingLastPathComponent, name].map {
        $0.utf8.map { String(format: "\\0%03o", Int($0)) }.joined()
    }
}

func readWorkspaceText(_ path: String, id: String, backend: Backend) throws -> WorkspaceTextSnapshot {
    let script = textPathSetup + #"""

if [ ! -e "$mybox_target" ]; then printf 'missing\n'; exit 0; fi
# Compare metadata before and after the bounded read. A writer still updating
# the file causes a retry on the next poll instead of publishing a partial read.
mybox_before=$(stat -c '%d:%i:%s:%y:%z' -- "$mybox_target")
mybox_copy=$(mktemp /tmp/mybox-text-read.XXXXXXXXXX)
trap 'rm -f -- "$mybox_copy"' EXIT
head -c 1048577 -- "$mybox_target" > "$mybox_copy"
mybox_after=$(stat -c '%d:%i:%s:%y:%z' -- "$mybox_target")
[ "$mybox_before" = "$mybox_after" ] || { echo 'The file is changing. Retry when the writer finishes.' >&2; exit 1; }
if [ -w "$mybox_target" ]; then printf 'writable\n'; else printf 'readonly\n'; fi
cat -- "$mybox_copy"
"""#
    let data = try backend.run(["exec", id, "/bin/sh", "-c", script, "mybox-text-read"] + textPathArguments(path), capture: true, inheritInput: false)
    guard let separator = data.firstIndex(of: 10),
          let header = String(data: data.prefix(upTo: separator), encoding: .utf8) else {
        throw WorkspaceFileError("Invalid text-file response.")
    }
    if header == "missing" { return .init(text: "", revision: "missing", writable: true) }
    let bytes = Data(data.suffix(from: data.index(after: separator)))
    guard let text = String(data: bytes, encoding: .utf8) else { throw WorkspaceFileError("The editor supports UTF-8 text files. This file uses a different encoding or contains binary data.") }
    try WorkspaceTextSnapshot.validate(text)
    guard ["writable", "readonly"].contains(header) else { throw WorkspaceFileError("Invalid text-file response.") }
    return .init(text: text, revision: WorkspaceTextSnapshot.digest(bytes), writable: header == "writable")
}

func saveWorkspaceText(_ path: String, text: String, revision: String, id: String, backend: Backend) throws -> WorkspaceTextSave {
    let arguments = try textPathArguments(path)
    try WorkspaceTextSnapshot.validate(text)
    guard revision == "missing" || (revision.count == 64 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }) else {
        throw WorkspaceFileError("Invalid text-file version. Reopen the file before saving.")
    }
    let temporary = try TemporaryFolder()
    let payload = temporary.url.appendingPathComponent("text")
    try Data(text.utf8).write(to: payload)
    let token = UUID().uuidString
    let recoveryKey = WorkspaceTextSnapshot.digest(Data(path.utf8))
    let guest = "/tmp/mybox-text-" + token
    _ = try backend.run(["exec", id, "/bin/mkdir", "-m", "700", "--", guest], capture: true, inheritInput: false)
    defer { _ = try? backend.run(["exec", id, "/bin/rm", "-rf", "--", guest], capture: true, inheritInput: false) }
    _ = try backend.run(["cp", payload.path, id + ":" + guest + "/text"], capture: true, inheritInput: false)
    let script = textPathSetup + #"""

# Lock the directory inode, so all Boxling editors serialize their checked saves
# without leaving lock files or depending on a replaceable target inode.
exec 9< .
flock -x 9
mybox_revision=$3
mybox_payload=$4
mybox_recovery=./.mybox-recovery-$5
mybox_staging=$(mktemp ./.mybox-edit.XXXXXXXXXX)
mybox_backup=$(mktemp ./.mybox-backup.XXXXXXXXXX)
trap 'rm -f -- "$mybox_staging" "$mybox_backup"' EXIT
cat -- "$mybox_payload" > "$mybox_staging"
if [ "$mybox_revision" = missing ]; then
    # Hard-link publication fails if another writer created the destination.
    chmod 644 -- "$mybox_staging"
    if ln -T -- "$mybox_staging" "$mybox_target" 2>/dev/null; then printf 'saved\n'; else printf 'conflict\n'; fi
    exit 0
fi
if [ ! -f "$mybox_target" ] || [ -L "$mybox_target" ]; then printf 'conflict\n'; exit 0; fi
mybox_actual=$(sha256sum < "$mybox_target")
mybox_actual=${mybox_actual%% *}
if [ "$mybox_actual" != "$mybox_revision" ]; then printf 'conflict\n'; exit 0; fi
[ -w "$mybox_target" ] || { echo 'This file is read-only.' >&2; exit 1; }
# Keep an independent recovery copy and recheck after copying. The replacement
# is atomic. Non-cooperating writers do not honor flock; see the editor guide.
cp -p -- "$mybox_target" "$mybox_backup"
chmod --reference="$mybox_target" -- "$mybox_staging"
mybox_copy_hash=$(sha256sum < "$mybox_backup")
mybox_copy_hash=${mybox_copy_hash%% *}
if [ "$mybox_copy_hash" != "$mybox_revision" ] || ! cmp -s -- "$mybox_target" "$mybox_backup" || [ -L "$mybox_target" ]; then
    printf 'conflict\n'; exit 0
fi
# Retain one previous version per path, replacing recovery files atomically.
mv -T -- "$mybox_backup" "$mybox_recovery"
if ! cmp -s -- "$mybox_target" "$mybox_recovery" || [ -L "$mybox_target" ]; then printf 'conflict\n'; exit 0; fi
mv -T -- "$mybox_staging" "$mybox_target"
printf 'saved\n'
"""#
    let output = try backend.run(["exec", id, "/bin/sh", "-c", script, "mybox-text-save"] + arguments + [revision, guest + "/text", recoveryKey], capture: true, inheritInput: false)
    let result = String(data: output, encoding: .utf8)
    guard result == "saved\n" || result == "conflict\n" else { throw WorkspaceFileError("Invalid editor save response from the box.") }
    guard result == "saved\n" else {
        return .init(saved: false, snapshot: try readWorkspaceText(path, id: id, backend: backend), recoveryPath: nil)
    }
    let recovery = revision == "missing" ? nil : (path as NSString).deletingLastPathComponent + "/.mybox-recovery-" + recoveryKey
    return .init(saved: true, snapshot: .init(text: text, revision: WorkspaceTextSnapshot.digest(Data(text.utf8)), writable: true), recoveryPath: recovery)
}
