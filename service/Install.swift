import Darwin
import Foundation

struct ServiceIdentity: Codable { let number: UInt32; let user: String; let group: String }
struct ServiceAccountRecord { let uid: uid_t; let gid: gid_t; let home: String }
typealias InstallCommand = (String, [String]) throws -> ServiceCommandResult

func runInstallCommand(_ executable: String, _ arguments: [String]) throws -> ServiceCommandResult {
    try serviceCommand(executable, arguments)
}

@discardableResult
func checkedInstallCommand(_ executable: String, _ arguments: [String], command: InstallCommand = runInstallCommand) throws -> ServiceCommandResult {
    let result = try command(executable, arguments)
    guard result.status == 0 else {
        let detail = result.error.isEmpty ? result.output : result.error
        throw BoxError("\(executable) \(arguments.joined(separator: " ")) failed. \(String(decoding: detail, as: UTF8.self))")
    }
    return result
}

func serviceAccounts() -> [(String, UInt32)] {
    var values: [(String, UInt32)] = []
    setpwent(); defer { endpwent() }
    while let entry = getpwent() { values.append((String(cString: entry.pointee.pw_name), entry.pointee.pw_uid)) }
    setgrent(); defer { endgrent() }
    while let entry = getgrent() { values.append((String(cString: entry.pointee.gr_name), entry.pointee.gr_gid)) }
    return values
}

func checkServiceID(_ number: UInt32, accounts: [(String, UInt32)] = serviceAccounts()) throws {
    guard (300...499).contains(number), !accounts.contains(where: {
        $0.1 == number && $0.0 != privateServiceAccount && $0.0 != legacyPrivateServiceAccount
    }) else {
        throw BoxError("The service ID \(number) is invalid or already in use by another account or group.")
    }
}

func installedAccountRecord() throws -> ServiceAccountRecord {
    guard let entry = getpwnam(privateServiceAccount) else { throw BoxError("The private Boxling account was not created.") }
    return ServiceAccountRecord(uid: entry.pointee.pw_uid, gid: entry.pointee.pw_gid, home: String(cString: entry.pointee.pw_dir))
}

private func serviceRecords(_ identity: ServiceIdentity) -> [(String, String, [(String, String)])] {
    let number = String(identity.number)
    return [
        ("Groups", identity.group, [("PrimaryGroupID", number), ("RealName", "Boxling service group")]),
        ("Users", identity.user, [("UniqueID", number), ("PrimaryGroupID", number), ("RealName", "Boxling service"),
          ("NFSHomeDirectory", privateServiceHome), ("UserShell", "/usr/bin/false"), ("IsHidden", "1"), ("Password", "*")])]
}

private func serviceRecordExists(_ path: String, uuid: String, command: InstallCommand) throws -> Bool {
    let record = try command("/usr/bin/dscl", [".", "-read", path, "GeneratedUID"])
    if record.status == 0 {
        guard String(decoding: record.output, as: UTF8.self).split(whereSeparator: \.isWhitespace).last?.lowercased() == uuid.lowercased() else {
            throw BoxError("The existing \(path) belongs to another installation.")
        }
        return true
    }
    guard String(decoding: record.output + record.error, as: UTF8.self).contains("eDSRecordNotFound") else {
        throw BoxError("Cannot check the directory record \(path).")
    }
    return false
}

private func serviceRecordValues(_ record: ServiceCommandResult, attribute: String) -> [String] {
    let prefix = attribute + ": "
    return String(decoding: record.output, as: UTF8.self).components(separatedBy: .newlines).compactMap { line in
        guard let range = line.range(of: prefix) else { return nil }
        return String(line[range.upperBound...])
    }
}

func serviceNameChanges(_ identity: ServiceIdentity, command: InstallCommand = runInstallCommand) throws -> [String] {
    var paths: [String] = []
    for (kind, uuid, attributes) in serviceRecords(identity) {
        let old = "/\(kind)/\(legacyPrivateServiceAccount)"
        let new = "/\(kind)/\(privateServiceAccount)"
        let newExists = try serviceRecordExists(new, uuid: uuid, command: command)
        guard try serviceRecordExists(old, uuid: uuid, command: command) else { continue }
        guard !newExists else { throw BoxError("Both \(old) and \(new) exist. Boxling could not determine which record to rename.") }
        let expected = [("RecordName", legacyPrivateServiceAccount)] + attributes.filter { !["Password", "RealName"].contains($0.0) }
        for (attribute, value) in expected {
            let record = try checkedInstallCommand("/usr/bin/dscl", [".", "-read", old, attribute], command: command)
            guard serviceRecordValues(record, attribute: attribute) == [value] else {
                throw BoxError("The existing \(old) has an unexpected \(attribute).")
            }
        }
        paths.append(old)
    }
    return paths
}

func renameServiceRecords(_ paths: [String], command: InstallCommand = runInstallCommand) throws {
    for path in paths {
        try checkedInstallCommand("/usr/bin/dscl", [".", "-change", path, "RecordName", legacyPrivateServiceAccount, privateServiceAccount], command: command)
    }
}

func configureServiceIdentity(_ identity: ServiceIdentity, command: InstallCommand = runInstallCommand,
                              checkID: (UInt32) throws -> Void = { try checkServiceID($0) },
                              lookup: () throws -> ServiceAccountRecord = installedAccountRecord) throws -> UInt32 {
    try checkID(identity.number)
    guard UUID(uuidString: identity.user) != nil, UUID(uuidString: identity.group) != nil else { throw BoxError("Invalid service account identity.") }
    for (kind, uuid, attributes) in serviceRecords(identity) {
        let path = "/\(kind)/\(privateServiceAccount)"
        let existing = try serviceRecordExists(path, uuid: uuid, command: command)
        if !existing {
            try checkedInstallCommand("/usr/bin/dscl", [".", "-create", path, "GeneratedUID", uuid], command: command)
        }
        for (attribute, value) in attributes {
            if existing {
                // Never reset an existing account's password on reinstall.
                if ["Password", "RealName"].contains(attribute) { continue }
                let current = try command("/usr/bin/dscl", [".", "-read", path, attribute])
                let found = serviceRecordValues(current, attribute: attribute)
                if found == [value] { continue }
                guard found.isEmpty, current.status == 0 || String(decoding: current.output + current.error, as: UTF8.self).contains("eDSAttributeNotFound") else { throw BoxError("The existing \(path) has an unexpected \(attribute).") }
            }
            try checkedInstallCommand("/usr/bin/dscl", [".", "-create", path, attribute, value], command: command)
        }
    }
    let account = try lookup()
    guard account.uid == identity.number, account.gid == identity.number, account.home == privateServiceHome else { throw BoxError("The Mac returned unexpected details for the service account.") }
    let groups = try checkedInstallCommand("/usr/bin/id", ["-Gn", privateServiceAccount], command: command)
    guard !String(decoding: groups.output, as: UTF8.self).split(whereSeparator: \.isWhitespace).contains("admin") else { throw BoxError("The Boxling service account must not be an administrator.") }
    return identity.number
}

func installDirectory(_ path: String, uid: uid_t, gid: gid_t, mode: mode_t, allowStickyBit: Bool = false) throws {
    if mkdir(path, mode) == 0 {
        guard chown(path, uid, gid) == 0, chmod(path, mode) == 0 else { throw systemError("Cannot set directory permissions") }
    } else {
        var info = stat()
        guard errno == EEXIST, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == uid, info.st_gid == gid,
              (info.st_mode & 0o7777 == mode || (allowStickyBit && info.st_mode & 0o7777 == mode | mode_t(S_ISVTX))) else {
            throw BoxError("Unexpected owner or permissions on \(path).")
        }
    }
}

func currentInstalledFile(_ path: String, content: Data, mode: mode_t) throws -> Bool {
    var info = stat()
    if lstat(path, &info) != 0 {
        if errno == ENOENT { return false }; throw systemError("Cannot inspect \(path)")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0, info.st_nlink == 1 else { throw BoxError("Unexpected ownership or file type at \(path).") }
    return try info.st_mode & 0o7777 == mode && Data(contentsOf: URL(fileURLWithPath: path)) == content
}

@discardableResult
func storeInstalledFile(_ path: String, content: Data, mode: mode_t) throws -> Bool {
    if try currentInstalledFile(path, content: content, mode: mode) { return false }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var template = Array((parent + "/.mybox-XXXXXX").utf8CString)
    let fd = try OwnedFD(mkstemp(&template))
    let pending = String(cString: template)
    defer { unlink(pending) }
    try writeAll(fd.value, content)
    guard fchmod(fd.value, mode) == 0, fsync(fd.value) == 0, rename(pending, path) == 0 else { throw systemError("Cannot install \(path)") }
    return true
}

func savedServiceIdentity() throws -> ServiceIdentity? {
    let path = helperDirectory + "/identity.plist"
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
        guard errno == ENOENT else { throw systemError("Cannot inspect \(path)") }
        guard lstat(privateServiceHome, &metadata) != 0, errno == ENOENT else {
            throw BoxError("The private Boxling home exists but its saved account identity is missing. Restore the identity before reinstalling.")
        }
        for name in [privateServiceAccount, legacyPrivateServiceAccount] {
            guard getpwnam(name) == nil, getgrnam(name) == nil else {
                throw BoxError("An account or group named \(name) already exists without a saved Boxling identity.")
            }
        }
        return nil
    }
    let identity = try PropertyListDecoder().decode(ServiceIdentity.self, from: readPackageFile(path, mode: 0o600))
    guard UUID(uuidString: identity.user) != nil, UUID(uuidString: identity.group) != nil else {
        throw BoxError("Invalid service account identity.")
    }
    try checkServiceID(identity.number)
    return identity
}

private func createServiceIdentity() throws -> ServiceIdentity {
    let used = Set(serviceAccounts().map { $0.1 })
    guard let number = (UInt32(300)...499).reversed().first(where: { !used.contains($0) }) else { throw BoxError("No unused service ID is available.") }
    let identity = ServiceIdentity(number: number, user: UUID().uuidString.lowercased(), group: UUID().uuidString.lowercased())
    let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
    try storeInstalledFile(helperDirectory + "/identity.plist", content: encoder.encode(identity), mode: 0o600)
    return identity
}

func requireBoxlingBootVerification(command: InstallCommand = runInstallCommand) throws {
    let result = try command(forkBootPlugin, ["--version"])
    let words = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
    let prefix = "1.6.1-mybox."
    guard result.status == 0, let version = words.dropFirst(2).first, version.hasPrefix(prefix),
          let revision = Int(version.dropFirst(prefix.count)), revision >= 6 else {
        throw BoxError("Install the updated Boxling package with my-container-box runtime 1.6.1-mybox.6 to use the _boxling account.")
    }
}

@discardableResult
func storeJob(_ path: String, _ job: [String: Any]) throws -> Bool {
    try storeInstalledFile(path, content: PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0), mode: 0o644)
}

func installSocketService(_ uid: uid_t, suffix: String, socketName: String, program: [String], reload: Bool = false) throws {
    let directory = "/private/var/db/mybox-boot"
    try installDirectory(directory, uid: 0, gid: uid, mode: 0o750)
    let label = "io.github.janpmz.my-container-box." + suffix
    let path = "/Library/LaunchDaemons/" + label + ".plist"
    let changed = try storeJob(path, ["Label": label, "ProgramArguments": program, "inetdCompatibility": ["Wait": false],
        "Sockets": ["Listener": ["SockPathName": directory + "/" + socketName, "SockPathMode": 0o666]],
        "StandardErrorPath": "/var/log/mybox-firewall.log"])
    let loaded = try runInstallCommand("/bin/launchctl", ["print", "system/" + label]).status == 0
    if changed || !loaded || reload {
        if loaded { try checkedInstallCommand("/bin/launchctl", ["bootout", "system/" + label]) }
        try checkedInstallCommand("/bin/launchctl", ["bootstrap", "system", path])
    }
}

// Only migrate the old runtime in the dedicated Boxling account. Never stop
// Apple's service in the signed-in account or move that account's containers.
func stopLegacyPrivateRuntime(_ uid: uid_t,
                              expectedDataRoot: String = privateServiceHome + "/Library/Application Support/com.apple.container",
                              command: InstallCommand = runInstallCommand) throws {
    let loaded = try command("/bin/launchctl", ["print", "user/\(uid)/com.apple.container.apiserver"])
    if loaded.status != 0 { return }
    let prefix = ["asuser", String(uid), "/usr/bin/sudo", "-n", "-H", "-u", "#\(uid)", "--", "/usr/local/bin/container"]
    let health = try checkedInstallCommand("/bin/launchctl", prefix + ["system", "status", "--format", "json"], command: command)
    guard let metadata = try JSONSerialization.jsonObject(with: health.output) as? [String: Any],
          let paths = metadata["paths"] as? [String: String],
          let data = paths["appRoot"], let installation = paths["installRoot"],
          URL(fileURLWithPath: data).resolvingSymlinksInPath().standardizedFileURL.path ==
            URL(fileURLWithPath: expectedDataRoot).resolvingSymlinksInPath().standardizedFileURL.path,
          URL(fileURLWithPath: installation).standardizedFileURL.path == "/usr/local" else {
        throw BoxError("The previous private runtime uses unexpected paths. Setup stopped. Reported status: \(String(decoding: health.output, as: UTF8.self))")
    }
    let listed = try checkedInstallCommand("/bin/launchctl", prefix + ["list", "--all", "--format", "json"], command: command)
    guard let records = try JSONSerialization.jsonObject(with: listed.output) as? [[String: Any]],
          records.allSatisfy({ ($0["status"] as? [String: Any])?["state"] as? String == "stopped" }) else {
        throw BoxError("Stop all Boxling boxes before upgrading the runtime installation.")
    }
    try checkedInstallCommand("/bin/launchctl", prefix + ["system", "stop"], command: command)
    guard try command("/bin/launchctl", ["print", "user/\(uid)/com.apple.container.apiserver"]).status != 0 else {
        throw BoxError("The previous private runtime did not stop. Setup stopped before replacing the helpers.")
    }
}

func installBoxlingService(artifactDirectory: String, packageOwner: uid_t? = nil, reloadServices: Bool = false) throws {
    guard geteuid() == 0, let owner = packageOwner ?? UInt32(ProcessInfo.processInfo.environment["SUDO_UID"] ?? ""), owner > 0 else {
        throw BoxError("Run boxling setup-service from your normal Mac account.")
    }
    umask(0o077)
    // Installer writes its receipt after postinstall. That root-only entry point
    // instead validates the prepared owner and the installed runtime files below.
    if packageOwner == nil {
        let combined = try runInstallCommand("/usr/sbin/pkgutil", ["--pkg-info", myboxPackageIdentifier])
        if combined.status != 0 { try checkedInstallCommand("/usr/sbin/pkgutil", ["--pkg-info", forkPackageIdentifier]) }
    }
    func verifyRuntime(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT != S_IFLNK,
              info.st_mode & 0o022 == 0 else { throw BoxError("The runtime installation must be under administrator control: \(path)") }
    }
    for path in ["/Library", "/Library/Application Support", "/Library/Application Support/MyBox", forkInstallRoot,
                 forkInstallRoot + "/bin", forkInstallRoot + "/bin/container", forkInstallRoot + "/bin/container-apiserver",
                 forkInstallRoot + "/libexec", forkInstallRoot + "/libexec/container",
                 forkInstallRoot + "/libexec/container/container-mybox-bridge", "/Library/PrivilegedHelperTools"] { try verifyRuntime(path) }
    guard let entries = FileManager.default.enumerator(atPath: forkInstallRoot + "/libexec/container") else { throw BoxError("Cannot inspect the runtime installation.") }
    for case let name as String in entries { try verifyRuntime(forkInstallRoot + "/libexec/container/" + name) }
    try requireBoxlingBootVerification()
    let programs = ["mybox-authenticate", "mybox-worker", "mybox-port-forwarder", "mybox-service", "mybox-access", "mybox-setup"]
    let firewallSource = FileManager.default.fileExists(atPath: artifactDirectory + "/mybox-firewall-manager")
        ? artifactDirectory + "/mybox-firewall-manager" : firewallProgram
    var artifacts: [String: Data] = [:]
    for name in programs + ["mybox-firewall-manager"] {
        artifacts[name] = try Data(contentsOf: URL(fileURLWithPath: name == "mybox-firewall-manager" ? firewallSource : artifactDirectory + "/" + name))
    }
    try installDirectory(helperDirectory, uid: 0, gid: 0, mode: 0o755)
    let lock = try OwnedFD(open(helperDirectory + "/setup.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600))
    guard flock(lock.value, LOCK_EX) == 0 else { throw systemError("Cannot lock service setup") }
    defer { withExtendedLifetime(lock) {} }
    let ownerPath = helperDirectory + "/owner"
    if FileManager.default.fileExists(atPath: ownerPath) {
        _ = try currentInstalledFile(ownerPath, content: Data(), mode: 0o644)
        guard try String(contentsOfFile: ownerPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == String(owner) else { throw BoxError("Another Mac account owns this installation.") }
    }
    let saved = try savedServiceIdentity()
    let identity = try saved ?? createServiceIdentity()
    if saved != nil {
        let names = try serviceNameChanges(identity)
        if !names.isEmpty {
            let uid = identity.number
            try installDirectory(privateServiceHome, uid: uid, gid: uid, mode: 0o700)
            try stopLegacyPrivateRuntime(uid)
            _ = try checkPackageRuntimeCanStop(uid)
            try stopPackageRuntime(uid)
            try renameServiceRecords(names)
        }
    }
    let uid = try configureServiceIdentity(identity)
    try stopLegacyPrivateRuntime(uid)
    try installDirectory(privateServiceHome, uid: uid, gid: uid, mode: 0o700)
    try installDirectory(privateServiceHome + "/requests", uid: uid, gid: uid, mode: 0o700)
    try installDirectory("/private/var/db/mybox-socket", uid: uid, gid: uid, mode: 0o755)
    var changed = Set<String>()
    for name in programs {
        if try storeInstalledFile(helperDirectory + "/" + name, content: artifacts[name]!, mode: 0o755) { changed.insert(name) }
    }
    try storeInstalledFile(ownerPath, content: Data("\(owner)\n".utf8), mode: 0o644)
    try installSocketService(uid, suffix: "verify-boot", socketName: "verify.sock", program: [firewallProgram, "verify-runtime-boot"], reload: reloadServices)
    try installSocketService(uid, suffix: "approve-access", socketName: "access.sock", program: [helperDirectory + "/mybox-access", "serve"], reload: reloadServices || changed.contains("mybox-access"))
    if try reloadServices || !currentInstalledFile(firewallProgram, content: artifacts["mybox-firewall-manager"]!, mode: 0o755) || runInstallCommand("/bin/launchctl", ["print", "system/io.github.janpmz.my-container-box.firewall"]).status != 0 {
        try checkedInstallCommand(firewallSource, ["install"])
    }
    let label = "io.github.janpmz.my-container-box.service"
    let agent = helperDirectory + "/service.plist"
    let changedAgent = try storeJob(agent, ["Label": label, "LimitLoadToSessionType": "Background",
        "ProgramArguments": [helperDirectory + "/mybox-service", "serve"], "WorkingDirectory": privateServiceHome, "KeepAlive": true,
        "EnvironmentVariables": ["HOME": privateServiceHome, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CONTAINER_INSTALL_ROOT": forkInstallRoot,
            "CONTAINER_DISABLE_HOST_DNS": "1",
            "CONTAINER_APP_ROOT": privateServiceHome + "/Library/Application Support/com.apple.container"]])
    let domain = "user/\(uid)", bootstrapLabel = "io.github.janpmz.my-container-box.bootstrap"
    let bootstrapPath = "/Library/LaunchDaemons/" + bootstrapLabel + ".plist"
    let changedBoot = try storeJob(bootstrapPath, ["Label": bootstrapLabel, "RunAtLoad": true,
        "ProgramArguments": ["/bin/launchctl", "asuser", String(uid), "/bin/launchctl", "bootstrap", domain, agent]])
    let registered = try runInstallCommand("/bin/launchctl", ["print", domain + "/" + label]).status == 0
    let bootRegistered = try runInstallCommand("/bin/launchctl", ["print", "system/" + bootstrapLabel]).status == 0
    if reloadServices || changedAgent || changedBoot || changed.contains("mybox-service") || !registered || !bootRegistered {
        _ = try runInstallCommand("/bin/launchctl", ["bootout", "system/" + bootstrapLabel])
        _ = try runInstallCommand("/bin/launchctl", ["bootout", domain + "/" + label])
        try checkedInstallCommand("/bin/launchctl", ["bootstrap", "system", bootstrapPath])
    }
    var ready = false
    for _ in 0..<100 {
        if try runInstallCommand("/bin/launchctl", ["print", domain + "/" + label]).status == 0,
           let probe = try? connectSocket(brokerSocket), (try? peerUID(probe.value)) == uid { ready = true; break }
        usleep(100_000)
    }
    guard ready else { throw BoxError("The service did not start in \(domain). Inspect launchctl print system/\(bootstrapLabel).") }
    // Remove the replaced scripts only after the native service is reachable.
    for name in ["broker.py", "access.py", "transfer.py"] {
        let path = helperDirectory + "/" + name
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw BoxError("Unexpected legacy helper: \(path)") }
            guard unlink(path) == 0 else { throw systemError("Cannot remove replaced Python helper") }
        }
    }
    print("Installed the private Boxling account. Check the connection with boxling list.")
}
