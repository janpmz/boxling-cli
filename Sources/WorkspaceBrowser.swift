import Foundation

// This worker serves one box, for the lifetime of one approved connection.
// Request paths are always /workspace paths; host paths never come from requests.
private let browserDirectoryCheck = """
set -eu
cd -P -- "$1"
if [ "$PWD" != "$1" ]; then
    printf '%s\n' 'Choose a real folder inside /workspace, not a symlink.' >&2
    exit 1
fi
"""

func browserList(_ path: String, id: String, backend: Backend) throws -> [WorkspaceFileEntry] {
    let path = try WorkspacePaths.absolute(path)
    let script = browserDirectoryCheck + "\nexec find . -mindepth 1 -maxdepth 1 -printf '%f\\0%y\\0%s\\0%T@\\0%m\\0'"
    let data = try backend.run(["exec", id, "/bin/sh", "-c", script, "mybox-files", path], capture: true, inheritInput: false)
    guard data.count < WorkspaceFileStream.maximumMessageBytes / 2,
          let listing = String(data: data, encoding: .utf8) else {
        throw WorkspaceFileError("This folder is too large to display, or contains names that are not valid UTF-8.")
    }
    if listing.isEmpty { return [] }
    let values = listing.split(separator: "\0", omittingEmptySubsequences: false)
    guard values.last == "", (values.count - 1) % 5 == 0 else { throw WorkspaceFileError("Cannot read the folder listing.") }
    return try stride(from: 0, to: values.count - 1, by: 5).map { index in
        let name = try WorkspacePaths.name(String(values[index]))
        guard let bytes = Int64(values[index + 2]), bytes >= 0,
              let modified = Double(values[index + 3]), modified.isFinite,
              let mode = Int(values[index + 4], radix: 8) else { throw WorkspaceFileError("Invalid file metadata.") }
        let kind = values[index + 1] == "d" ? "folder" : values[index + 1] == "f" ? "file" : values[index + 1] == "l" ? "link" : "other"
        return WorkspaceFileEntry(path: path + "/" + name, kind: kind, bytes: bytes, modified: modified, permissions: mode & 0o777)
    }
}

private func browserUpload(_ source: URL, name: String, directory: String, id: String, backend: Backend) throws {
    let check = browserDirectoryCheck + """

    if [ -e "$2" ] || [ -L "$2" ]; then
        printf '%s\n' 'An item with this name already exists. Nothing was replaced.' >&2
        exit 1
    fi
    """
    _ = try backend.run(["exec", id, "/bin/sh", "-c", check, "mybox-files", directory, name], capture: true, inheritInput: false)
    let temporary = "/tmp/mybox-files-" + UUID().uuidString
    _ = try backend.run(["exec", id, "/bin/mkdir", "-m", "700", "--", temporary], capture: true, inheritInput: false)
    defer { _ = try? backend.run(["exec", id, "/bin/rm", "-rf", "--", temporary], capture: true, inheritInput: false) }
    _ = try backend.run(["cp", source.path, id + ":" + temporary + "/payload"], capture: true, inheritInput: false)
    let move = check + """

    mv -T --no-clobber -- "$3" "$2"
    if [ -e "$3" ] || [ -L "$3" ]; then
        printf '%s\n' 'An item with this name already exists. Nothing was replaced.' >&2
        exit 1
    fi
    """
    _ = try backend.run(["exec", id, "/bin/sh", "-c", move, "mybox-files", directory, name, temporary + "/payload"], capture: true, inheritInput: false)
}

private func browserDelete(_ value: String, id: String, backend: Backend) throws {
    let path = try WorkspacePaths.absolute(value)
    guard path != "/workspace" else { throw WorkspaceFileError("The workspace folder itself cannot be deleted.") }
    let parent = (path as NSString).deletingLastPathComponent
    let name = try WorkspacePaths.name((path as NSString).lastPathComponent)
    // Anchor the operation to the physical parent directory. rm unlinks a
    // selected symlink rather than following it, and won't cross mount points.
    // Foundation Process normalizes Unicode arguments on macOS. Transport
    // UTF-8 as ASCII octal escapes so Linux receives the exact selected name.
    func encoded(_ argument: String) -> String {
        argument.utf8.map { String(format: "\\0%03o", Int($0)) }.joined()
    }
    let decode = """
    mybox_delete_parent=$(printf '%b.' "$1")
    mybox_delete_name=$(printf '%b.' "$2")
    set -- "${mybox_delete_parent%.}" "${mybox_delete_name%.}"

    """
    let script = decode + browserDirectoryCheck + """

    if [ ! -e "./$2" ] && [ ! -L "./$2" ]; then
        printf '%s\\n' 'This item no longer exists. Refresh the folder.' >&2
        exit 1
    fi
    exec /bin/rm -r --one-file-system --preserve-root=all -- "./$2"
    """
    _ = try backend.run(["exec", id, "/bin/sh", "-c", script, "mybox-files-delete", encoded(parent), encoded(name)], capture: true, inheritInput: false)
}

private func browserCreateFolder(_ value: String, id: String, backend: Backend) throws {
    let path = try WorkspacePaths.absolute(value)
    guard path != "/workspace" else { throw WorkspaceFileError("Choose a new folder inside /workspace.") }
    let parent = (path as NSString).deletingLastPathComponent
    let name = try WorkspacePaths.name((path as NSString).lastPathComponent)
    func encoded(_ argument: String) -> String {
        argument.utf8.map { String(format: "\\0%03o", Int($0)) }.joined()
    }
    let decode = #"""
    mybox_folder_parent=$(printf '%b.' "$1")
    mybox_folder_name=$(printf '%b.' "$2")
    set -- "${mybox_folder_parent%.}" "${mybox_folder_name%.}"

    """#
    let script = decode + browserDirectoryCheck + #"""

    if [ -e "./$2" ] || [ -L "./$2" ]; then
        echo 'An item already exists at this path. Choose another folder name.' >&2
        exit 1
    fi
    # No -p: an existing destination, including one created after the check,
    # must fail. The physical parent check rejects paths through symlinks.
    exec /bin/mkdir -- "./$2"
    """#
    _ = try backend.run(["exec", id, "/bin/sh", "-c", script, "mybox-files-create-folder", encoded(parent), encoded(name)], capture: true, inheritInput: false)
}

func browseWorkspace(_ box: String, backend: Backend) throws {
    _ = try containerID(box)
    try approveBoxAccess("files", box: box, arguments: [])
    let id = try backend.ready(box)
    backend.includesCommandDiagnostics = true
    let stream = WorkspaceFileStream(input: STDIN_FILENO, output: STDOUT_FILENO)
    try stream.send(.init(kind: "ready", version: 1))
    while let request = try stream.receive() {
        // An incomplete byte stream cannot be resumed safely. Only errors before
        // a transfer starts (or after it finishes) leave the session reusable.
        var transferring = false
        do {
            guard let value = request.path else { throw WorkspaceFileError("Missing workspace path.") }
            let path = try WorkspacePaths.absolute(value)
            switch request.kind {
            case "createFolder":
                try browserCreateFolder(path, id: id, backend: backend)
                try stream.send(.init(kind: "done", path: path))
            case "readText":
                let snapshot = try readWorkspaceText(path, id: id, backend: backend)
                try stream.send(.init(kind: "text", path: path, text: snapshot.text, revision: snapshot.revision, writable: snapshot.writable))
            case "saveText":
                guard let text = request.text, let revision = request.revision else { throw WorkspaceFileError("Missing text or file version.") }
                let saved = try saveWorkspaceText(path, text: text, revision: revision, id: id, backend: backend)
                try stream.send(.init(kind: saved.saved ? "savedText" : "textConflict", path: path, text: saved.snapshot.text,
                    revision: saved.snapshot.revision, writable: saved.snapshot.writable, recoveryPath: saved.recoveryPath))
            case "list":
                try stream.send(.init(kind: "listing", path: path, entries: browserList(path, id: id, backend: backend)))
            case "delete":
                try browserDelete(path, id: id, backend: backend)
                try stream.send(.init(kind: "done"))
            case "upload":
                guard let names = request.names, names.count == 1 else { throw WorkspaceFileError("Choose one upload at a time.") }
                let name = try WorkspacePaths.name(names[0])
                let existing = try browserList(path, id: id, backend: backend)
                guard !existing.contains(where: { ($0.path as NSString).lastPathComponent == name }) else {
                    throw WorkspaceFileError("\(name.debugDescription) already exists in \(path). Nothing was replaced.")
                }
                let temporary = try TemporaryFolder()
                defer { withExtendedLifetime(temporary) {} }
                try stream.send(.init(kind: "accept"))
                transferring = true
                let (payload, skipped) = try WorkspaceFileTransfer.receive(from: stream, into: temporary.url)
                transferring = false
                try browserUpload(payload, name: name, directory: path, id: id, backend: backend)
                try stream.send(.init(kind: "done", skipped: skipped))
            case "download":
                let temporary = try TemporaryFolder()
                defer { withExtendedLifetime(temporary) {} }
                let payload = temporary.url.appendingPathComponent("payload")
                try exportFiles(box, path: path, destination: payload, backend: backend, readyID: id)
                try stream.send(.init(kind: "accept"))
                transferring = true
                _ = try WorkspaceFileTransfer.send(payload, to: stream, skipLinks: false)
                transferring = false
            default: throw WorkspaceFileError("Unsupported file-browser operation.")
            }
        } catch {
            if transferring { throw error }
            let description = error is CommandFailed ? "The box could not complete this file operation. The folder may have changed or may not be accessible." : String(describing: error)
            try stream.send(.init(kind: "error", message: description))
        }
    }
}
