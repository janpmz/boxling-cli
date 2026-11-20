import Darwin
import Foundation

typealias AccessCommand = (String, [String], Data, Double) throws -> ServiceCommandResult

func accessPrompt(_ args: [String]) throws -> String {
    guard args.count >= 2, matches(args[1], "^[a-z][a-z0-9-]{0,47}$"),
          !args.contains(where: { $0.utf8.contains(0) }) else { throw BoxError("Invalid box access request.") }
    // The fixed prompt setup opens the same interactive Bash session as plain
    // `enter`. Match every argument, never a caller-supplied label or prefix.
    if args[0] == "enter", args.count == 2 || Array(args.dropFirst(2)) == EmbeddedTerminalShell.arguments
        || Array(args.dropFirst(2)) == EmbeddedTerminalShell.legacyArguments {
        return "Open a shell in box “\(args[1])”. The requesting terminal controls this shell."
    }
    func quoted(_ argument: String) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: json, as: UTF8.self).utf16.map { unit in
            unit < 128 ? String(UnicodeScalar(unit)!) : String(format: "\\u%04x", unit)
        }.joined()
    }
    let shown = try args.dropFirst(2).map(quoted).joined(separator: " ")
    switch (args[0], args.count) {
    case ("start", 2), ("create", 2):
        return "\(args[0] == "create" ? "Create and start" : "Start") box “\(args[1])” with its Mac firewall protection."
    case ("stop", 2): return "Stop box “\(args[1])” and remove its firewall rules after Linux has stopped."
    case ("delete", 2): return "Permanently delete box “\(args[1])” and all its files, stopping Linux first if needed."
    case ("resize", 2): return "Change the CPU, memory, or disk capacity of stopped box “\(args[1])”."
    case ("recover-ports", 2): return "Restore the previous port settings of box “\(args[1])” after an interrupted change."
    case ("copy", 3) where matches(args[2], "^[a-z][a-z0-9-]{0,47}$") && args[1] != args[2]:
        return "Copy all files and saved credentials from box “\(args[1])” to new box “\(args[2])”."
    case ("ports", 7):
        _ = try approvedPortPolicies(args)
        return args[2] == "add"
            ? "Forward Mac localhost port \(args[4]) to port \(args[3]) in box “\(args[1])”, and update its firewall protection."
            : "Remove forwarding from Mac localhost port \(args[4]) for box “\(args[1])”, and update its firewall protection."
    case ("enter", _): return "Run in box “\(args[1])”. The requesting program controls input and receives output. Command: \(shown)"
    case ("files", 2): return "Allow this program to browse, read, create, edit, upload, download, and delete files and folders in “\(args[1])” /workspace for this session."
    case ("export", 3): return "Give the requesting program a copy of \(shown) from box “\(args[1])”."
    case ("import", 3...): return "Allow the requesting program to write \(shown) into box “\(args[1])”."
    default: throw BoxError("Unsupported box access request.")
    }
}

// Only the private worker supplies these policies. Pin both the existing and
// requested policy so the approval also covers an exact rollback on failure.
func approvedPortPolicies(_ args: [String]) throws -> [NSDictionary] {
    guard args.count == 7, ["add", "remove"].contains(args[2]),
          let outside = Int(args[4]), (1...65535).contains(outside),
          args[2] == "add" ? (Int(args[3]).map { (1...65535).contains($0) } ?? false) : args[3].isEmpty else {
        throw BoxError("Invalid port approval request.")
    }
    let policies = try args.suffix(2).map { value -> NSDictionary in
        guard let policy = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSDictionary,
              policy["network"] as? String == "mybox-net-" + args[1],
              policy["active"] as? Bool == true, let ports = policy["ports"] as? [Int],
              ports.count <= 64, Set(ports).count == ports.count,
              ports.allSatisfy({ (1...65535).contains($0) }) else { throw BoxError("Invalid approved port policy.") }
        return policy
    }
    let old = policies[0].mutableCopy() as! NSMutableDictionary
    let next = policies[1].mutableCopy() as! NSMutableDictionary
    let before = Set(old["ports"] as! [Int]), after = Set(next["ports"] as! [Int])
    old.removeObject(forKey: "ports"); next.removeObject(forKey: "ports")
    let validPorts = args[2] == "add" ? after == before.union([Int(args[3])!])
        : after.isSubset(of: before) && before.subtracting(after).count <= 1
    guard old.isEqual(next), validPorts else { throw BoxError("The port change modifies unrelated network settings.") }
    return policies
}

func nextAccessActions(_ sequence: [String], operation: String = "enter") -> [String]? {
    switch operation {
    case "stop", "delete": return sequence.isEmpty ? ["remove"] : nil
    case "copy", "resize": return nil
    case "recover-ports": return sequence.isEmpty ? ["update-ports"] : nil
    case "ports":
        switch sequence {
        case []: return ["verify"]
        case ["verify"]: return ["update-ports"]
        default: return nil
        }
    default: break
    }
    switch sequence {
    case []: return ["apply", "verify", "update-ports"]
    case ["apply"], ["apply", "verify"], ["update-ports"]: return ["verify"]
    default: return nil
    }
}

func prepareApprovedBox(_ connection: Int32, box: String,
                        operation: String = "enter", portPolicies: [NSDictionary]? = nil,
                        command: AccessCommand = serviceCommand,
                        clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
                        lifetime: Double = 300) throws {
    let deadline = clock() + lifetime
    let expires = Date().timeIntervalSince1970 + lifetime
    var actions: [String] = [], used = Set<String>(), policy: NSDictionary?
    var rollingBack = false, rollbackFinished = false
    while true {
        var remaining = deadline - clock()
        guard remaining > 0 else { throw BoxError("Box preparation approval expired.") }
        try socketTimeout(connection, remaining)
        let value: Any
        do { value = try receivePacket(connection) } catch is StreamClosed { return }
        remaining = deadline - clock()
        guard remaining > 0 else { throw BoxError("Box preparation approval expired.") }
        guard let message = value as? [String] else { throw BoxError("Unexpected approved firewall operation.") }
        if message == ["rollback"] {
            guard operation == "ports", !rollingBack,
                  [["verify"], ["verify", "update-ports"]].contains(actions) else {
                throw BoxError("Unexpected port rollback.")
            }
            rollingBack = true
            try sendPacket(connection, ["rollback"])
            continue
        }
        if message == ["finish"] {
            let complete: [[String]]
            switch operation {
            case "stop", "delete": complete = [[], ["remove"]]
            case "copy", "resize": complete = [[]]
            case "recover-ports": complete = [[], ["update-ports"]]
            case "ports": complete = rollingBack ? (rollbackFinished ? [actions] : []) : [[], ["verify", "update-ports"]]
            default: complete = [["verify"], ["apply", "verify", "verify"], ["update-ports", "verify"]]
            }
            guard complete.contains(actions) else { throw BoxError("Firewall preparation is incomplete.") }
            try sendPacket(connection, ["finished"]); return
        }
        let nextActions = rollingBack ? (rollbackFinished ? nil : ["update-ports"]) : nextAccessActions(actions, operation: operation)
        guard message.count == 2, message[0] == "firewall", let allowed = nextActions else {
            throw BoxError("Unexpected approved firewall operation.")
        }
        let token = message[1]
        guard UUID(uuidString: token)?.uuidString.lowercased() == token, used.insert(token).inserted else { throw BoxError("Invalid or reused firewall request.") }
        let expectedPolicy = portPolicies.map { $0[!rollingBack && actions.count == 1 ? 1 : 0] } ?? policy
        let scope: [String: Any] = ["box": box, "expires": expires, "actions": allowed, "policy": expectedPolicy ?? NSNull()]
        let result: ServiceCommandResult
        do {
            result = try command(firewallProgram, ["approve-access", token], JSONSerialization.data(withJSONObject: scope), remaining)
        } catch is ServiceTimeout {
            try sendPacket(connection, ["firewall-error", token, "Firewall preparation timed out; entry was refused."]); return
        }
        if result.status != 0 {
            let raw = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = String(raw.unicodeScalars.map { scalar -> String in
                if scalar == "\n" || scalar == "\t" || scalar == " " { return String(scalar) }
                switch scalar.properties.generalCategory {
                case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: return "?"
                default: return String(scalar)
                }
            }.joined().prefix(2000))
            let detail = sanitized.isEmpty ? "The firewall helper exited with status \(result.status)." : sanitized
            note(detail)
            try sendPacket(connection, ["firewall-error", token, detail])
            if operation == "ports", actions == ["verify"], !rollingBack {
                // The update may have partially applied. Only an explicit
                // rollback to the original policy can follow this failure.
                actions.append("update-ports")
                continue
            }
            return
        }
        guard let confirmation = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let action = confirmation["action"] as? String, allowed.contains(action),
              let confirmedPolicy = confirmation["policy"] as? NSDictionary,
              confirmedPolicy["network"] as? String == "mybox-net-" + box,
              expectedPolicy == nil || expectedPolicy!.isEqual(confirmedPolicy) else { throw BoxError("The firewall helper returned an unexpected confirmation.") }
        policy = confirmedPolicy; actions.append(action)
        if rollingBack { rollbackFinished = true }
        guard clock() < deadline else { throw BoxError("Box preparation approval expired.") }
        try sendPacket(connection, ["firewall", token])
    }
}

func serveAccess(_ connection: Int32, expectedPeer: uid_t, owner: uid_t, consoleOwner: uid_t,
                 command: AccessCommand = serviceCommand) throws {
    guard try peerUID(connection) == expectedPeer else { throw BoxError("Only the private Boxling service can request approval.") }
    try socketTimeout(connection, 5)
    guard let message = try receivePacket(connection) as? [Any], message.count == 3,
          message[0] as? String == "access-v2", let challenge = message[1] as? String,
          matches(challenge, "^[0-9a-f]{64}$"), let args = message[2] as? [String] else { throw BoxError("Invalid box access request.") }
    let preparing = ["enter", "files", "import", "export"].contains(args.first ?? "")
    let reason = try accessPrompt(args) + (preparing ? " Prepare and check the Mac firewall." : "")
    guard owner > 0, consoleOwner == owner else { throw BoxError("Sign in to the Mac account that installed Boxling to approve access.") }
    let result = try command("/bin/launchctl", ["asuser", String(owner), "/usr/bin/sudo", "-n", "-H", "-u", "#\(owner)", "--", helperDirectory + "/mybox-authenticate"],
                             JSONSerialization.data(withJSONObject: [challenge, reason]), 115)
    guard result.status == 0, result.output == Data(challenge.utf8) else { throw BoxError("Box access was not approved.") }
    try sendPacket(connection, ["approved", challenge])
    try prepareApprovedBox(connection, box: args[1], operation: args[0],
        portPolicies: args[0] == "ports" ? approvedPortPolicies(args) : nil, command: command)
}
