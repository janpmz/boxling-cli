import Darwin
import Foundation

// Only signal children spawned by this broker. An unreaped child keeps its PID
// until waitpid returns, so a stale status file cannot target another process.
final class PortSupervisor {
    private struct Child {
        let pid: pid_t
        let started: TimeInterval
        var stopping = false
    }

    private let root: URL
    private let executable: String
    private let backend: String
    private var children: [URL: Child] = [:]
    private var nextCheck: TimeInterval = 0

    init(root: URL, executable: String, backend: String) {
        self.root = root
        self.executable = executable
        self.backend = backend
    }

    func check() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextCheck else { return }
        nextCheck = now + 1
        var exited = Set<pid_t>()
        while true {
            let pid = waitpid(-1, nil, WNOHANG)
            if pid > 0 { exited.insert(pid) }
            else if pid == 0 || errno != EINTR { break }
        }
        children = children.filter { !exited.contains($0.value.pid) }

        for (directory, child) in children where !child.stopping {
            let status = readStatus(directory)
            let checked = ProcessInfo.processInfo.systemUptime
            let heartbeat = status?.pid == child.pid ? status?.heartbeat : nil
            let lastSeen = heartbeat.flatMap { (child.started...checked).contains($0) ? $0 : nil } ?? child.started
            if checked - lastSeen >= portForwarderHeartbeatTimeout {
                kill(child.pid, SIGKILL)
                children[directory]?.stopping = true
                note("Restarting unresponsive port forwarding for \(directory.lastPathComponent).")
            }
        }

        guard (try? checkPrivatePortDirectory(root)) != nil,
              let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where children[directory] == nil {
            do { try restore(directory, now: now) }
            catch { continue }
        }
    }

    private func readStatus(_ directory: URL) -> PortStatus? {
        try? readPortJSON(PortStatus.self, directory.appendingPathComponent("status.json"))
    }

    private func restore(_ directory: URL, now: TimeInterval) throws {
        try checkPrivatePortDirectory(directory)
        let config = try readPortConfiguration(directory)
        guard config.id == directory.lastPathComponent, config.target != nil, !config.mappings.isEmpty,
              try !forwarderIsRunning(directory) else { return }
        if let status = readStatus(directory), status.revision == config.revision, status.targetRejected == true { return }
        if files.fileExists(atPath: directory.appendingPathComponent("pending.json").path),
           try !portLockIsHeld(directory.appendingPathComponent("activation.lock")) { return }

        let log = try OwnedFD(open(directory.appendingPathComponent("helper.log").path,
                                   O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600))
        let null = try OwnedFD(open("/dev/null", O_RDWR | O_CLOEXEC))
        let pid = try spawnServiceProcess(executable, [directory.path, backend, String(getpid())],
                                          streams: [null.value, null.value, log.value])
        children[directory] = Child(pid: pid, started: now)
    }
}
