import Foundation
import CryptoKit
import Darwin

// Descriptor-relative operations keep symlink checks attached to the object used.
// This is protection against unsafe paths and ordinary competing writers, not a
// security boundary against a process with the same user's unrestricted access.
internal enum VaultFS {
    static let metadataLimit = 64 * 1024 * 1024
    static let symbolicLinkLimit = 64 * 1024
    final class Handle {
        let fd: Int32
        init(_ fd: Int32) throws {
            guard fd >= 0 else { throw unavailable("Could not open the requested file") }
            self.fd = fd
        }
        deinit { Darwin.close(fd) }
    }

    struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    static func unavailable(_ message: String) -> VaultStoreError {
        let code = errno
        return .unavailable("\(message) (\(String(cString: strerror(code)))).")
    }

    static func absolute(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw VaultStoreError.invalid("Use an absolute folder path without traversal components.")
        }
        return url
    }

    static func relative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.utf8.contains(0), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VaultStoreError.corrupt("unsafe relative path")
        }
    }

    // Conservative for portability: reject case/Unicode aliases even on a
    // case-sensitive source volume, because a restore may use ordinary APFS.
    static func portablePathKey(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func contains(_ ancestor: URL, _ candidate: URL) -> Bool {
        let a = portablePathKey(ancestor.path), b = portablePathKey(candidate.path)
        return b == a || b.hasPrefix(a + "/")
    }

    static func canonicalURL(_ directory: Handle) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory.fd, F_GETPATH, &buffer) == 0 else { throw unavailable("Could not identify the opened folder") }
        guard let path = buffer.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else { throw VaultStoreError.invalid("Folder path is not valid UTF-8.") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func sameDirectory(_ first: Handle, _ second: Handle) throws -> Bool {
        let a = try info(first), b = try info(second)
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    static func containsDirectory(_ ancestor: Handle, _ candidate: Handle) throws -> Bool {
        var current = candidate
        // Descriptors resolve firmlinks/mount aliases as actual filesystem objects.
        for _ in 0..<4096 {
            if try sameDirectory(ancestor, current) { return true }
            let parent = try Handle(openat(current.fd, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            if try sameDirectory(current, parent) { return false }
            current = parent
        }
        throw VaultStoreError.invalid("Folder nesting exceeds the supported limit.")
    }

    static func directory(_ url: URL, create: Bool = false) throws -> Handle {
        let url = try absolute(url)
        var current = try Handle(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for component in url.pathComponents.dropFirst() {
            if create {
                if mkdirat(current.fd, component, 0o700) == 0 { try sync(current.fd) }
                else if errno != EEXIST { throw unavailable("Could not create a folder") }
            }
            let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw VaultStoreError.invalid("A folder is unavailable or uses a symbolic link: \(url.path)")
            }
            current = try Handle(next)
        }
        return current
    }

    static func childDirectory(_ parent: Handle, _ name: String, create: Bool = false) throws -> Handle {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw VaultStoreError.corrupt("unsafe directory name")
        }
        if create {
            if mkdirat(parent.fd, name, 0o700) == 0 { try sync(parent.fd) }
            else if errno != EEXIST { throw unavailable("Could not create a history folder") }
        }
        return try Handle(openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    static func info(_ handle: Handle) throws -> stat {
        var result = stat()
        guard fstat(handle.fd, &result) == 0 else { throw unavailable("Could not inspect a file") }
        return result
    }

    static func entryInfo(_ parent: Handle, _ name: String) throws -> stat? {
        var result = stat()
        if fstatat(parent.fd, name, &result, AT_SYMLINK_NOFOLLOW) == 0 { return result }
        if errno == ENOENT { return nil }
        throw unavailable("Could not inspect a directory entry")
    }

    static func validateSymbolicLinkTarget(_ data: Data) throws {
        guard !data.isEmpty, data.count <= symbolicLinkLimit, !data.contains(0) else {
            throw VaultStoreError.corrupt("invalid symbolic-link target bytes")
        }
    }

    /// Read the link entry itself. Never open or resolve its target.
    static func readSymbolicLink(_ parent: Handle, _ name: String) throws -> Data {
        guard let before = try entryInfo(parent, name), (before.st_mode & S_IFMT) == S_IFLNK else {
            throw VaultStoreError.changedDuringCapture
        }
        var bytes = [UInt8](repeating: 0, count: symbolicLinkLimit + 1)
        let count = bytes.withUnsafeMutableBytes { readlinkat(parent.fd, name, $0.baseAddress!, $0.count) }
        guard count >= 0 else { throw unavailable("Could not read a symbolic link") }
        let data = Data(bytes.prefix(count))
        try validateSymbolicLinkTarget(data)
        guard let after = try entryInfo(parent, name), Stamp(before) == Stamp(after) else {
            throw VaultStoreError.changedDuringCapture
        }
        return data
    }

    /// Used only after regular entries have been materialized with no-follow parents.
    static func createSymbolicLink(_ data: Data, parent: Handle, name: String) throws {
        try validateSymbolicLinkTarget(data)
        var terminated = Array(data)
        terminated.append(0)
        let result = terminated.withUnsafeBytes {
            symlinkat($0.baseAddress!.assumingMemoryBound(to: CChar.self), parent.fd, name)
        }
        guard result == 0 else { throw unavailable("Could not restore a symbolic link") }
    }

    static func names(_ directory: Handle) throws -> [String] {
        // A fresh open description avoids sharing the directory's iteration offset.
        let descriptor = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable("Could not enumerate a folder") }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor); throw unavailable("Could not enumerate a folder")
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw unavailable("Could not complete folder enumeration") }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw VaultStoreError.invalid("A filename is not valid UTF-8.") }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }

    static func sync(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw unavailable("Could not durably save data") }
    }

    static func writeAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw unavailable("Could not write data") }
            offset += count
        }
    }

    static func stream(_ source: Handle, destination: Int32? = nil, limit: Int64? = nil) throws -> (digest: String, size: Int64) {
        guard (try info(source).st_mode & S_IFMT) == S_IFREG else { throw VaultStoreError.invalid("Only regular files can be read.") }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw unavailable("Could not read a file") }
            if count == 0 { break }
            total += Int64(count)
            if let limit, total > limit { throw VaultStoreError.corrupt("file exceeds its declared size") }
            try buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(rebasing: bytes[..<count])
                hasher.update(bufferPointer: chunk)
                if let destination { try writeAll(destination, chunk) }
            }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ parent: Handle, _ name: String, maximum: Int = metadataLimit) throws -> Data {
        let file = try Handle(openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC))
        let before = try info(file)
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0, before.st_size <= maximum else {
            throw VaultStoreError.corrupt("invalid or oversized metadata file")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw unavailable("Could not read history metadata") }
            if count == 0 { break }
            guard result.count + count <= maximum else { throw VaultStoreError.corrupt("metadata grew during reading") }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard Stamp(before) == Stamp(try info(file)), result.count == before.st_size else {
            throw VaultStoreError.corrupt("metadata changed during reading")
        }
        return result
    }

    static func atomicData(_ data: Data, parent: Handle, name: String, replace: Bool, maximumBytes: Int = metadataLimit) throws {
        guard data.count <= maximumBytes else { throw VaultStoreError.invalid("History metadata exceeds the current 64 MiB limit.") }
        let temporary = ".pending-" + UUID().uuidString
        let file = try Handle(openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        defer { unlinkat(parent.fd, temporary, 0) }
        try data.withUnsafeBytes { try writeAll(file.fd, $0) }
        try sync(file.fd)
        if replace {
            if let existing = try entryInfo(parent, name), (existing.st_mode & S_IFMT) != S_IFREG {
                throw VaultStoreError.corrupt("metadata destination is not a regular file")
            }
            guard renameat(parent.fd, temporary, parent.fd, name) == 0 else { throw unavailable("Could not publish metadata") }
        } else {
            guard renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
                throw unavailable("Could not publish an immutable file")
            }
        }
        try sync(parent.fd)
    }

    static func publishDirectory(parent: Handle, temporary: String, destination: String) throws {
        guard renameatx_np(parent.fd, temporary, parent.fd, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw VaultStoreError.invalid("The destination appeared or could not be created. Nothing there was overwritten.")
        }
        try sync(parent.fd)
    }
}
