import Foundation
import CryptoKit

/// Bounded, atomic disk storage. Reads renew recency; age alone never expires
/// offline content. Application Support avoids the OS purging it as temporary data.
final class PersistentCacheStore: @unchecked Sendable {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TinyCordOffline", isDirectory: true)
    let directory: URL
    private let byteLimit: Int
    private static let diskLock = NSRecursiveLock()
    private var lock: NSRecursiveLock { Self.diskLock }

    init(directory: URL, byteLimit: Int) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent(Self.key(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    @discardableResult
    func write(_ data: Data, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= byteLimit else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            try data.write(to: directory.appendingPathComponent(Self.key(key)), options: .atomic)
            prune()
            return true
        } catch {
            // Disk pressure must not prevent viewing or sending a message.
            return false
        }
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.key(key)))
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    var size: Int {
        lock.lock(); defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.size }
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? []
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
    }

    private func prune() {
        let files = entries().sorted { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > byteLimit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    static func removeAccount(_ id: UUID) {
        diskLock.lock(); defer { diskLock.unlock() }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("accounts/\(id.uuidString)"))
    }
}
