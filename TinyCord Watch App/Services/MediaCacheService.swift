//
//  MediaCacheService.swift
//  TinyCord Watch App
//

import Foundation
import UIKit
import CryptoKit

// MARK: - Media Diagnostic Types

public struct MediaLoadFailure: Identifiable, Sendable {
    public var id: String { url.absoluteString + (resolvedURL?.absoluteString ?? "") }
    public let url: URL
    public let resolvedURL: URL?
    public let httpStatusCode: Int?
    public let mimeType: String?
    public let dataLength: Int?
    public let errorDescription: String
    public let dataSnippet: String?
    public let timestamp: Date

    public init(
        url: URL,
        resolvedURL: URL? = nil,
        httpStatusCode: Int? = nil,
        mimeType: String? = nil,
        dataLength: Int? = nil,
        errorDescription: String,
        dataSnippet: String? = nil,
        timestamp: Date = Date()
    ) {
        self.url = url
        self.resolvedURL = resolvedURL
        self.httpStatusCode = httpStatusCode
        self.mimeType = mimeType
        self.dataLength = dataLength
        self.errorDescription = errorDescription
        self.dataSnippet = dataSnippet
        self.timestamp = timestamp
    }
}

public enum MediaLoadResult: Sendable {
    case success(data: Data, resolvedURL: URL?)
    case failure(MediaLoadFailure)
}

public final class MediaCacheService: @unchecked Sendable {
    public static let shared = MediaCacheService()

    private let imageMemoryCache = NSCache<NSString, UIImage>()
    private let dataMemoryCache = NSCache<NSString, NSData>()

    private let fileManager = FileManager.default
    private let diskCacheURL: URL

    private let lock = NSLock()
    private var inFlightTasks: [String: Task<MediaLoadResult, Never>] = [:]

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

    // MARK: - Helpers

    public static func unwrapProxiedURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host.contains("images-ext") || host.contains("discordapp") else {
            return url
        }
        let path = url.path
        if let range = path.range(of: "/https/") {
            let unproxied = "https://" + path[range.upperBound...]
            if let unwrapped = URL(string: unproxied) {
                return unwrapped
            }
        } else if let range = path.range(of: "/http/") {
            let unproxied = "http://" + path[range.upperBound...]
            if let unwrapped = URL(string: unproxied) {
                return unwrapped
            }
        }
        return url
    }

    private func isLikelyHTML(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let prefix = String(decoding: data.prefix(120), as: UTF8.self).lowercased()
        return prefix.contains("<!doctype") || prefix.contains("<html") || prefix.contains("<head") || prefix.contains("<body")
    }

    public func evictCache(for url: URL) {
        let key = cacheKey(for: url)
        dataMemoryCache.removeObject(forKey: key as NSString)
        imageMemoryCache.removeObject(forKey: key as NSString)
        let fileURL = diskFileURL(for: key)
        try? fileManager.removeItem(at: fileURL)

        let unproxied = Self.unwrapProxiedURL(url)
        if unproxied != url {
            let unKey = cacheKey(for: unproxied)
            dataMemoryCache.removeObject(forKey: unKey as NSString)
            imageMemoryCache.removeObject(forKey: unKey as NSString)
            try? fileManager.removeItem(at: diskFileURL(for: unKey))
        }
    }

    // MARK: - Asynchronous Loading

    public func fetchMedia(from rawURL: URL) async -> MediaLoadResult {
        let url = Self.unwrapProxiedURL(rawURL)
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // 1. Check memory cache
        if let memoryData = dataMemoryCache.object(forKey: nsKey) as Data? {
            if !isLikelyHTML(memoryData) {
                return .success(data: memoryData, resolvedURL: url != rawURL ? url : nil)
            } else {
                dataMemoryCache.removeObject(forKey: nsKey)
            }
        }

        // 2. Check disk cache
        let fileURL = diskFileURL(for: key)
        if fileManager.fileExists(atPath: fileURL.path),
           let diskData = try? Data(contentsOf: fileURL) {
            if isLikelyHTML(diskData) {
                print("[TinyCord Media] Evicting corrupt HTML error from disk cache for \(url)")
                try? fileManager.removeItem(at: fileURL)
            } else {
                dataMemoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
                return .success(data: diskData, resolvedURL: url != rawURL ? url : nil)
            }
        }

        // 3. Resolve Klipy webpage URLs if needed
        var targetURL = url
        if KlipyResolver.shared.isKlipyWebURL(url) {
            print("[TinyCord Media] Resolving Klipy webpage URL: \(url)")
            let klipyResult = await KlipyResolver.shared.resolveDirectMediaURLWithDiagnostics(from: url)
            switch klipyResult {
            case .success(let direct):
                print("[TinyCord Media] Klipy resolved \(url) -> \(direct)")
                targetURL = direct

                // Check cache for resolved direct media
                let directKey = cacheKey(for: direct)
                let directNsKey = directKey as NSString
                if let memoryData = dataMemoryCache.object(forKey: directNsKey) as Data?, !isLikelyHTML(memoryData) {
                    dataMemoryCache.setObject(memoryData as NSData, forKey: nsKey, cost: memoryData.count)
                    return .success(data: memoryData, resolvedURL: direct)
                }
                let directDiskURL = diskFileURL(for: directKey)
                if fileManager.fileExists(atPath: directDiskURL.path),
                   let diskData = try? Data(contentsOf: directDiskURL) {
                    if isLikelyHTML(diskData) {
                        try? fileManager.removeItem(at: directDiskURL)
                    } else {
                        dataMemoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
                        return .success(data: diskData, resolvedURL: direct)
                    }
                }

            case .failure(let reason):
                let failure = MediaLoadFailure(
                    url: rawURL,
                    resolvedURL: nil,
                    httpStatusCode: nil,
                    mimeType: nil,
                    dataLength: nil,
                    errorDescription: "Klipy: \(reason)",
                    dataSnippet: nil
                )
                print("[TinyCord Media] Klipy resolution failed: \(reason)")
                return .failure(failure)
            }
        }

        // 4. Deduplicate in-flight network requests
        let targetKey = cacheKey(for: targetURL)
        lock.lock()
        if let ongoing = inFlightTasks[targetKey] {
            lock.unlock()
            return await ongoing.value
        }

        let downloadTask = Task<MediaLoadResult, Never> { [weak self] () -> MediaLoadResult in
            defer {
                self?.lock.lock()
                self?.inFlightTasks.removeValue(forKey: targetKey)
                self?.lock.unlock()
            }

            var request = URLRequest(url: targetURL)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("image/*,video/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    let fail = MediaLoadFailure(
                        url: rawURL,
                        resolvedURL: targetURL,
                        httpStatusCode: nil,
                        mimeType: nil,
                        dataLength: data.count,
                        errorDescription: "Invalid response from server",
                        dataSnippet: nil
                    )
                    return .failure(fail)
                }

                guard (200...299).contains(http.statusCode) else {
                    let snippet = String(data: data.prefix(150), encoding: .utf8)
                    let statusText = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    let fail = MediaLoadFailure(
                        url: rawURL,
                        resolvedURL: targetURL,
                        httpStatusCode: http.statusCode,
                        mimeType: http.mimeType,
                        dataLength: data.count,
                        errorDescription: "HTTP \(http.statusCode) (\(statusText))",
                        dataSnippet: snippet
                    )
                    print("[TinyCord Media] HTTP failure \(http.statusCode) for \(targetURL)")
                    return .failure(fail)
                }

                if self?.isLikelyHTML(data) == true {
                    let snippet = String(data: data.prefix(150), encoding: .utf8)
                    let fail = MediaLoadFailure(
                        url: rawURL,
                        resolvedURL: targetURL,
                        httpStatusCode: http.statusCode,
                        mimeType: http.mimeType ?? "text/html",
                        dataLength: data.count,
                        errorDescription: "Received HTML webpage instead of image",
                        dataSnippet: snippet
                    )
                    print("[TinyCord Media] Server returned HTML for \(targetURL)")
                    return .failure(fail)
                }

                // Cache in memory
                self?.dataMemoryCache.setObject(data as NSData, forKey: nsKey, cost: data.count)

                // Cache on disk asynchronously
                if let diskURL = self?.diskFileURL(for: key) {
                    try? data.write(to: diskURL, options: .atomic)
                }

                // Also cache under direct media key if redirected
                if targetURL != url, let self {
                    let directKey = self.cacheKey(for: targetURL)
                    self.dataMemoryCache.setObject(data as NSData, forKey: directKey as NSString, cost: data.count)
                    let directDiskURL = self.diskFileURL(for: directKey)
                    try? data.write(to: directDiskURL, options: .atomic)
                }

                print("[TinyCord Media] Successfully loaded \(data.count) bytes for \(targetURL)")
                return .success(data: data, resolvedURL: targetURL != rawURL ? targetURL : nil)
            } catch {
                let fail = MediaLoadFailure(
                    url: rawURL,
                    resolvedURL: targetURL,
                    httpStatusCode: nil,
                    mimeType: nil,
                    dataLength: nil,
                    errorDescription: error.localizedDescription,
                    dataSnippet: nil
                )
                print("[TinyCord Media] Network error for \(targetURL): \(error.localizedDescription)")
                return .failure(fail)
            }
        }

        inFlightTasks[targetKey] = downloadTask
        lock.unlock()

        return await downloadTask.value
    }

    public func loadData(from url: URL) async -> Data? {
        switch await fetchMedia(from: url) {
        case .success(let data, _):
            return data
        case .failure:
            return nil
        }
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

// MARK: - Klipy Resolver

public enum KlipyResolveResult: Sendable {
    case success(URL)
    case failure(reason: String)
}

public final class KlipyResolver: @unchecked Sendable {
    public static let shared = KlipyResolver()
    private let cache = NSCache<NSString, NSURL>()

    private init() {
        cache.countLimit = 100
    }

    public func isKlipyURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("klipy.com")
    }

    public func isKlipyWebURL(_ url: URL) -> Bool {
        guard isKlipyURL(url) else { return false }
        if let host = url.host?.lowercased(), host.contains("static") {
            return false
        }
        let pathLower = url.path.lowercased()
        return pathLower.contains("/gif") || pathLower.contains("/sticker") || pathLower.contains("/clip")
    }

    public func extractSlug(from url: URL) -> String? {
        guard isKlipyURL(url) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if let idx = parts.firstIndex(where: {
            let l = $0.lowercased()
            return l == "gifs" || l == "gif" || l == "stickers" || l == "sticker" || l == "clips" || l == "clip"
        }), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    public func resolveDirectMediaURLWithDiagnostics(from url: URL) async -> KlipyResolveResult {
        guard let slug = extractSlug(from: url) else {
            if let host = url.host?.lowercased(), host.contains("static") {
                return .success(url)
            }
            return .failure(reason: "Cannot parse slug from URL path '\(url.path)'")
        }

        let nsSlug = slug as NSString
        if let cached = cache.object(forKey: nsSlug) as URL? {
            return .success(cached)
        }

        guard let apiURL = URL(string: "https://api.klipy.com/api/v1/gifs/\(slug)") else {
            return .failure(reason: "Malformed Klipy API URL for slug '\(slug)'")
        }

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(reason: "Invalid non-HTTP response from Klipy API")
            }

            guard (200...299).contains(http.statusCode) else {
                return .failure(reason: "Klipy API returned HTTP \(http.statusCode)")
            }

            struct KlipyResponse: Decodable {
                struct DataObj: Decodable {
                    struct FileObj: Decodable {
                        struct MediaObj: Decodable {
                            struct Item: Decodable {
                                let url: String
                            }
                            let gif: Item?
                            let webp: Item?
                        }
                        let sm: MediaObj?
                        let md: MediaObj?
                        let hd: MediaObj?
                    }
                    let file: FileObj?
                }
                let data: DataObj?
            }

            let decoded: KlipyResponse
            do {
                decoded = try JSONDecoder().decode(KlipyResponse.self, from: data)
            } catch {
                return .failure(reason: "Failed to parse Klipy API JSON: \(error.localizedDescription)")
            }

            let candidateString = decoded.data?.file?.sm?.gif?.url
                ?? decoded.data?.file?.md?.gif?.url
                ?? decoded.data?.file?.hd?.gif?.url
                ?? decoded.data?.file?.sm?.webp?.url
                ?? decoded.data?.file?.md?.webp?.url

            if let candidateString, let resolved = URL(string: candidateString) {
                cache.setObject(resolved as NSURL, forKey: nsSlug)
                return .success(resolved)
            } else {
                return .failure(reason: "No GIF or WebP candidate found in Klipy API response")
            }
        } catch {
            return .failure(reason: "Network error contacting Klipy API: \(error.localizedDescription)")
        }
    }

    public func resolveDirectMediaURL(from url: URL) async -> URL? {
        switch await resolveDirectMediaURLWithDiagnostics(from: url) {
        case .success(let directURL): return directURL
        case .failure: return nil
        }
    }
}
