import Foundation
import Combine

/// One visible media load at a time. Views created speculatively by LazyVStack
/// cannot start network work. Initial layout must reach the latest messages first.
@MainActor
final class ChatMediaLoader: ObservableObject {
    private var layout = ChatMediaLayout()
    private var reachedBottom = false
    private struct Request {
        let mediaID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var pending: [UUID: Request] = [:]
    private var active: UUID?
    private var dispatchTask: Task<Void, Never>?

    func update(_ layout: ChatMediaLayout) {
        self.layout = layout
        if layout.isVisible(layout.bottom) { reachedBottom = true }
        schedule()
    }

    func perform(id: UUID, operation: () async -> Void) async {
        let ticket = UUID() // URL changes/retries must not cancel a previous waiter.
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pending[ticket] = Request(mediaID: id, continuation: continuation)
                schedule()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: ticket)?.continuation.resume(returning: false)
            }
        }
        guard granted else { return }
        // Already-started shared cache downloads may finish when scrolled away;
        // never cancel another view's request for the same URL.
        if !Task.isCancelled { await operation() }
        if active == ticket { active = nil }
        schedule()
    }

    private func schedule() {
        guard reachedBottom, active == nil, dispatchTask == nil else { return }
        dispatchTask = Task { [weak self] in
            // Gather this layout's image tasks before choosing the bottommost.
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self else { return }
            self.dispatchTask = nil
            var candidates = self.layout
            candidates.media = self.pending.reduce(into: [:]) { frames, entry in
                frames[entry.key] = self.layout.media[entry.value.mediaID]
            }
            guard self.active == nil,
                  let ticket = candidates.next(in: Set(self.pending.keys)) else { return }
            self.active = ticket
            self.pending.removeValue(forKey: ticket)?.continuation.resume(returning: true)
        }
    }
}
