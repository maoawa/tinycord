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
    private let diskCacheURL: URL // Legacy cache, migrated lazily on read.
    private let mediaDiskStore = PersistentCacheStore(directory: PersistentCacheStore.root.appendingPathComponent("media"), byteLimit: 50 * 1024 * 1024)
    private let avatarCache = AvatarCache()

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

        Task.detached(priority: .background) { [weak self] in
            self?.migrateLegacyCache()
        }
    }

    /// Derives a stable cache key from a URL.
    /// For Discord attachments, normalizes by stripping ephemeral signature tokens (`ex`, `is`, `hm`)
    /// so identical files are not re-downloaded when Discord refreshes URL tokens.
    public func cacheKey(for url: URL) -> String {
        if let avatar = AvatarCacheIdentity(url) { return sha256Hex(avatar.key) }
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
        mediaDiskStore.remove(key)
        if let identity = AvatarCacheIdentity(url) { avatarCache.remove(identity) }

        let unproxied = Self.unwrapProxiedURL(url)
        if unproxied != url {
            let unKey = cacheKey(for: unproxied)
            dataMemoryCache.removeObject(forKey: unKey as NSString)
            imageMemoryCache.removeObject(forKey: unKey as NSString)
            try? fileManager.removeItem(at: diskFileURL(for: unKey))
            mediaDiskStore.remove(unKey)
        }
    }

    // MARK: - Asynchronous Loading

    public func fetchMedia(from rawURL: URL) async -> MediaLoadResult {
        let url = AvatarCacheIdentity(rawURL)?.downloadURL ?? Self.unwrapProxiedURL(rawURL)
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

        // 2. Persistent disk cache, with migration from earlier releases.
        if let diskData = cachedDiskData(for: url, key: key) {
            dataMemoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
            return .success(data: diskData, resolvedURL: url != rawURL ? url : nil)
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
                if let diskData = cachedDiskData(for: direct, key: directKey) {
                    dataMemoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
                    return .success(data: diskData, resolvedURL: direct)
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

                // Do not persist successful HTTP responses that are invalid avatars.
                if AvatarCacheIdentity(url) != nil && UIImage(data: data) == nil {
                    return .failure(MediaLoadFailure(url: rawURL, errorDescription: "Invalid avatar image"))
                }
                self?.dataMemoryCache.setObject(data as NSData, forKey: nsKey, cost: data.count)
                self?.saveDiskData(data, for: url, key: key)
                if targetURL != url, let self {
                    let directKey = self.cacheKey(for: targetURL)
                    self.dataMemoryCache.setObject(data as NSData, forKey: directKey as NSString, cost: data.count)
                    self.saveDiskData(data, for: targetURL, key: directKey)
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
        guard let data = await loadData(from: url) else {
            return offlineImage(for: url)
        }

        guard let image = UIImage(data: data) else {
            evictCache(for: url)
            return offlineImage(for: url)
        }

        // Cache image object in memory
        let cost = Int(image.size.width * image.size.height * 4)
        imageMemoryCache.setObject(image, forKey: nsKey, cost: cost)

        return image
    }

    /// Used before the visible-media network queue so an offline avatar appears
    /// immediately and stays visible while refreshing a changed avatar hash.
    public func offlineImage(for url: URL) -> UIImage? {
        if let image = imageFromMemory(for: url) { return image }
        guard let identity = AvatarCacheIdentity(url) else { return nil }
        if let data = cachedDiskData(for: url, key: cacheKey(for: url)), let image = UIImage(data: data) {
            imageMemoryCache.setObject(image, forKey: cacheKey(for: url) as NSString,
                                      cost: Int(image.size.width * image.size.height * 4))
            return image
        }
        return avatarCache.data(for: identity, fallback: true).flatMap { UIImage(data: $0) }
    }

    private func cachedDiskData(for url: URL, key: String) -> Data? {
        if let identity = AvatarCacheIdentity(url), let data = avatarCache.data(for: identity) {
            if UIImage(data: data) != nil { return data }
            avatarCache.remove(identity)
        }
        if let identity = AvatarCacheIdentity(url) {
            // Older releases keyed avatars by the complete URL, including size.
            // Recover those files even on the first launch of this version offline.
            for size in [128, 64] {
                var components = URLComponents(url: identity.downloadURL, resolvingAgainstBaseURL: false)!
                components.queryItems = (components.queryItems ?? []).filter { $0.name != "size" }
                    + [URLQueryItem(name: "size", value: String(size))]
                let legacyKey = sha256Hex(components.url!.absoluteString)
                if let data = mediaDiskStore.read(legacyKey) ?? (try? Data(contentsOf: diskFileURL(for: legacyKey))),
                   UIImage(data: data) != nil {
                    avatarCache.save(data, for: identity)
                    return data
                }
            }
        }
        if let data = mediaDiskStore.read(key) {
            if !isLikelyHTML(data), !data.isEmpty { return data }
            mediaDiskStore.remove(key)
        }
        let legacy = diskFileURL(for: key)
        guard let data = try? Data(contentsOf: legacy) else { return nil }
        defer { try? fileManager.removeItem(at: legacy) }
        guard !isLikelyHTML(data), !data.isEmpty else { return nil }
        saveDiskData(data, for: url, key: key)
        return data
    }

    private func saveDiskData(_ data: Data, for url: URL, key: String) {
        if let identity = AvatarCacheIdentity(url) {
            if UIImage(data: data) != nil { avatarCache.save(data, for: identity) }
        } else {
            mediaDiskStore.write(data, key: key)
        }
    }

    private func migrateLegacyCache() {
        let files = (try? fileManager.contentsOfDirectory(at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let oldestFirst = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in oldestFirst {
            guard let data = try? Data(contentsOf: file) else { continue }
            if isLikelyHTML(data) || data.isEmpty || mediaDiskStore.write(data, key: file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Disk Cache Management

    public func clearCache() {
        imageMemoryCache.removeAllObjects()
        dataMemoryCache.removeAllObjects()
        avatarCache.clear()
        mediaDiskStore.clear()
        try? fileManager.removeItem(at: diskCacheURL)
    }

    public func diskCacheSizeInBytes() -> Int64 {
        let legacyFiles = (try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let legacySize = legacyFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return Int64(avatarCache.size + mediaDiskStore.size + legacySize)
    }

    public func formattedDiskCacheSize() -> String {
        ByteCountFormatter.string(fromByteCount: diskCacheSizeInBytes(), countStyle: .file)
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
