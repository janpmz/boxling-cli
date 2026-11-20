import Foundation
import Darwin
import CryptoKit

struct WorkspaceFileError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

struct WorkspaceFileEntry: Codable, Sendable, Equatable {
    var path: String
    var kind: String
    var bytes: Int64 = 0
    var modified: Double = 0
    var permissions: Int = 0o644
}

struct WorkspaceFileMessage: Codable, Sendable {
    var kind: String
    var path: String? = nil
    var names: [String]? = nil
    var entries: [WorkspaceFileEntry]? = nil
    var entry: WorkspaceFileEntry? = nil
    var message: String? = nil
    var skipped: Int? = nil
    var version: Int? = nil
    var text: String? = nil
    var revision: String? = nil
    var writable: Bool? = nil
    var recoveryPath: String? = nil
}

struct WorkspaceTextSnapshot: Codable, Sendable, Equatable {
    let text: String
    let revision: String
    let writable: Bool
    var exists: Bool { revision != "missing" }
    static let maximumBytes = 1_048_576

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw WorkspaceFileError("The editor supports text files up to 1 MB.") }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            throw WorkspaceFileError("This file contains binary data. Open a UTF-8 text file in the editor.")
        }
    }
}

struct WorkspaceTextSave: Sendable {
    let saved: Bool
    let snapshot: WorkspaceTextSnapshot
    let recoveryPath: String?
}

enum WorkspacePaths {
    static func absolute(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { throw WorkspaceFileError("Choose a path inside /workspace.") }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.first == "workspace", !parts.contains("..") else { throw WorkspaceFileError("Choose a path inside /workspace.") }
        return "/" + parts.filter { $0 != "." }.joined(separator: "/")
    }

    static func name(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
              !value.utf8.contains(0), value.utf8.count <= 255 else { throw WorkspaceFileError("Invalid file name.") }
        return value
    }

    static func transferPath(_ value: String) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "payload", parts.count <= 256 else { throw WorkspaceFileError("Invalid transfer path.") }
        for part in parts { _ = try name(String(part)) }
        return value
    }
}

/// Bounded JSON messages and raw file bytes share a private process pipe.
/// File contents never pass through a shell or a command-line argument.
final class WorkspaceFileStream {
    let input: Int32
    let output: Int32
    static let maximumMessageBytes = 16 * 1024 * 1024
    static let chunkBytes = 128 * 1024

    init(input: Int32, output: Int32) {
        self.input = input; self.output = output
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }

    func send(_ message: WorkspaceFileMessage) throws {
        let body = try JSONEncoder().encode(message)
        guard body.count <= Self.maximumMessageBytes else { throw WorkspaceFileError("This folder contains too many entries to display.") }
        var count = UInt32(body.count).bigEndian
        try write(Data(bytes: &count, count: 4))
        try write(body)
    }

    func receive() throws -> WorkspaceFileMessage? {
        guard let header = try read(4, allowEOF: true) else { return nil }
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Self.maximumMessageBytes else { throw WorkspaceFileError("Invalid file-browser response. Update the Boxling service and try again.") }
        return try JSONDecoder().decode(WorkspaceFileMessage.self, from: read(count)!)
    }

    func read(_ count: Int, allowEOF: Bool = false) throws -> Data? {
        guard count >= 0 else { throw WorkspaceFileError("Invalid transfer size.") }
        var data = Data(count: count), ended = false
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let result = Darwin.read(input, bytes.baseAddress!.advanced(by: offset), count - offset)
                if result < 0 && errno == EINTR { continue }
                if result == 0 && offset == 0 && allowEOF { ended = true; return }
                guard result > 0 else { throw WorkspaceFileError("The file-browser connection closed before the operation finished.") }
                offset += result
            }
        }
        return ended ? nil : data
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw WorkspaceFileError("The file-browser connection closed before the operation finished.") }
                offset += result
            }
        }
    }
}

enum WorkspaceFileTransfer {
    /// Enumerate all names, including dotfiles, without following symlinks.
    static func send(_ source: URL, to stream: WorkspaceFileStream, skipLinks: Bool,
                     progress: (Int64) -> Void = { _ in }) throws -> Int {
        var skipped = 0
        func visit(parent: Int32, name: String, path: String, depth: Int) throws {
            guard depth < 256 else { throw WorkspaceFileError("The folder exceeds 256 directory levels.") }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceFileError("Cannot read \(name.debugDescription).") }
            let folder = info.st_mode & S_IFMT == S_IFDIR
            if !folder && info.st_mode & S_IFMT != S_IFREG {
                if skipLinks && depth > 0 { skipped += 1; return }
                throw WorkspaceFileError("Transfers support regular files and folders; symlinks and special files cannot be transferred.")
            }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (folder ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw WorkspaceFileError("Cannot open \(name.debugDescription).") }
            defer { close(descriptor) }
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == (folder ? S_IFDIR : S_IFREG), info.st_size >= 0 else {
                throw WorkspaceFileError("The source changed during transfer.")
            }
            try stream.send(.init(kind: "entry", entry: .init(path: path, kind: folder ? "folder" : "file",
                bytes: folder ? 0 : Int64(info.st_size), modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                permissions: Int(info.st_mode & 0o777))))
            if folder {
                guard let listing = fdopendir(dup(descriptor)) else { throw WorkspaceFileError("Cannot list \(name.debugDescription).") }
                defer { closedir(listing) }
                var names: [String] = []
                errno = 0
                while let child = readdir(listing) {
                    let value = withUnsafePointer(to: &child.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
                    }
                    guard let value else { throw WorkspaceFileError("A file name is not valid UTF-8.") }
                    if value != "." && value != ".." { names.append(try WorkspacePaths.name(value)) }
                    errno = 0
                }
                guard errno == 0 else { throw WorkspaceFileError("Cannot finish listing \(name.debugDescription).") }
                for child in names.sorted() { try visit(parent: descriptor, name: child, path: path + "/" + child, depth: depth + 1) }
            } else {
                var remaining = Int64(info.st_size)
                let input = WorkspaceFileStream(input: descriptor, output: stream.output)
                while remaining > 0 {
                    let data = try input.read(Int(min(remaining, Int64(WorkspaceFileStream.chunkBytes))))!
                    try stream.write(data)
                    remaining -= Int64(data.count); progress(Int64(data.count))
                }
            }
        }
        try visit(parent: AT_FDCWD, name: source.path, path: "payload", depth: 0)
        try stream.send(.init(kind: "transferEnd", skipped: skipped))
        return skipped
    }

    /// Only newly created files/directories are accepted inside private staging.
    static func receive(from stream: WorkspaceFileStream, into staging: URL,
                        progress: (Int64) -> Void = { _ in }) throws -> (URL, Int) {
        var seen = Set<String>(), directories = Set<String>()
        var folderMetadata: [(URL, WorkspaceFileEntry)] = []
        func restoreMetadata(_ target: URL, _ entry: WorkspaceFileEntry) throws {
            try FileManager.default.setAttributes([.posixPermissions: entry.permissions,
                .modificationDate: Date(timeIntervalSince1970: entry.modified)], ofItemAtPath: target.path)
        }
        while let message = try stream.receive() {
            if message.kind == "transferEnd" {
                guard seen.contains("payload") else { throw WorkspaceFileError("The transfer was empty.") }
                // Apply directory modes last, so read-only folders can receive
                // their children without relaxing the private staging parent.
                for (target, entry) in folderMetadata.reversed() { try restoreMetadata(target, entry) }
                return (staging.appendingPathComponent("payload"), message.skipped ?? 0)
            }
            guard message.kind == "entry", let entry = message.entry,
                  entry.bytes >= 0, (0...0o777).contains(entry.permissions), entry.modified.isFinite,
                  (-62_135_596_800...253_402_300_799).contains(entry.modified) else { throw WorkspaceFileError("Invalid transfer entry.") }
            let path = try WorkspacePaths.transferPath(entry.path)
            let parent = (path as NSString).deletingLastPathComponent
            guard seen.insert(path).inserted, path == "payload" || directories.contains(parent),
                  seen.count != 1 || path == "payload" else { throw WorkspaceFileError("Invalid or duplicate transfer path.") }
            let target = staging.appendingPathComponent(path)
            switch entry.kind {
            case "folder":
                guard entry.bytes == 0 else { throw WorkspaceFileError("Invalid folder size in transfer.") }
                guard mkdir(target.path, 0o700) == 0 else { throw WorkspaceFileError("Cannot create downloaded folder \(target.lastPathComponent.debugDescription).") }
                directories.insert(path)
                folderMetadata.append((target, entry))
            case "file":
                let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw WorkspaceFileError("Cannot create downloaded file \(target.lastPathComponent.debugDescription).") }
                defer { close(descriptor) }
                let output = WorkspaceFileStream(input: stream.input, output: descriptor)
                var remaining = entry.bytes
                while remaining > 0 {
                    let data = try stream.read(Int(min(remaining, Int64(WorkspaceFileStream.chunkBytes))))!
                    try output.write(data)
                    remaining -= Int64(data.count); progress(Int64(data.count))
                }
                try restoreMetadata(target, entry)
            default: throw WorkspaceFileError("The transfer contains a link or unsupported file type.")
            }
        }
        throw WorkspaceFileError("The transfer ended before all files arrived.")
    }

    static func publish(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw WorkspaceFileError("Cannot save \(destination.lastPathComponent.debugDescription). An item may already exist there; nothing was replaced.")
        }
    }
}
