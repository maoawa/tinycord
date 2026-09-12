//
//  DiscordLoginWebView.swift
//  TinyCord
//

import SwiftUI
import WebKit

public struct DiscordLoginWebView: UIViewRepresentable {
    public let loginURL: URL
    public let onTokenCaptured: (String) -> Void
    public let onLoadingChanged: ((Bool) -> Void)?

    public init(
        loginURL: URL = URL(string: "https://discord.com/login")!,
        onTokenCaptured: @escaping (String) -> Void,
        onLoadingChanged: ((Bool) -> Void)? = nil
    ) {
        self.loginURL = loginURL
        self.onTokenCaptured = onTokenCaptured
        self.onLoadingChanged = onLoadingChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onTokenCaptured: onTokenCaptured, onLoadingChanged: onLoadingChanged)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "discordTokenHandler")

        // Interception script: hooks XMLHttpRequest, fetch, WebSocket, and localStorage
        let scriptSource = """
        (function() {
            function notifyToken(raw) {
                if (!raw || typeof raw !== 'string') return;
                let token = raw.trim().replace(/^"|"$/g, '');
                if (token.startsWith('Bot ')) return;
                // Basic check for Discord token length & structure
                if (token.length >= 24) {
                    window.webkit.messageHandlers.discordTokenHandler.postMessage(token);
                }
            }

            // 1. Hook XMLHttpRequest setRequestHeader
            const origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
                if (header && header.toLowerCase() === 'authorization') {
                    notifyToken(value);
                }
                return origSetRequestHeader.apply(this, arguments);
            };

            // 2. Hook window.fetch
            const origFetch = window.fetch;
            window.fetch = function(input, init) {
                if (init && init.headers) {
                    let auth = null;
                    if (init.headers instanceof Headers) {
                        auth = init.headers.get('authorization') || init.headers.get('Authorization');
                    } else if (Array.isArray(init.headers)) {
                        for (let i = 0; i < init.headers.length; i++) {
                            if (init.headers[i][0] && init.headers[i][0].toLowerCase() === 'authorization') {
                                auth = init.headers[i][1];
                                break;
                            }
                        }
                    } else if (typeof init.headers === 'object') {
                        for (let k in init.headers) {
                            if (k.toLowerCase() === 'authorization') {
                                auth = init.headers[k];
                                break;
                            }
                        }
                    }
                    if (auth) {
                        notifyToken(auth);
                    }
                }
                return origFetch.apply(this, arguments);
            };

            // 3. Hook WebSocket send (Gateway IDENTIFY payload)
            const origSend = WebSocket.prototype.send;
            WebSocket.prototype.send = function(data) {
                try {
                    if (typeof data === 'string' && data.includes('"token"')) {
                        const parsed = JSON.parse(data);
                        if (parsed && parsed.d && parsed.d.token) {
                            notifyToken(parsed.d.token);
                        }
                    }
                } catch (e) {}
                return origSend.apply(this, arguments);
            };

            // 4. Periodic localStorage inspection fallback
            let checks = 0;
            const timer = setInterval(function() {
                checks++;
                if (checks > 90) clearInterval(timer);
                try {
                    const stored = window.localStorage.getItem('token');
                    if (stored) notifyToken(stored);
                } catch (e) {}
            }, 1000);
        })();
        """

        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(userScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Use Desktop Safari User-Agent so Discord presents the full web app with QR code scanning and direct login
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        let request = URLRequest(url: loginURL)
        webView.load(request)

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "discordTokenHandler")
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onTokenCaptured: (String) -> Void
        let onLoadingChanged: ((Bool) -> Void)?
        private var hasCaptured = false

        init(
            onTokenCaptured: @escaping (String) -> Void,
            onLoadingChanged: ((Bool) -> Void)?
        ) {
            self.onTokenCaptured = onTokenCaptured
            self.onLoadingChanged = onLoadingChanged
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !hasCaptured else { return }
            if message.name == "discordTokenHandler", let tokenStr = message.body as? String {
                let clean = tokenStr.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                guard clean.count >= 24 else { return }
                hasCaptured = true
                DispatchQueue.main.async {
                    self.onTokenCaptured(clean)
                }
            }
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChanged?(true)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged?(false)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged?(false)
        }
    }
}
