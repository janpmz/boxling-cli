import CoreFoundation
import Darwin
import Foundation

private let packageOwnerFile = helperDirectory + "/package-install-owner"

func isGraphicalPackageInstall(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PACKAGE_PATH"] != nil && environment["COMMAND_LINE_INSTALL"] == nil
}

struct PackageUpdateError: Error, CustomStringConvertible {
    let title: String
    let message: String
    var description: String { title + "\n" + message }

    func notifyInstallerUser(environment: [String: String] = ProcessInfo.processInfo.environment,
                             display: (String, String) -> Void = { title, message in
        CFUserNotificationDisplayNotice(0, CFOptionFlags(kCFUserNotificationCautionAlertLevel),
            nil, nil, nil, title as CFString, message as CFString, "OK" as CFString)
    }) {
        // Installer's failure summary is generic. Send a separate notice without
        // waiting for dismissal or interrupting command-line installations.
        guard isGraphicalPackageInstall(environment) else { return }
        display(title, message)
    }
}

func readPackageFile(_ path: String, mode: mode_t) throws -> Data {
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_uid == 0,
          metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o7777 == mode,
          metadata.st_nlink == 1, metadata.st_size <= 65536 else {
        throw BoxError("Unexpected owner, permissions, or file type at \(path). Installation stopped.")
    }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

func packageCommand(_ executable: String, _ arguments: [String]) throws -> ServiceCommandResult {
    do { return try serviceCommand(executable, arguments, timeout: 30) }
    catch is ServiceTimeout { throw BoxError("Installer timed out running \(executable). Stop Boxling and my-container before retrying.") }
}

func selectPackageOwner(existing: uid_t?, console: uid_t?) throws -> uid_t {
    func ordinary(_ uid: uid_t) -> Bool { uid >= 500 && uid < 65534 }
    if let existing {
        guard ordinary(existing), console == nil || console == existing else {
            throw BoxError("Install Boxling from the Mac account that already owns its boxes.")
        }
        return existing
    }
    guard let console, ordinary(console) else {
        throw BoxError("Sign in to your Mac account before installing Boxling.")
    }
    return console
}

func requirePackageStartupDisk(_ target: String) throws {
    guard target.hasPrefix("/"), URL(fileURLWithPath: target).standardizedFileURL.path == "/" else {
        throw BoxError("Install Boxling on the current startup disk.")
    }
}

func requirePackageTarget(_ target: String) throws {
    guard geteuid() == 0 else { throw BoxError("The Boxling package must be run by macOS Installer with administrator authentication.") }
    try requirePackageStartupDisk(target)
    #if !arch(arm64)
    throw BoxError("This Boxling package requires an Apple silicon Mac.")
    #endif
    guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
        throw BoxError("This Boxling package requires macOS 26 or later.")
    }
}

private func verifyExistingPackagePaths() throws {
    // Installer may create missing directories, but never follow a pre-existing
    // symlink into a user's writable directory when installing root helpers.
    for path in ["/Library", "/Library/Application Support", "/Library/Application Support/MyBox", forkInstallRoot,
                 "/Library/PrivilegedHelperTools", helperDirectory,
                 forkInstallRoot + "/bin", forkInstallRoot + "/bin/container"] {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else { throw systemError("Cannot inspect \(path)") }
            continue
        }
        guard metadata.st_uid == 0, metadata.st_mode & S_IFMT != S_IFLNK, metadata.st_mode & 0o022 == 0 else {
            throw BoxError("Unexpected ownership or permissions on \(path). Installation stopped.")
        }
    }
}

private func packageOwner() throws -> uid_t {
    var consoleInfo = stat()
    guard stat("/dev/console", &consoleInfo) == 0 else { throw systemError("Cannot identify the signed-in Mac account") }
    let console: uid_t? = consoleInfo.st_uid >= 500 && consoleInfo.st_uid < 65534 ? consoleInfo.st_uid : nil
    let ownerPath = helperDirectory + "/owner"
    var existing: uid_t?
    if FileManager.default.fileExists(atPath: ownerPath) {
        let data = try readPackageFile(ownerPath, mode: 0o644)
        guard let value = UInt32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BoxError("The existing Boxling installation has an invalid owner.")
        }
        existing = value
    }
    let owner = try selectPackageOwner(existing: existing, console: console)
    guard getpwuid(owner) != nil else { throw BoxError("The Boxling owner account no longer exists.") }
    return owner
}

func requirePersonalForksStopped(_ users: [uid_t], command: InstallCommand = packageCommand) throws {
    for uid in Set(users).sorted() {
        for domain in ["gui/\(uid)", "user/\(uid)"] {
            if try command("/bin/launchctl", ["print", domain + "/" + forkServicePrefix + "apiserver"]).status == 0 {
                throw BoxError("Run my-container system stop in Mac account \(uid) before installing Boxling. Apple's container may keep running.")
            }
        }
    }
}

private func activePackageBoxNames(_ runtimeArguments: [String], command: InstallCommand) throws -> [String] {
    let listing = try checkedInstallCommand("/bin/launchctl", runtimeArguments + ["list", "--all", "--format", "json"], command: command)
    guard let containers = try JSONSerialization.jsonObject(with: listing.output) as? [[String: Any]] else {
        throw BoxError("The installer could not read the state of your Boxling boxes.")
    }
    var names: [String] = []
    for container in containers {
        let state = (container["status"] as? [String: Any])?["state"] as? String
        if state == "stopped" { continue }
        guard let state, ["running", "starting", "stopping"].contains(state),
              let id = container["id"] as? String, let configuration = container["configuration"] as? [String: Any],
              let name = managedBoxName(id: id, configuration: configuration) else {
            throw PackageUpdateError(title: "Boxling could not identify every active box",
                message: "Check the containers in the private Boxling runtime. Stop any that are still active, then retry.")
        }
        names.append(name)
    }
    return names.sorted()
}

func confirmInstallerBoxStop(_ names: [String]) -> Bool {
    let message = "Stopping these boxes will interrupt their sites, terminals, and running jobs. Boxling will keep their files and settings.\n\n"
        + names.joined(separator: "\n")
    var response = CFOptionFlags(kCFUserNotificationCancelResponse)
    let status = CFUserNotificationDisplayAlert(300, CFOptionFlags(kCFUserNotificationCautionAlertLevel),
        nil, nil, nil, "Stop these boxes and install Boxling?" as CFString, message as CFString,
        "Cancel" as CFString, "Stop Boxes and Install" as CFString, nil, &response)
    return status == 0 && response == CFOptionFlags(kCFUserNotificationAlternateResponse)
}

// Use the normal owner's stop operation, including Boxling's per-box approval
// and network cleanup. This works even when the desktop app has been removed.
func stopPackageBoxes(_ names: [String], owner: uid_t, confirm: ([String]) -> Bool,
                      command: InstallCommand = { try serviceCommand($0, $1, timeout: 300) }) throws {
    guard confirm(names) else { throw BoxError("Canceled before stopping any boxes.") }
    // Installer's temporary directory can be accessible only to root.
    let client = ["asuser", String(owner), "/usr/bin/sudo", "-n", "-H", "-u", "#\(owner)", "--", "/usr/bin/env", "-u", "TMPDIR",
                  helperDirectory + "/mybox-service", "client", "stop"]
    for name in names {
        do {
            try checkedInstallCommand("/bin/launchctl", client + [name], command: command)
        } catch {
            note(String(describing: error))
            throw PackageUpdateError(title: "Boxling could not finish stopping \(name)",
                message: "Check the box status with boxling list in Terminal, then retry. Any boxes already stopped will stay stopped.")
        }
    }
}

// The second check, after the broker closes, always runs without a stop action.
func checkPackageRuntimeCanStop(_ uid: uid_t, command: InstallCommand = packageCommand,
                                expectedDataRoot: String = privateServiceHome + "/Library/Application Support/com.apple.container",
                                stopActiveBoxes: (([String]) throws -> Void)? = nil) throws -> Bool {
    if try command("/bin/launchctl", ["print", "user/\(uid)/com.apple.container.apiserver"]).status == 0 {
        throw BoxError("Migrate the older shared Boxling runtime before using this package.")
    }
    guard try command("/bin/launchctl", ["print", "user/\(uid)/" + forkServicePrefix + "apiserver"]).status == 0 else { return false }
    let prefix = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)", "--", forkInstallRoot + "/bin/container"]
    let health = try checkedInstallCommand("/bin/launchctl", prefix + ["system", "status", "--format", "json"], command: command)
    guard let metadata = try JSONSerialization.jsonObject(with: health.output) as? [String: Any],
          metadata["status"] as? String == "running", let paths = metadata["paths"] as? [String: String],
          let root = paths["appRoot"], let install = paths["installRoot"],
          URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: expectedDataRoot).resolvingSymlinksInPath().standardizedFileURL.path,
          URL(fileURLWithPath: install).standardizedFileURL.path == forkInstallRoot else {
        throw BoxError("The private Boxling runtime reports unexpected paths. Installation stopped.")
    }
    var names = try activePackageBoxNames(prefix, command: command)
    if !names.isEmpty, let stopActiveBoxes {
        try stopActiveBoxes(names)
        names = try activePackageBoxNames(prefix, command: command)
    }
    if !names.isEmpty {
        throw PackageUpdateError(title: "Stop all boxes before updating Boxling",
            message: "In Terminal, stop each box below, then retry. Use boxling stop on a Boxling installation or mybox stop on an older installation.\n\nBoxes to stop\n" + names.joined(separator: "\n"))
    }
    return true
}

func stopPackageRuntime(_ uid: uid_t) throws {
    let service = "user/\(uid)/io.github.janpmz.my-container-box.service"
    let bootstrap = "system/io.github.janpmz.my-container-box.bootstrap"
    do {
        for job in [bootstrap, service] {
            if try packageCommand("/bin/launchctl", ["print", job]).status == 0 {
                try checkedInstallCommand("/bin/launchctl", ["bootout", job], command: packageCommand)
            }
        }
        // Recheck after closing the broker so new commands cannot race with
        // replacing the runtime. Never ask the runtime to stop running boxes.
        if try checkPackageRuntimeCanStop(uid) {
            let prefix = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)", "--", forkInstallRoot + "/bin/container"]
            try checkedInstallCommand("/bin/launchctl", prefix + ["system", "stop"], command: packageCommand)
            guard try packageCommand("/bin/launchctl", ["print", "user/\(uid)/" + forkServicePrefix + "apiserver"]).status != 0 else {
                throw BoxError("The private runtime did not stop. Installation stopped before replacing files.")
            }
        }
    } catch {
        _ = try? packageCommand("/bin/launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/io.github.janpmz.my-container-box.bootstrap.plist"])
        throw error
    }
}

func preparePackageInstallation(target: String, confirmBoxStop: (([String]) -> Bool)? = nil) throws {
    try requirePackageTarget(target)
    try verifyExistingPackagePaths()
    let owner = try packageOwner()
    let app = try packageCommand("/usr/bin/pgrep", ["-x", "Boxling|MyBox"])
    if app.status == 0 {
        throw PackageUpdateError(title: "Quit Boxling before updating",
            message: "Quit the Boxling desktop app and reopen this installer.")
    }
    guard app.status == 1 else { throw BoxError("The installer could not check whether Boxling is open.") }
    let users = serviceAccounts().map(\.1).filter { $0 >= 500 && $0 < 65534 }
    try requirePersonalForksStopped(users)

    let identity = try savedServiceIdentity()
    if let identity {
        _ = try serviceNameChanges(identity)
        _ = try checkPackageRuntimeCanStop(identity.number, stopActiveBoxes: confirmBoxStop.map { confirm in
            { names in try stopPackageBoxes(names, owner: owner, confirm: confirm) }
        })
    }

    // This shared system directory may have the sticky bit. Keep that extra
    // deletion protection; Boxling's own directories still require exact modes.
    try installDirectory("/Library/PrivilegedHelperTools", uid: 0, gid: 0, mode: 0o755, allowStickyBit: true)
    try installDirectory(helperDirectory, uid: 0, gid: 0, mode: 0o755)
    try storeInstalledFile(packageOwnerFile, content: Data("\(owner)\n".utf8), mode: 0o600)
    if let identity { try stopPackageRuntime(identity.number) }
    print("Boxling package checks passed. Existing box data will be preserved.")
}

func finishPackageInstallation(target: String, artifactDirectory: String) throws {
    try requirePackageTarget(target)
    try verifyExistingPackagePaths()
    let data = try readPackageFile(packageOwnerFile, mode: 0o600)
    guard let owner = UInt32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          owner >= 500, owner < 65534, getpwuid(owner) != nil else { throw BoxError("The package did not prepare a valid Boxling owner.") }
    try installBoxlingService(artifactDirectory: artifactDirectory, packageOwner: owner, reloadServices: true)
    guard unlink(packageOwnerFile) == 0 else { throw systemError("Cannot finish package setup") }
    print("Boxling is installed. Open /Applications/Boxling.app or run boxling help.")
}
