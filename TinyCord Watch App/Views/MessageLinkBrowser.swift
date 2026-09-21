import AuthenticationServices
import Combine
import SwiftUI

/// Keeps the system browser session alive while the user reads a message link.
@MainActor
private final class MessageLinkBrowser: ObservableObject {
    private var session: ASWebAuthenticationSession?
    private var sessionID: UUID?
    @Published var errorMessage: String?

    func open(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .systemAction
        }

        session?.cancel()
        errorMessage = nil
        let id = UUID()
        sessionID = id
        // No callback is expected: the user ends this browsing session with Done.
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.session = nil
                self.sessionID = nil
                if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    self.errorMessage = "The web browser could not open this link. Please try again."
                }
            }
        }
        session = browser
        if !browser.start() {
            session = nil
            sessionID = nil
            errorMessage = "The web browser is unavailable. Please try again."
        }
        return .handled
    }
}

struct MessageLinkBrowserModifier: ViewModifier {
    @StateObject private var browser = MessageLinkBrowser()

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { browser.open($0) })
            .alert("Unable to Open Link", isPresented: Binding(
                get: { browser.errorMessage != nil },
                set: { if !$0 { browser.errorMessage = nil } }
            )) {
                Button("Dismiss", role: .cancel) { browser.errorMessage = nil }
            } message: {
                Text(browser.errorMessage ?? "")
            }
    }
}
