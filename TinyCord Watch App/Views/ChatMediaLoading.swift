import SwiftUI

struct ChatMediaLayoutKey: PreferenceKey {
    static let defaultValue = ChatMediaLayout()

    static func reduce(value: inout ChatMediaLayout, nextValue: () -> ChatMediaLayout) {
        let next = nextValue()
        if next.viewport != .zero { value.viewport = next.viewport }
        if next.bottom != .zero { value.bottom = next.bottom }
        value.media.merge(next.media) { _, new in new }
    }
}

private struct ChatMediaLoaderKey: EnvironmentKey {
    static let defaultValue: ChatMediaLoader? = nil
}

extension EnvironmentValues {
    var chatMediaLoader: ChatMediaLoader? {
        get { self[ChatMediaLoaderKey.self] }
        set { self[ChatMediaLoaderKey.self] = newValue }
    }
}

private struct VisibleMediaTask: ViewModifier {
    @Environment(\.chatMediaLoader) private var loader
    @State private var id = UUID()
    let url: URL?
    let operation: () async -> Void

    func body(content: Content) -> some View {
        content
            .background {
                if loader != nil {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ChatMediaLayoutKey.self,
                            value: ChatMediaLayout(media: [id: geometry.frame(in: .global)]))
                    }
                }
            }
            .task(id: url) {
                if let loader {
                    await loader.perform(id: id, operation: operation)
                } else {
                    await operation()
                }
            }
    }
}

extension View {
    func visibleMediaTask(url: URL?, operation: @escaping () async -> Void) -> some View {
        modifier(VisibleMediaTask(url: url, operation: operation))
    }
}
