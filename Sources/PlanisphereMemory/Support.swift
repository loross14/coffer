import Foundation
import CoreFoundation
import CryptoKit
import CSQLite
import Darwin

public enum MemoryError: Error, CustomStringConvertible {
    case rejected(String)
    public var description: String { switch self { case .rejected(let message): return message } }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw MemoryError.rejected(message) }
}

func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MemoryError.rejected("Expected JSON object")
    }
    return result
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func token() -> String { UUID().uuidString.lowercased() }

func field(_ request: [String: Any], _ key: String, maximum: Int = 256) throws -> String {
    guard let value = request[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= maximum, !value.contains("\0") else {
        throw MemoryError.rejected("Missing or invalid \(key)")
    }
    return value
}

func integer(_ request: [String: Any], _ key: String, minimum: Int = 0, maximum: Int = 1_000_000) throws -> Int {
    guard let value = request[key] as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
          value.doubleValue.rounded() == value.doubleValue,
          value.doubleValue >= Double(minimum), value.doubleValue <= Double(maximum) else {
        throw MemoryError.rejected("Invalid \(key)")
    }
    return value.intValue
}

final class Database {
    private var db: OpaquePointer?
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        try require(sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, "Cannot open memory database")
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=DELETE")
        try exec("PRAGMA synchronous=FULL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA secure_delete=ON")
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ parameters: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        try require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Database statement failed")
        defer { sqlite3_finalize(statement) }
        for (index, value) in parameters.enumerated() {
            let code: Int32
            if let value {
                code = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else { code = sqlite3_bind_null(statement, Int32(index + 1)) }
            try require(code == SQLITE_OK, "Database bind failed")
        }
        var result = [[String: String]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            try require(code == SQLITE_ROW, "Database operation failed")
            var row = [String: String]()
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    func exec(_ sql: String, _ parameters: [String?] = []) throws { _ = try rows(sql, parameters) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
}

/// A private, explicitly configured memory directory. Requests cannot choose paths.
final class PrivateDirectory {
    let path: String
    let fd: Int32
    private let lockFD: Int32
    init(_ url: URL) throws {
        let path = url.path
        try require(path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "Absolute normalized directory required")
        // Walk descriptors so a symlink in any existing path component is rejected.
        var parent = open("/", O_RDONLY | O_DIRECTORY)
        try require(parent >= 0, "Cannot open filesystem root")
        do {
            for component in path.split(separator: "/") {
                let name = String(component)
                if mkdirat(parent, name, 0o700) != 0 { try require(errno == EEXIST, "Cannot create memory directory") }
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                try require(child >= 0, "Unsafe memory directory component: \(name), errno \(errno)")
                close(parent); parent = child
            }
            var info = stat()
            try require(fstat(parent, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o077 == 0,
                        "Memory root must be private and owned by this user")
            var lock = openat(parent, "store.lock", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            if lock < 0 && errno == EEXIST {
                lock = openat(parent, "store.lock", O_RDWR | O_NOFOLLOW)
            }
            try require(lock >= 0, "Cannot open memory lock, errno \(errno)")
            var lockInfo = stat()
            guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_nlink == 1 else {
                close(lock); throw MemoryError.rejected("Unsafe memory lock")
            }
            self.path = path; fd = parent; lockFD = lock
        } catch { close(parent); throw error }
    }
    deinit { close(lockFD); close(fd) }
    func locked<T>(_ body: () throws -> T) throws -> T {
        try require(flock(lockFD, LOCK_EX) == 0, "Cannot lock memory")
        defer { flock(lockFD, LOCK_UN) }
        var opened = stat(), current = stat()
        try require(fstat(fd, &opened) == 0 && lstat(path, &current) == 0 && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino,
                    "Memory directory identity changed")
        return try body()
    }
    func read(_ name: String) throws -> Data? {
        try require(!name.contains("/") && name != "." && name != "..", "Invalid internal file")
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        try require(file >= 0, "Unsafe managed file")
        defer { close(file) }
        var info = stat()
        try require(fstat(file, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_size <= 1_048_576,
                    "Unsafe or oversized managed file")
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            try require(count >= 0, "Managed read failed")
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            try require(data.count <= 1_048_576, "Managed file grew during read")
        }
        var after = stat(), named = stat()
        try require(fstat(file, &after) == 0 && fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                    info.st_ino == named.st_ino && info.st_size == after.st_size &&
                    info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                    "Managed file changed during read")
        return data
    }
    func publish(_ name: String, bytes: Data) throws {
        if let existing = try read(name) { try require(existing == bytes, "Projection conflict; user bytes preserved"); return }
        let temp = "pending-" + name
        if try read(temp) != nil { try require(unlinkat(fd, temp, 0) == 0, "Cannot retire partial projection") }
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(file >= 0, "Cannot stage projection")
        defer { close(file) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                try require(count > 0, "Projection write failed")
                offset += count
            }
        }
        try require(fsync(file) == 0, "Cannot sync projection")
        try require(renameatx_np(fd, temp, fd, name, UInt32(RENAME_EXCL)) == 0, "Projection appeared concurrently")
        try require(fsync(fd) == 0, "Cannot sync projection directory")
    }
    func remove(_ name: String, expected: String?) throws {
        guard let data = try read(name) else { return }
        if let expected { try require(digest(data) == expected, "Deletion conflict; edited projection preserved") }
        try require(unlinkat(fd, name, 0) == 0 && fsync(fd) == 0, "Cannot remove managed file")
    }
    // Caller holds the directory lock. Configuration replacement is atomic;
    // projections deliberately retain their stricter exclusive-create rule.
    func replaceConfiguration(_ bytes: Data) throws {
        _ = try read("connection.json")
        let staging = "configuration-" + token()
        try publish(staging, bytes: bytes)
        try require(renameat(fd, staging, fd, "connection.json") == 0 && fsync(fd) == 0, "Cannot save memory configuration")
    }
}
