import Foundation

/// Avatar hashes change when the image changes, so they do not need a TTL.
/// Keep a last-known image for offline use while a new hash is unavailable.
struct AvatarCacheIdentity {
    let key: String
    let fallbackKey: String
    let downloadURL: URL

    init?(_ url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.contains("/avatars/") || components.path.contains("/channel-icons/") else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != "size" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        guard let canonical = components.url else { return nil }
        key = canonical.absoluteString
        fallbackKey = components.path.contains("/embed/avatars/") ? key
            : canonical.deletingLastPathComponent().absoluteString + "last-known-avatar"
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "size", value: "128")]
        downloadURL = components.url ?? url
    }
}

final class AvatarCache: @unchecked Sendable {
    private let store: PersistentCacheStore
    init(root: URL = PersistentCacheStore.root) {
        store = PersistentCacheStore(directory: root.appendingPathComponent("avatars"), byteLimit: 12 * 1024 * 1024)
    }
    func data(for identity: AvatarCacheIdentity, fallback: Bool = false) -> Data? {
        store.read(fallback ? identity.fallbackKey : identity.key)
    }
    func save(_ data: Data, for identity: AvatarCacheIdentity) {
        store.write(data, key: identity.key)
        if identity.fallbackKey != identity.key { store.write(data, key: identity.fallbackKey) }
    }
    func remove(_ identity: AvatarCacheIdentity) { store.remove(identity.key) }
    func clear() { store.clear() }
    var size: Int { store.size }
}
