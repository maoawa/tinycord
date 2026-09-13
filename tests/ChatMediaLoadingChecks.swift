import Foundation
import CoreGraphics

@main
struct ChatMediaLoadingChecks {
    @MainActor
    static func main() async {
        let old = UUID(), upper = UUID(), lower = UUID(), cancelled = UUID()
        let frames = [old: CGRect(x: 0, y: -150, width: 100, height: 100),
                      upper: CGRect(x: 0, y: 20, width: 100, height: 50),
                      lower: CGRect(x: 0, y: 120, width: 100, height: 50),
                      cancelled: CGRect(x: 0, y: 80, width: 100, height: 20)]
        var layout = ChatMediaLayout(viewport: CGRect(x: 0, y: 0, width: 180, height: 200),
                                     media: frames)
        precondition(layout.next(in: [old, upper, lower]) == lower)
        precondition(!layout.isVisible(CGRect(x: 0, y: 200, width: 100, height: 20)))
        precondition(!layout.isVisible(.zero))
        precondition(!layout.isVisible(CGRect(x: 200, y: 0, width: 100, height: 20)))

        let loader = ChatMediaLoader()
        loader.update(layout)
        var started: [UUID] = []
        var running = 0
        var peakRunning = 0
        func request(_ id: UUID) -> Task<Void, Never> {
            Task { @MainActor in
                await loader.perform(id: id) {
                    started.append(id)
                    running += 1
                    peakRunning = max(peakRunning, running)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    running -= 1
                }
            }
        }
        let oldTask = request(old)
        let upperTask = request(upper)
        let lowerTask = request(lower)
        let cancelTask = request(cancelled)
        try? await Task.sleep(nanoseconds: 70_000_000)
        precondition(started.isEmpty, "Initial layout must not download older media before reaching bottom")
        cancelTask.cancel()
        await cancelTask.value
        layout.bottom = CGRect(x: 0, y: 190, width: 100, height: 1)
        loader.update(layout)
        await lowerTask.value
        await upperTask.value
        precondition(started == [lower, upper], "Visible items must load bottom-first; off-screen items stay pending")
        precondition(peakRunning == 1, "Downloads must not compete")

        // A lazily removed view has no geometry and must stay deferred.
        layout.media.removeValue(forKey: old)
        layout.viewport = CGRect(x: 0, y: -200, width: 180, height: 200)
        loader.update(layout)
        try? await Task.sleep(nanoseconds: 70_000_000)
        precondition(started == [lower, upper])
        layout.media[old] = frames[old]

        // Scrolling up admits old media, without requiring the bottom to remain visible.
        layout.viewport = CGRect(x: 0, y: -200, width: 180, height: 200)
        loader.update(layout)
        await oldTask.value
        precondition(started == [lower, upper, old])

        // A canceled pending URL must not cancel a replacement for the same view.
        let previous = request(upper)
        await Task.yield()
        previous.cancel()
        let replacement = request(upper)
        await previous.value
        layout.viewport = CGRect(x: 0, y: 0, width: 180, height: 200)
        loader.update(layout)
        await replacement.value
        precondition(started.last == upper && started.count == 4)
        print("Chat media visibility, bottom-first order, initial gating, serial loading, scrolling and cancellation checks passed.")
    }
}
