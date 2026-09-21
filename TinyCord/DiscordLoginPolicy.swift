import Foundation

/// Only the real Discord HTTPS document may deliver tokens or login events.
enum DiscordLoginPolicy {
    static func isDiscordOrigin(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "discord.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil && components.password == nil
    }

    /// Hints only: never reads, copies, logs, or submits password/OTP values.
    /// Discord replaces its form during MFA, so observe new inputs too.
    static let formSupportScript = #"""
    (() => {
        if (window.top !== window || location.origin !== 'https://discord.com') return;
        const update = (element, name, value) => {
            if (element.getAttribute(name) !== value) element.setAttribute(name, value);
        };
        const annotate = () => {
            if (!/^\/(login|mfa)(\/|$)/.test(location.pathname)) return;
            for (const input of document.querySelectorAll('input')) {
                const name = (input.getAttribute('name') || '').toLowerCase();
                const type = (input.getAttribute('type') || 'text').toLowerCase();
                const autocomplete = input.getAttribute('autocomplete') || '';
                if (type === 'hidden' || autocomplete.includes('new-password')) continue;
                if (type === 'password') {
                    update(input, 'autocomplete', 'current-password');
                } else if (['email', 'login', 'username'].includes(name)) {
                    update(input, 'autocomplete', 'username');
                    update(input, 'autocapitalize', 'none');
                    update(input, 'spellcheck', 'false');
                } else if (['code', 'mfa_code', 'totp'].includes(name) &&
                           ['text', 'number', 'tel'].includes(type)) {
                    update(input, 'autocomplete', 'one-time-code');
                }
            }
        };
        let scheduled = false;
        const schedule = () => {
            if (scheduled) return;
            scheduled = true;
            queueMicrotask(() => { scheduled = false; annotate(); });
        };
        const observer = new MutationObserver(schedule);
        observer.observe(document, {
            subtree: true, childList: true, attributes: true,
            attributeFilter: ['type', 'name', 'autocomplete']
        });
        document.addEventListener('focusin', annotate);
        schedule();

        // Observe WebAuthn only; never forward options, challenges or credentials.
        // Once per document prevents duplicate explanations from preparation + get.
        let explained = false;
        const explain = () => {
            if (explained) return;
            try {
                window.webkit.messageHandlers.discordLoginEvent.postMessage('passkey-unavailable');
                explained = true;
            } catch (_) { /* A missing native bridge must not affect authentication. */ }
        };
        const explicitRequest = options => options && options.publicKey &&
            options.mediation !== 'conditional' && options.mediation !== 'silent';
        const failed = (options, error) => {
            if (explicitRequest(options) && error && error.name !== 'AbortError') {
                explain();
            }
        };
        const credentials = navigator.credentials;
        if (credentials && typeof credentials.get === 'function') {
            const originalGet = credentials.get;
            credentials.get = function(options) {
                try {
                    return originalGet.call(this, options).catch(error => {
                        failed(options, error);
                        throw error;
                    });
                } catch (error) {
                    failed(options, error);
                    throw error;
                }
            };
        }

        // Discord's MFA button calls this parser BEFORE credentials.get. Older
        // WebKit versions lack it and Discord catches the resulting TypeError.
        // Preserve the undefined value for typeof checks; do not polyfill
        // WebAuthn or claim support. Only explain access during a user gesture,
        // excluding passive/conditional checks performed when the page loads.
        // Lazy-loaded MFA code can run after WebKit's transient activation has
        // expired (or on versions without navigator.userActivation). Remember a
        // recent real interaction, without inspecting the user's text or values.
        let lastInteraction = -Infinity;
        const rememberInteraction = event => {
            if (event.isTrusted) lastInteraction = Date.now();
        };
        document.addEventListener('click', rememberInteraction, true);
        document.addEventListener('keydown', rememberInteraction, true);
        const userInitiated = () => navigator.userActivation?.isActive === true ||
            Date.now() - lastInteraction < 30000;
        const publicKey = window.PublicKeyCredential;
        const parserName = 'parseRequestOptionsFromJSON';
        if (publicKey) {
            const originalParser = publicKey[parserName];
            if (typeof originalParser === 'function') {
                publicKey[parserName] = function(...args) {
                    try {
                        return originalParser.apply(this, args);
                    } catch (error) {
                        if (userInitiated()) explain();
                        throw error;
                    }
                };
            } else if (originalParser === undefined && !(parserName in publicKey)) {
                Object.defineProperty(publicKey, parserName, {
                    configurable: true,
                    get() {
                        if (userInitiated()) {
                            // Let Discord catch and render the failed invocation first.
                            setTimeout(explain, 0);
                        }
                        return undefined;
                    }
                });
            }
        }
    })();
    """#
}
