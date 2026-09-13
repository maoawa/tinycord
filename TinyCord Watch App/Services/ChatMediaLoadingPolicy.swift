import Foundation
import CoreGraphics

/// Pure viewport policy, shared with the command-line regression checks.
struct ChatMediaLayout: Equatable {
    var viewport: CGRect = .zero
    var bottom: CGRect = .zero
    var media: [UUID: CGRect] = [:]

    func isVisible(_ frame: CGRect) -> Bool {
        guard viewport.width > 0, viewport.height > 0,
              frame.width > 0, frame.height > 0 else { return false }
        let overlap = viewport.intersection(frame)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }

    func next(in pending: Set<UUID>) -> UUID? {
        pending.filter { media[$0].map(isVisible) == true }.sorted {
            let left = media[$0]!, right = media[$1]!
            if left.maxY != right.maxY { return left.maxY > right.maxY }
            return $0.uuidString < $1.uuidString
        }.first
    }
}
