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
    public let onPasskeyUnavailable: (() -> Void)?

    public init(
        loginURL: URL = URL(string: "https://discord.com/login")!,
        onTokenCaptured: @escaping (String) -> Void,
        onLoadingChanged: ((Bool) -> Void)? = nil,
        onPasskeyUnavailable: (() -> Void)? = nil
    ) {
        self.loginURL = loginURL
        self.onTokenCaptured = onTokenCaptured
        self.onLoadingChanged = onLoadingChanged
        self.onPasskeyUnavailable = onPasskeyUnavailable
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onTokenCaptured: onTokenCaptured, onLoadingChanged: onLoadingChanged,
                    onPasskeyUnavailable: onPasskeyUnavailable)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "discordTokenHandler")
        contentController.add(context.coordinator, name: "discordLoginEvent")
        contentController.addUserScript(WKUserScript(source: DiscordLoginPolicy.formSupportScript,
                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Interception script: hooks XMLHttpRequest, fetch, WebSocket, and localStorage
        let scriptSource = """
        (function() {
            if (window.top !== window || location.origin !== 'https://discord.com') return;
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
            forMainFrameOnly: true
        )
        contentController.addUserScript(userScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // A fresh login can add another account instead of immediately capturing
        // the previously signed-in account from persistent website cookies.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Keep WebKit's real iPhone identity and the actual HTTPS origin. A fake
        // desktop Safari UA cannot grant AutoFill or passkey domain association.
        let request = URLRequest(url: DiscordLoginPolicy.isDiscordOrigin(loginURL)
                                 ? loginURL : URL(string: "https://discord.com/login")!)
        webView.load(request)

        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "discordTokenHandler")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "discordLoginEvent")
    }

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onTokenCaptured: (String) -> Void
        let onLoadingChanged: ((Bool) -> Void)?
        let onPasskeyUnavailable: (() -> Void)?
        private var hasCaptured = false

        init(
            onTokenCaptured: @escaping (String) -> Void,
            onLoadingChanged: ((Bool) -> Void)?,
            onPasskeyUnavailable: (() -> Void)?
        ) {
            self.onTokenCaptured = onTokenCaptured
            self.onLoadingChanged = onLoadingChanged
            self.onPasskeyUnavailable = onPasskeyUnavailable
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !hasCaptured, message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == "discord.com",
                  [0, 443].contains(message.frameInfo.securityOrigin.port),
                  DiscordLoginPolicy.isDiscordOrigin(message.frameInfo.request.url),
                  DiscordLoginPolicy.isDiscordOrigin(message.webView?.url) else { return }
            if message.name == "discordLoginEvent", message.body as? String == "passkey-unavailable" {
                onPasskeyUnavailable?()
                return
            }
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

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChanged?(false)
        }
    }
}
