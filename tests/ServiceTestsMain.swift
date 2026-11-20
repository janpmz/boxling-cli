// Test-only entry points exercise production Swift code without root, PF, or UI.
import Darwin
import Foundation

@main struct ServiceTestsMain {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            func json(_ index: Int) throws -> Any { try JSONSerialization.jsonObject(with: Data(args[index].utf8)) }
            switch args[0] {
            case "supervise-ports":
                let supervisor = PortSupervisor(root: URL(fileURLWithPath: args[1]), executable: args[2], backend: args[3])
                while true {
                    supervisor.check()
                    Thread.sleep(forTimeInterval: 0.1)
                }
            case "workspace-pack":
                _ = try WorkspaceFileTransfer.send(URL(fileURLWithPath: args[1]), to: WorkspaceFileStream(input: 0, output: 1), skipLinks: args.last == "skip")
            case "workspace-unpack":
                _ = try WorkspaceFileTransfer.receive(from: WorkspaceFileStream(input: 0, output: 1), into: URL(fileURLWithPath: args[1]))
            case "workspace-publish":
                try WorkspaceFileTransfer.publish(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
            case "workspace-path": print(try WorkspacePaths.absolute(args[1]))
            case "client": exit(try brokerClient(Array(args.dropFirst(3)), socketPath: args[1], expectedPeer: UInt32(args[2])!))
            case "pack": note(String(try packTransfer(args[1], 1, skipSpecial: args.last == "skip")))
            case "unpack": print(try unpackTransfer(0, args[1]))
            case "publish": try publishTransfer(args[1], args[2])
            case "validate": _ = try validateServiceCommand(json(1))
            case "prompt": print(try accessPrompt(json(1) as! [String]))
            case "embedded-shell":
                print(String(decoding: try JSONEncoder().encode(EmbeddedTerminalShell.arguments), as: UTF8.self))
            case "legacy-embedded-shell":
                print(String(decoding: try JSONEncoder().encode(EmbeddedTerminalShell.legacyArguments), as: UTF8.self))
            case "peer":
                guard try peerUID(Int32(args[1])!) == UInt32(args[2])! else { throw BoxError("Wrong peer.") }
            case "request":
                let approval = try BoxAccessApproval(["enter", "demo", "pwd"], socketPath: args[1], expectedOwner: UInt32(args[2])!)
                withExtendedLifetime(approval) {}
            case "check-id":
                let pairs = try json(2) as! [[Any]]
                try checkServiceID(UInt32(args[1])!, accounts: pairs.map { ($0[0] as! String, UInt32(($0[1] as! NSNumber).uint32Value)) })
            case "package-owner":
                let values = try json(1) as! [String: UInt32]
                print(try selectPackageOwner(existing: values["existing"], console: values["console"]))
            case "package-target":
                try requirePackageStartupDisk(args[1])
            case "install-directory":
                try installDirectory(args[1], uid: UInt32(args[2])!, gid: UInt32(args[3])!, mode: 0o755,
                                     allowStickyBit: args[4] == "sticky")
            case "package-personal":
                let active = args[1]
                try requirePersonalForksStopped([501, 502], command: { executable, arguments in
                    guard executable == "/bin/launchctl", arguments.count == 2, arguments[0] == "print",
                          arguments[1].hasSuffix("/" + forkServicePrefix + "apiserver") else { throw BoxError("Unexpected personal service operation.") }
                    return ServiceCommandResult(status: arguments[1] == active ? 0 : 113, output: Data(), error: Data())
                })
            case "package-runtime":
                let mode = args[1]
                let decision = args.dropFirst(2).first
                var activeNames: Set<String> = ["running", "new-box", "stop-fails", "still-running", "foreign"].contains(mode)
                    ? ["api", "website"] : []
                let temporary = try TemporaryDirectory()
                defer { withExtendedLifetime(temporary) {} }
                let command: InstallCommand = { executable, arguments in
                    guard executable == "/bin/launchctl" else { throw BoxError("Unexpected package command.") }
                    if arguments == ["print", "user/499/com.apple.container.apiserver"] {
                        return ServiceCommandResult(status: mode == "legacy" ? 0 : 113, output: Data(), error: Data())
                    }
                    if arguments == ["print", "user/499/" + forkServicePrefix + "apiserver"] {
                        return ServiceCommandResult(status: mode == "absent" ? 113 : 0, output: Data(), error: Data())
                    }
                    let stop = ["asuser", "501", "/usr/bin/sudo", "-n", "-H", "-u", "#501", "--", "/usr/bin/env", "-u", "TMPDIR",
                                helperDirectory + "/mybox-service", "client", "stop"]
                    if Array(arguments.dropLast()) == stop, let name = arguments.last {
                        guard decision == "approve", activeNames.contains(name) else { throw BoxError("Unexpected stop.") }
                        print("stop " + name)
                        if mode == "stop-fails" { return ServiceCommandResult(status: 1, output: Data(), error: Data()) }
                        if mode != "still-running" { activeNames.remove(name) }
                        if mode == "new-box" { activeNames.insert("archive") }
                        return ServiceCommandResult(status: 0, output: Data(), error: Data())
                    }
                    let prefix = ["asuser", "499", "/usr/bin/sudo", "-n", "-H", "-u", "#499", "--", forkInstallRoot + "/bin/container"]
                    guard Array(arguments.prefix(prefix.count)) == prefix else { throw BoxError("Package checked another account or runtime.") }
                    let operation = Array(arguments.dropFirst(prefix.count))
                    let value: Any
                    if operation == ["system", "status", "--format", "json"] {
                        value = ["status": "running", "paths": ["appRoot": mode == "wrong-root" ? "/tmp/foreign/" : temporary.path + "/",
                            "installRoot": mode == "wrong-install" ? "/usr/local/" : forkInstallRoot + "/"]]
                    } else if operation == ["list", "--all", "--format", "json"] {
                        let configuration = ["labels": [managedLabel: "true"]]
                        value = [
                            ["id": "mybox-website", "configuration": configuration,
                             "status": ["state": activeNames.contains("website") ? "running" : "stopped"]],
                            ["id": "mybox-api", "configuration": configuration,
                             "status": ["state": activeNames.contains("api") ? "starting" : "stopped"]],
                            ["id": "mybox-archive", "configuration": configuration, "status": ["state": activeNames.contains("archive") ? "running" : "stopped"]],
                            ["id": "other-container", "configuration": [:], "status": ["state": mode == "foreign" ? "running" : "stopped"]],
                            ["status": ["state": mode == "unknown" ? "unknown" : "stopped"]]
                        ]
                    } else { throw BoxError("Package preflight attempted a mutation.") }
                    return ServiceCommandResult(status: mode == "broken" ? 1 : 0,
                        output: try JSONSerialization.data(withJSONObject: value), error: Data())
                }
                do {
                    let stop: (([String]) throws -> Void)? = decision.map { choice in
                        { names in
                            try stopPackageBoxes(names, owner: 501, confirm: { requested in
                                print("prompt " + requested.joined(separator: " "))
                                return choice == "approve"
                            }, command: command)
                        }
                    }
                    print(try checkPackageRuntimeCanStop(499, command: command, expectedDataRoot: temporary.path, stopActiveBoxes: stop))
                } catch let error as PackageUpdateError {
                    error.notifyInstallerUser { title, message in print(title + "\n" + message) }
                    throw error
                }
            case "identity":
                let config = try json(1) as! [String: Any]
                let identity = ServiceIdentity(number: 499, user: "11111111-1111-4111-8111-111111111111", group: "22222222-1111-4111-8111-111111111111")
                let record = config["record"] as! [String: String]
                var calls: [[String]] = []
                defer { if let log = config["log"] as? String { try? JSONSerialization.data(withJSONObject: calls).write(to: URL(fileURLWithPath: log)) } }
                let command: InstallCommand = { executable, arguments in
                    calls.append([executable] + arguments)
                    if executable == "/usr/bin/id" {
                        return ServiceCommandResult(status: 0, output: Data((config["groups"] as? String ?? "_boxling everyone").utf8), error: Data())
                    }
                    guard arguments[1] == "-read" else { throw BoxError("An existing account was modified.") }
                    let attribute = arguments[3]
                    let value = attribute == "GeneratedUID" ? (config["uuid"] as? String ?? (arguments[2].contains("Groups") ? identity.group : identity.user)) : record[attribute]!
                    let key = attribute == "IsHidden" ? "dsAttrTypeNative:IsHidden" : attribute
                    return ServiceCommandResult(status: 0, output: Data("\(key): \(value)\n".utf8), error: Data())
                }
                _ = try configureServiceIdentity(identity, command: command, checkID: { _ in }, lookup: {
                    ServiceAccountRecord(uid: 499, gid: 499, home: privateServiceHome)
                })
            case "rename-identity":
                var records = try json(1) as! [String: [String: String]]
                let identity = ServiceIdentity(number: 499, user: "11111111-1111-4111-8111-111111111111", group: "22222222-1111-4111-8111-111111111111")
                var writes: [[String]] = []
                defer { if args.count == 3 { try? JSONEncoder().encode(writes).write(to: URL(fileURLWithPath: args[2])) } }
                let command: InstallCommand = { executable, arguments in
                    guard executable == "/usr/bin/dscl", arguments.first == "." else { throw BoxError("Unexpected account command.") }
                    let path = arguments[2], attribute = arguments[3]
                    switch arguments[1] {
                    case "-read":
                        guard let record = records[path] else {
                            return ServiceCommandResult(status: 1, output: Data(), error: Data("eDSRecordNotFound".utf8))
                        }
                        guard let value = record[attribute] else { throw BoxError("Unexpected account attribute.") }
                        return ServiceCommandResult(status: 0, output: Data("\(attribute): \(value)\n".utf8), error: Data())
                    case "-change":
                        guard attribute == "RecordName", arguments.count == 6, let record = records[path],
                              record[attribute] == arguments[4] else { throw BoxError("Unexpected account modification.") }
                        let renamed = String(path.prefix(through: path.lastIndex(of: "/")!)) + arguments[5]
                        guard records[renamed] == nil else { throw BoxError("Attempted to overwrite an account.") }
                        records[renamed] = record.merging([attribute: arguments[5]]) { _, new in new }
                        records.removeValue(forKey: path)
                        writes.append(arguments)
                        return ServiceCommandResult(status: 0, output: Data(), error: Data())
                    default: throw BoxError("Unexpected account operation.")
                    }
                }
                try renameServiceRecords(serviceNameChanges(identity, command: command), command: command)
                guard try serviceNameChanges(identity, command: command).isEmpty else { throw BoxError("The account migration could not be retried.") }
                print(String(decoding: try JSONEncoder().encode(records), as: UTF8.self))
            case "boot-verification":
                try requireBoxlingBootVerification { executable, arguments in
                    guard executable == forkBootPlugin, arguments == ["--version"] else { throw BoxError("Setup checked the wrong runtime.") }
                    return ServiceCommandResult(status: 0, output: Data("container-runtime-linux version \(args[1]) (build: release)".utf8), error: Data())
                }
            case "legacy-runtime":
                let mode = args[1]
                var stopped = false
                // The real private directory cannot be traversed by this test's
                // user. Use an accessible directory to reproduce macOS resolving
                // /private/var and /var to the same location during root setup.
                let temporary = try TemporaryDirectory(parent: "/private/var/tmp")
                defer { withExtendedLifetime(temporary) {} }
                let dataRoot = mode == "var-alias" ? temporary.path : privateServiceHome + "/Library/Application Support/com.apple.container"
                let command: InstallCommand = { executable, arguments in
                    guard executable == "/bin/launchctl" else { throw BoxError("Unexpected migration executable.") }
                    if arguments.first == "print" {
                        guard arguments == ["print", "user/499/com.apple.container.apiserver"] else { throw BoxError("Migration touched another account.") }
                        return ServiceCommandResult(status: mode == "absent" || stopped ? 113 : 0, output: Data(), error: Data())
                    }
                    let prefix = ["asuser", "499", "/usr/bin/sudo", "-n", "-H", "-u", "#499", "--", "/usr/local/bin/container"]
                    guard Array(arguments.prefix(prefix.count)) == prefix else { throw BoxError("Migration touched another account.") }
                    let operation = Array(arguments.dropFirst(prefix.count))
                    let value: Any
                    if operation == ["system", "status", "--format", "json"] {
                        let reportedRoot = mode == "var-alias" ? String(dataRoot.dropFirst("/private".count)) : dataRoot
                        value = ["paths": ["appRoot": mode == "wrong-root" ? "/tmp/foreign" : reportedRoot + "/", "installRoot": mode == "wrong-install" ? "/tmp/foreign/" : "/usr/local/"]]
                    } else if operation == ["list", "--all", "--format", "json"] {
                        value = [["status": ["state": mode == "running" ? "running" : "stopped"]]]
                    } else if operation == ["system", "stop"], ["stopped", "var-alias"].contains(mode) {
                        stopped = true; value = [:] as [String: String]
                    } else { throw BoxError("Unsafe migration operation.") }
                    return ServiceCommandResult(status: 0, output: try JSONSerialization.data(withJSONObject: value), error: Data())
                }
                try stopLegacyPrivateRuntime(499, expectedDataRoot: dataRoot, command: command)
                print(stopped ? "stopped private runtime" : "no previous runtime")
            case "prepare", "access":
                let fd = Int32(args[1])!
                try configureSocket(fd)
                let config = try json(2) as! [String: Any]
                let responses = config["responses"] as? [[String: Any]] ?? []
                var calls: [[String: Any]] = [], index = 0
                defer { if let log = config["log"] as? String { try? JSONSerialization.data(withJSONObject: calls).write(to: URL(fileURLWithPath: log)) } }
                let command: AccessCommand = { executable, arguments, input, timeout in
                    calls.append(["executable": executable, "arguments": arguments, "input": try JSONSerialization.jsonObject(with: input), "timeout": timeout])
                    if executable == "/bin/launchctl" {
                        let challenge = (try JSONSerialization.jsonObject(with: input) as! [String])[0]
                        return ServiceCommandResult(status: Int32(config["auth_status"] as? Int ?? 0),
                            output: Data((config["auth_output"] as? String ?? challenge).utf8), error: Data())
                    }
                    guard index < responses.count else { throw BoxError("Unexpected firewall call.") }
                    let response = responses[index]; index += 1
                    if response["timeout"] as? Bool == true { throw ServiceTimeout() }
                    return ServiceCommandResult(status: Int32(response["status"] as? Int ?? 0),
                        output: try JSONSerialization.data(withJSONObject: response["confirmation"] ?? [:]),
                        error: Data((response["error"] as? String ?? "").utf8))
                }
                if args[0] == "access" {
                    try serveAccess(fd, expectedPeer: UInt32(config["peer"] as? Int ?? Int(getuid())),
                        owner: UInt32(config["owner"] as? Int ?? 501), consoleOwner: UInt32(config["console"] as? Int ?? 501), command: command)
                } else {
                    var times = config["times"] as? [Double] ?? []
                    try prepareApprovedBox(fd, box: "demo", command: command, clock: {
                        times.isEmpty ? ProcessInfo.processInfo.systemUptime : times.removeFirst()
                    }, lifetime: config["lifetime"] as? Double ?? 300)
                }
            default: throw BoxError("Unknown test operation.")
            }
        } catch { note(String(describing: error)); exit(1) }
    }
}
