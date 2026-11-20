import Foundation
import Darwin
import Network

// Each receive waits for the corresponding send. At most one 64 KiB buffer per
// direction is pending, even if a peer stops reading.
final class PortRelay {
    let incoming: NWConnection
    let outgoing: NWConnection
    let queue: DispatchQueue
    let finished: () -> Void
    let config: PortConfiguration
    let backend: String
    let port: Int
    var guest: GuestPortConnection?
    var tryingLoopback = false
    var closed = false
    var completedDirections = 0
    var connected = false
    var readIn = 0
    var readOut = 0

    func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["MYBOX_TRACE"] == "1" { note(message + " in=\(readIn) out=\(readOut)") }
    }

    init(incoming: NWConnection, config: PortConfiguration, backend: String, port: Int, queue: DispatchQueue, finished: @escaping () -> Void) {
        self.incoming = incoming
        self.config = config
        self.backend = backend
        self.port = port
        self.outgoing = NWConnection(host: NWEndpoint.Host(config.target!.address), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        self.queue = queue
        self.finished = finished
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state, let self {
                self.trace("incoming failure \(error)")
                if !self.connected { self.close() }
            }
        }
        outgoing.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed, !self.tryingLoopback else { return }
            switch state {
            case .ready:
                guard !self.connected else { return }
                self.connected = true
                self.trace("using box network port \(self.port)")
                self.copyToBox()
                self.copyFromBox()
            case .failed(let error):
                self.trace("outgoing failure \(error)")
                // A state change can precede delivery of buffered receive data.
                // Once connected, let the receive/send completions drain it.
                if !self.connected { self.connectLoopback() }
            case .waiting:
                if !self.connected { self.connectLoopback() }
            case .cancelled: self.trace("outgoing cancelled"); self.close()
            default: break
            }
        }
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            if let self, !self.connected { self.connectLoopback() }
        }
    }

    func connectLoopback() {
        guard !closed, !connected, !tryingLoopback else { return }
        tryingLoopback = true
        outgoing.stateUpdateHandler = nil
        outgoing.cancel()
        // Check the target again before executing inside the box. No request bytes
        // were sent on the failed network connection, so this does not replay data.
        DispatchQueue.global().async { [self] in
            var failure: Error?
            do { try checkForwardingTarget(config, backend: backend) } catch { failure = error }
            let result = failure
            queue.async { [self] in
                guard !closed else { return }
                do {
                    if let result { throw result }
                    let connection = try GuestPortConnection(backend: backend, id: config.id, port: port, queue: queue)
                    guest = connection
                    connection.start { [weak self] error in
                        guard let self, !self.closed else { return }
                        if let error { self.trace("loopback connection failed: \(error)"); self.close(); return }
                        self.trace("using box loopback port \(self.port)")
                        self.connected = true
                        self.copyToBox()
                        self.copyFromBox()
                    }
                } catch { trace("loopback connection failed: \(error)"); close() }
            }
        }
    }

    func completeDirection() {
        completedDirections += 1
        if completedDirections == 2 { close() }
    }

    func copyToBox() {
        guard !closed else { return }
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.readIn += data?.count ?? 0
            let ended = complete || error != nil
            let sent: (Error?) -> Void = { [weak self] error in
                guard let self, !self.closed else { return }
                if let error { self.trace("send failure \(error)"); self.close(); return }
                if ended { self.completeDirection() } else { self.copyToBox() }
            }
            if let guest = self.guest { guest.send(data, final: ended, completion: sent) }
            else {
                self.outgoing.send(content: data, contentContext: .defaultStream, isComplete: ended,
                                   completion: .contentProcessed { sent($0) })
            }
        }
    }

    func copyFromBox() {
        guard !closed else { return }
        let received: GuestPortConnection.Receive = { [weak self] data, complete, error in
            guard let self, !self.closed else { return }
            self.readOut += data?.count ?? 0
            let ended = complete || error != nil
            if let error { self.trace("read failure \(error)") }
            self.incoming.send(content: data, contentContext: .defaultStream, isComplete: ended,
                               completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if let error { self.trace("send failure \(error)"); self.close(); return }
                if ended { self.completeDirection() } else { self.copyFromBox() }
            })
        }
        if let guest { guest.receive(received) }
        else { outgoing.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in received(data, complete, error) } }
    }

    func close() {
        guard !closed else { return }
        trace("close \(completedDirections)")
        closed = true
        incoming.cancel()
        outgoing.cancel()
        guest?.cancel()
        finished()
    }
}

final class PortListener {
    let mapping: PortMapping
    let listener: NWListener
    var ready = false
    var failure: String?
    var relays: [UUID: PortRelay] = [:]

    init(_ mapping: PortMapping, config: PortConfiguration, backend: String, queue: DispatchQueue) throws {
        self.mapping = mapping
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(mapping.outside))!)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.ready = true
            case .failed(let error):
                self?.failure = "Cannot listen on outside port \(mapping.outside): \(error)"
            case .waiting(let error) where self?.ready == true:
                self?.failure = "Outside port \(mapping.outside) stopped listening: \(error)"
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.relays.count < 128 else { connection.cancel(); return }
            let id = UUID()
            let relay = PortRelay(incoming: connection, config: config, backend: backend, port: mapping.inside, queue: queue) { [weak self] in
                self?.relays.removeValue(forKey: id)
            }
            self.relays[id] = relay
            relay.start()
        }
        listener.start(queue: queue)
    }

    func close() {
        listener.cancel()
        for relay in Array(relays.values) { relay.close() }
    }
}

struct ForwardingCheckTimeout: Error, CustomStringConvertible {
    var description: String { "The container service did not answer. Forwarding is paused; retrying automatically." }
}

struct ForwardingTargetChanged: Error, CustomStringConvertible {
    var description: String { "The box stopped or its network identity changed. Forwarding stopped." }
}

// A timeout leaves the identity unknown. Keep ports closed until a later check
// confirms the same container, boot, and network; do not adopt a new target.
func checkForwardingTarget(_ config: PortConfiguration, backend: String) throws {
    guard let target = config.target else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: backend)
    process.arguments = ["inspect", config.id]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let output = Pipe()
    let reader = output.fileHandleForReading
    defer { try? reader.close() }
    process.standardOutput = output
    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3

    // Drain stdout before waiting for exit. Large inspect replies can fill a
    // pipe and keep the child blocked in write until we read from it.
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ForwardingCheckTimeout() }
        let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
        if ready == 0 { throw ForwardingCheckTimeout() }
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw BoxError("Cannot read the box's network identity.") }
        let count = read(descriptor.fd, &buffer, buffer.count)
        if count == 0 { break }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw BoxError("Cannot read the box's network identity.") }
        data.append(contentsOf: buffer.prefix(count))
    }
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
    guard !process.isRunning else { throw ForwardingCheckTimeout() }
    guard process.terminationStatus == 0,
          let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          items.count == 1, let item = items.first,
          let configuration = item["configuration"] as? [String: Any],
          let status = item["status"] as? [String: Any], let state = status["state"] as? String else {
        throw BoxError("Cannot read the box's network identity from the container service.")
    }
    guard item["id"] as? String == config.id, configuration["creationDate"] as? String == config.created,
          (configuration["labels"] as? [String: String])?["io.github.janpmz.my-container-box.managed"] == "true",
          state != "stopped" else {
        throw ForwardingTargetChanged()
    }
    guard state == "running", let started = status["startedDate"] as? String,
          let networks = status["networks"] as? [[String: Any]], !networks.isEmpty,
          let network = networks[0]["network"] as? String,
          let address = (networks[0]["ipv4Address"] as? String)?.split(separator: "/").first else {
        throw BoxError("The container service has not reported the box's running network yet.")
    }
    guard started == target.started, networks.count == 1, network == "mybox-net-" + String(config.id.dropFirst(6)),
          address == target.address else {
        throw ForwardingTargetChanged()
    }
}

final class PortForwarder {
    let directory: URL
    let backend: String
    let queue = DispatchQueue(label: "mybox.port-forwarder")
    var config: PortConfiguration?
    var listeners: [Int: PortListener] = [:]
    var pendingListeners: [Int: PortListener] = [:]
    var pendingSince = Date()
    var failedRevision = ""
    var reported = ""
    var monitorStarted: TimeInterval?
    var targetNeedsVerification = true
    var lastMonitor: TimeInterval = -.infinity
    var lastHeartbeat: TimeInterval = -.infinity
    var status: PortStatus?
    var timer: DispatchSourceTimer?

    init(directory: URL, backend: String) { self.directory = directory; self.backend = backend }

    func report(_ current: PortConfiguration, error: String? = nil, targetRejected: Bool? = nil) {
        status = PortStatus(revision: current.revision, pid: getpid(), active: error == nil && !listeners.isEmpty,
                            error: error, targetRejected: targetRejected)
        writeHeartbeat(ProcessInfo.processInfo.systemUptime)
        reported = current.revision
    }

    func writeHeartbeat(_ now: TimeInterval) {
        guard var status else { return }
        status.heartbeat = now
        do {
            try writePortJSON(status, directory.appendingPathComponent("status.json"))
            lastHeartbeat = now
        } catch { note("Cannot report forwarding status: \(error)"); exit(1) }
    }

    func closeAll() {
        for listener in listeners.values { listener.close() }
        listeners.removeAll()
        for listener in pendingListeners.values { listener.close() }
        pendingListeners.removeAll()
    }

    func checkTarget(_ current: PortConfiguration) {
        monitorStarted = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async { [self] in
            var failure: Error?
            do { try checkForwardingTarget(current, backend: backend) } catch { failure = error }
            let result = failure
            queue.async { [self] in
                monitorStarted = nil
                // Commands can remove mappings or replace the target during a
                // slow check. Its result must never reopen the previous ports.
                guard config?.revision == current.revision else { return }
                lastMonitor = ProcessInfo.processInfo.systemUptime
                do {
                    if let result { throw result }
                    if targetNeedsVerification {
                        pendingSince = Date()
                        for mapping in current.mappings where listeners[mapping.outside] == nil {
                            pendingListeners[mapping.outside] = try PortListener(mapping, config: current, backend: backend, queue: queue)
                        }
                        targetNeedsVerification = false
                        reported = ""
                        failedRevision = ""
                    }
                } catch {
                    closeAll()
                    let rejected = error is ForwardingTargetChanged
                    report(current, error: String(describing: error), targetRejected: rejected ? true : nil)
                    if rejected {
                        note("Port forwarding stopped: \(error)")
                        exit(1)
                    }
                    targetNeedsVerification = true
                }
            }
        }
    }

    func tick() {
        do {
            let next = try readPortConfiguration(directory)
            if next.revision != config?.revision {
                for listener in pendingListeners.values { listener.close() }
                pendingListeners.removeAll()
                if next.target != config?.target || next.created != config?.created { closeAll() }
                config = next
                reported = ""
                failedRevision = ""
                targetNeedsVerification = true
                lastMonitor = -.infinity
                if next.target == nil || next.mappings.isEmpty {
                    closeAll()
                    report(next)
                    exit(0)
                }
            }
            guard let current = config else { return }
            if !targetNeedsVerification && failedRevision != current.revision && reported != current.revision {
                let failure = pendingListeners.values.compactMap(\.failure).first
                    ?? (Date().timeIntervalSince(pendingSince) > 5 ? "The new outside ports did not become ready." : nil)
                if let failure {
                    for listener in pendingListeners.values { listener.close() }
                    pendingListeners.removeAll()
                    failedRevision = current.revision
                    report(current, error: failure)
                    if listeners.isEmpty { exit(1) }
                } else if pendingListeners.values.allSatisfy(\.ready) {
                    // Keep existing connections until all new listeners bind.
                    for (port, listener) in Array(listeners) where !current.mappings.contains(listener.mapping) {
                        listener.close()
                        listeners.removeValue(forKey: port)
                    }
                    listeners.merge(pendingListeners) { _, new in new }
                    pendingListeners.removeAll()
                    report(current)
                }
            }
            if let failure = listeners.values.compactMap(\.failure).first {
                closeAll()
                report(current, error: failure)
                exit(1)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHeartbeat >= 1, monitorStarted.map({ now - $0 < 4 }) ?? true {
                writeHeartbeat(now)
            }
            if monitorStarted == nil && now - lastMonitor >= 1 {
                checkTarget(current)
            }
        } catch {
            closeAll()
            if let config { report(config, error: String(describing: error)) }
            note("Port forwarding stopped: \(error)")
            exit(1)
        }
    }

    func run() throws -> Never {
        try checkPrivatePortDirectory(directory)
        let fd = open(directory.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BoxError("Cannot open the forwarding lock.") }
        // A second startup must not replace the active helper or its status.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); exit(0) }
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(100))
        source.setEventHandler { [self] in tick() }
        timer = source
        source.resume()
        dispatchMain()
    }
}

@main
struct PortForwarderMain {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard [2, 3].contains(args.count), args[0].hasPrefix("/"), args[1].hasPrefix("/") else {
                throw BoxError("This helper is started by Boxling port commands.")
            }
            let parentWatch: DispatchSourceProcess?
            if args.count == 3 {
                guard let parent = pid_t(args[2]), parent > 1, getppid() == parent else { return }
                let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
                watch.setEventHandler { exit(0) }
                watch.resume()
                guard getppid() == parent else { return }
                parentWatch = watch
            } else { parentWatch = nil }
            defer { withExtendedLifetime(parentWatch) {} }
            try PortForwarder(directory: URL(fileURLWithPath: args[0]), backend: args[1]).run()
        } catch { note("mybox-port-forwarder: \(error)"); exit(1) }
    }
}
