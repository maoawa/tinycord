# Accounts and login

On Apple Watch, open **Settings → Accounts** to add, switch, or remove saved accounts. With more than one saved account, the profile picture also shows a small switch badge. Tap the picture to open the picker. Add tokens directly on the watch or sign into another account on iPhone and sync it. Each iPhone login uses a fresh browser session so it can capture a different account.

Watch tokens are stored together in the device-only Keychain. The old single token migrates on first launch; its UserDefaults copy is removed only after a successful Keychain write. Removing an account deletes its saved token and snippets from the watch. **Log Out** removes the active account and returns to login; other saved accounts remain available. This does not revoke a token at Discord or remove the copy on iPhone.

Account switching resets the chat navigation and connection, ends calls through the existing credential-change handler, and rejects requests/results associated with the previous account. Message snippets are separated by account and API endpoint. Repeated iPhone syncs of a known token do not switch away from the account selected on the watch. New verified tokens for the same Discord user replace older saved entries after the watch fetches the user profile.

The passkey explanation observes WebAuthn failures rather than translated error messages. It now remembers a recent trusted interaction to cover Discord's asynchronous MFA preparation after transient browser activation expires. Authentication outcomes remain unchanged. A real-device check is still needed for the reported Discord error.

## Account warnings and request behavior

There is no guarantee against Discord account restrictions when using an unofficial client with a user token. Account switching does not address that risk. Use Discord's official app for ordinary user-account activity and its supported bot/OAuth APIs for integrations. If Discord reports a compromised account, review sessions and authorized apps, reset the password through the official site/app, enable MFA, and review every service that has received the account token.

CAPTCHA responses now show a readable verification message, with no claim that opening Discord completes the pending challenge. Voice messages fall back to ordinary audio only after an explicit invalid-flags response, not after authentication errors, CAPTCHA, rate limits, or ambiguous delivery failures. Polling stops on rejected credentials or CAPTCHA. iPhone automatic sync waits for a successful debounced credential check instead of saving partially typed tokens.

## Checks

- `bash tests/check-accounts.sh`: migration, persistence failures, switching, profile isolation, stale HTTP responses, CAPTCHA, and retry isolation using synthetic credentials and a mocked transport.
- `bash tests/check-discord-login.sh`: origin isolation, AutoFill hints, preservation of WebAuthn behavior, delayed preparation, and passive/synthetic interaction exclusions.
- Live device checks: add two accounts, switch via the avatar, restart the watch app, remove one account, and repeat the reported passkey attempt. No live-account actions are performed by these tests.

## Official guidance checked

Discord's **Automated User Accounts (Self-Bots)** article states that automating normal user accounts outside its OAuth2/bot API is forbidden and can lead to account termination. This establishes a risk for user-token integrations; it does not establish the cause of a particular account restriction.

Discord's **My Discord Account was Hacked or Compromised** article recommends resetting the password, enabling MFA, and reviewing/removing unwanted Authorized Apps.

Sources:
- https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots
- https://support.discord.com/hc/en-us/articles/24160905919511-My-Discord-Account-was-Hacked-or-Compromised
