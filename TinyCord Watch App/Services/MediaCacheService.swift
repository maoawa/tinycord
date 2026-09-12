//
//  MediaCacheService.swift
//  TinyCord Watch App
//

import Foundation
import UIKit
import CryptoKit

public final class MediaCacheService: @unchecked Sendable {
    public static let shared = MediaCacheService()

    private let imageMemoryCache = NSCache<NSString, UIImage>()
    private let dataMemoryCache = NSCache<NSString, NSData>()

    private let fileManager = FileManager.default
    private let diskCacheURL: URL

    private let lock = NSLock()
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]

    private init() {
        // Configure memory cache limits suited for Apple Watch (watchOS RAM budget)
        imageMemoryCache.countLimit = 120
        imageMemoryCache.totalCostLimit = 25 * 1024 * 1024 // 25 MB

        dataMemoryCache.countLimit = 50
        dataMemoryCache.totalCostLimit = 20 * 1024 * 1024 // 20 MB

        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskCacheURL = cachesDirectory.appendingPathComponent("TinyCordMediaCache", isDirectory: true)

        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Perform background cleanup of stale files (> 7 days)
        Task.detached(priority: .background) { [weak self] in
            self?.pruneDiskCacheIfNeeded()
        }
    }

    /// Derives a stable cache key from a URL.
    /// For Discord attachments, normalizes by stripping ephemeral signature tokens (`ex`, `is`, `hm`)
    /// so identical files are not re-downloaded when Discord refreshes URL tokens.
    public func cacheKey(for url: URL) -> String {
        let urlString = url.absoluteString

        // For Discord attachments, use host + path as canonical key
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let host = components.host,
           host.contains("discordapp") || host.contains("discord.com"),
           components.path.contains("/attachments/") {
            let canonical = "\(host)\(components.path)".lowercased()
            return sha256Hex(canonical)
        }

        return sha256Hex(urlString)
    }

    private func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskFileURL(for key: String) -> URL {
        diskCacheURL.appendingPathComponent(key)
    }

    // MARK: - Synchronous Memory Lookups (Zero UI latency)

    public func imageFromMemory(for url: URL) -> UIImage? {
        let key = cacheKey(for: url) as NSString
        return imageMemoryCache.object(forKey: key)
    }

    public func dataFromMemory(for url: URL) -> Data? {
        let key = cacheKey(for: url) as NSString
        return dataMemoryCache.object(forKey: key) as Data?
    }

    // MARK: - Asynchronous Loading

    public func loadData(from url: URL) async -> Data? {
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // 1. Check memory cache
        if let memoryData = dataMemoryCache.object(forKey: nsKey) as Data? {
            return memoryData
        }

        // 2. Check disk cache
        let fileURL = diskFileURL(for: key)
        if fileManager.fileExists(atPath: fileURL.path),
           let diskData = try? Data(contentsOf: fileURL) {
            dataMemoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
            return diskData
        }

        // 3. Deduplicate in-flight network requests
        lock.lock()
        if let ongoing = inFlightTasks[key] {
            lock.unlock()
            return await ongoing.value
        }

        let downloadTask = Task<Data?, Never> { [weak self] () -> Data? in
            defer {
                self?.lock.lock()
                self?.inFlightTasks.removeValue(forKey: key)
                self?.lock.unlock()
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return nil
                }

                // Cache in memory
                self?.dataMemoryCache.setObject(data as NSData, forKey: nsKey, cost: data.count)

                // Cache on disk asynchronously
                if let diskURL = self?.diskFileURL(for: key) {
                    try? data.write(to: diskURL, options: .atomic)
                }

                return data
            } catch {
                return nil
            }
        }

        inFlightTasks[key] = downloadTask
        lock.unlock()

        return await downloadTask.value
    }

    public func loadImage(from url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // Check memory
        if let img = imageMemoryCache.object(forKey: nsKey) {
            return img
        }

        // Load data (from disk or network)
        guard let data = await loadData(from: url) else { return nil }

        guard let image = UIImage(data: data) else { return nil }

        // Cache image object in memory
        let cost = Int(image.size.width * image.size.height * 4)
        imageMemoryCache.setObject(image, forKey: nsKey, cost: cost)

        return image
    }

    // MARK: - Disk Cache Management

    public func clearCache() {
        imageMemoryCache.removeAllObjects()
        dataMemoryCache.removeAllObjects()

        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    public func diskCacheSizeInBytes() -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for file in contents {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = attrs.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func formattedDiskCacheSize() -> String {
        let bytes = diskCacheSizeInBytes()
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    private func pruneDiskCacheIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let now = Date()
        let maxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        var totalSize: Int64 = 0
        var fileList: [(url: URL, date: Date, size: Int64)] = []

        for file in files {
            guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = vals.contentModificationDate,
                  let size = vals.fileSize else { continue }

            let s = Int64(size)
            if now.timeIntervalSince(date) > maxAge {
                try? fileManager.removeItem(at: file)
            } else {
                totalSize += s
                fileList.append((url: file, date: date, size: s))
            }
        }

        // If total size exceeds 50MB, prune oldest files
        let maxTotalSize: Int64 = 50 * 1024 * 1024
        if totalSize > maxTotalSize {
            fileList.sort { $0.date < $1.date }
            for entry in fileList {
                try? fileManager.removeItem(at: entry.url)
                totalSize -= entry.size
                if totalSize <= maxTotalSize / 2 {
                    break
                }
            }
        }
    }
}
