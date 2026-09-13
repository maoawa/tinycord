# TinyCord

<p align="center">
  <strong>A lightweight, standalone Discord client for Apple Watch with an iOS companion app.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/watchOS-10.0+-black?style=flat-square&logo=apple" alt="watchOS 10.0+" />
  <img src="https://img.shields.io/badge/iOS-17.0+-black?style=flat-square&logo=apple" alt="iOS 17.0+" />
  <img src="https://img.shields.io/badge/Swift-5.0+-orange?style=flat-square&logo=swift" alt="Swift 5.0+" />
  <img src="https://img.shields.io/badge/Dependencies-0-success?style=flat-square" alt="Zero Dependencies" />
  <img src="https://img.shields.io/badge/License-Proprietary-red?style=flat-square" alt="License Proprietary" />
</p>

---

## 📖 Overview

**TinyCord** brings Discord messaging to your wrist. Engineered natively with **SwiftUI** and modern Swift Concurrency, TinyCord operates as a fully independent watchOS client (`WKRunsIndependentlyOfCompanionApp`) that connects to Discord over HTTPS, with optional live updates and presence through TinyCord Companion, paired with an iOS companion app for effortless account setup and customization.

Whether you are on a run, in a meeting, or away from your phone, TinyCord gives you glanceable access to direct messages, real-time updates, voice recordings, photo sharing, and customizable quick replies.

---

## ✨ Features

### ⌚ Apple Watch Client

- **Standalone Operation**:
  - Uses HTTPS REST directly (or through your configured proxy). Optional TinyCord Companion supplies live events and presence over HTTPS.
  - Functions completely on Wi-Fi or Cellular without needing your iPhone nearby.
- **Direct & Group DMs**:
  - Browse conversations with real-time unread badges, typing indicators, and message snippet previews.
  - Swipe to mark conversations as read/unread.
- **Compose New Message & Friends List**:
  - Tap `+` on the home screen to access your Discord friends list.
  - **One-Tap Voice & Keyboard Search**: Search friends using watchOS dictation, scribble, or keyboard.
  - Instant direct message opening/creation.
- **Rich Messaging Experience**:
  - Full pagination of message history.
  - High-contrast, clean `@mention` styling (user, role, channel, and `@everyone` formatted in bold without distracting boxes).
  - Hyperlinks, Discord markdown formatting, and custom sticker rendering.
  - Reaction browser: inspect all emoji reactions and see who reacted; tap to add/toggle your own reactions.
- **Media & Attachments**:
  - In-line image previews with full-screen zoomable lightbox viewer (`PhotoDetailView`).
  - Audio playback directly on Apple Watch speaker or Bluetooth headphones.
- **Multiple Reply Modes**:
  - **Dictation & Keyboard**: Native watchOS text input.
  - **Quick Reply Presets**: One-tap pills or swipe actions for fast wrist replies.
  - **Photo Attachments**: Select and upload images straight from your watch Photos library.
  - **Voice Messages**: Record up to 60-second voice notes with real-time waveform visualization, playback preview, and native audio upload.
- **Personalization & Theming**:
  - 7 vibrant accent color themes (Discord Blurple, Emerald Green, Amber Gold, Coral Pink, Electric Violet, Ice Blue, Ruby Red).
  - Optional action button accenting.
  - Customizable conversation subtitles (snippets, handle, or unread status).
- **Custom Reverse Proxies & Relays**:
  - Switch between Discord Official endpoints and custom reverse proxies/CDNs directly from Watch Settings.

---

### 📱 iPhone Companion App

- **Discord Web Login**:
  - In-app embedded web login sheet (`WKWebView`) that captures your session token safely and securely on-device.
  - Credentials remain on your devices unless you configure a proxy or enable your own TinyCord Companion server.
- **User Profile Display**:
  - Real-time display of authenticated avatar, nickname, `@handle`, bot tag, and live connection status.
- **Token Management**:
  - Manual token entry with quick-paste support, visibility toggle, and credential testing tool.
- **Apple Watch Settings Management**:
  - Manage Quick Reply presets: add new phrases, swipe left to delete, swipe right to edit, or reset to factory defaults.
- **Custom Endpoints Management**:
  - Manage multiple API/CDN endpoint profiles with an optional TinyCord Companion toggle and HTTPS address (useful for restricted networks or private relay servers).
  - Default Discord Official profile is safely preserved.
- **One-Tap Watch Sync**:
  - Instant synchronization of authentication, endpoint configurations, and custom quick replies via Apple `WatchConnectivity`.

---

## 🛠️ Tech Stack

The Apple apps use **zero third-party dependencies**. The optional Ubuntu service uses Python/aiohttp, rlottie/Pillow, and Caddy:

| Area | Technologies |
| :--- | :--- |
| **Language** | Swift 5.0+ with modern `async`/`await` and `@MainActor` concurrency |
| **UI Framework** | SwiftUI (declarative state management, `NavigationStack`, `ToolbarItemGroup`, sheets) |
| **Networking** | Native `URLSession` HTTPS; server-side WebSocket via TinyCord Companion |
| **Media & Audio** | `AVFoundation` (`AVAudioRecorder`, `AVAudioPlayer`, `AVAudioSession`), `PhotosUI` |
| **Device Sync** | `WatchConnectivity` (`WCSession` with real-time messages & application context fallback) |
| **Authentication** | `WebKit` (`WKWebView` with cookie / header observation), `Security` (Keychain Services) |
| **Target Platforms** | watchOS 10.0+ / watchOS 11.0+, iOS 17.0+ / iOS 18.0+ |

---

## 🧠 Working Principle & Architecture

```mermaid
flowchart LR
    Phone[iPhone app] <-->|WatchConnectivity| Watch[Apple Watch]
    Watch -->|HTTPS REST| Discord[Discord / configured proxy]
    Watch <-->|HTTPS long polling| Companion[TinyCord Companion on Ubuntu]
    Companion <-->|WSS gateway| Gateway[Discord Gateway]
```

### 1. TinyCord Companion (`PresenceClient`)

- Physical watches use HTTPS only. They never create `URLSessionWebSocketTask` connections; watchOS restricts those for ordinary apps.
- Optional [TinyCord Companion](tinycord-companion/README.md) maintains the Discord WebSocket on Ubuntu and requests “Active on Apple Watch” with a mobile client identity for user sessions.
- Relays `MESSAGE_CREATE`, `MESSAGE_DELETE`, and `TYPING_START` using HTTPS long polling. REST polling continues if Companion is disabled or unavailable.
- The Watch renews its lease every three seconds while active and disconnects on leaving the app. Orphaned sessions expire after ten seconds, with cleanup checked every quarter second.
- Tokens are transient authentication input, discarded after IDENTIFY. Companion cannot reconnect without fresh authentication from the Watch. Presence appearance is controlled by Discord; the mobile indicator/activity is not guaranteed by a supported user-account API.
- To enable it, add/edit a custom endpoint profile on iPhone or Watch, turn on **TinyCord Companion**, and enter its `https://` origin. iPhone profiles sync both settings to the Watch. Existing profiles default to off.
- Voice recording plays the start cue, waits one second, then begins capture. Leaving the recorder during this pause cancels capture.

### 2. REST API Engine (`DiscordAPIClient`)
- Communicates with Discord v10 REST API endpoints using modern Swift `async`/`await`.
- Multi-part form-data generation for sending images (`image/jpeg`, `image/png`) and audio voice notes (`audio/m4a`).
- Resolves author mentions (`<@id>`), role mentions (`<@&id>`), channel mentions (`<#id>`), and nicknames on the fly.

### 3. Bidirectional Watch Connectivity
- `PhoneSyncService` (iOS) and `WatchSyncService` (watchOS) maintain a synchronized state of credentials, quick reply templates, and endpoint profiles.
- Uses `sendMessage` for instantaneous updates when both devices are actively connected, falling back to `updateApplicationContext` / `transferUserInfo` for queued background transfer.

---

## 🔒 Security & Privacy

- **Token handling**: Tokens are saved on your devices. REST sends them to Discord or your selected proxy; enabling TinyCord Companion also sends the token to that server over HTTPS for authentication. Companion never persists or logs it and does not retain it in session state. Transient process/TLS memory is unavoidable; use only a server you trust.
- **Traffic**: REST uses your selected API endpoints. Companion traffic uses HTTPS to your configured service; the service alone uses WSS to Discord or its operator-configured gateway proxy.
- **Zero Telemetry**: No third-party SDKs, analytics, ads, or tracking frameworks.
- **Export Compliance**: Uses standard HTTPS/TLS encryption only; `ITSAppUsesNonExemptEncryption` is explicitly declared as `NO`.

---

## 🚀 Getting Started

### Prerequisites

- **Mac** running macOS Sonoma 14.0 or later
- **Xcode 15.0+** or **Xcode 16.0+**
- **iOS Device / Simulator**: iOS 17.0 or later
- **Apple Watch / Simulator**: watchOS 10.0 or later
- An active Apple Developer Account (free or paid) for signing and running on physical hardware.

### Building & Running

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/maoawa/tinycord.git
   cd tinycord
   ```

2. **Open in Xcode**:
   ```bash
   open TinyCord.xcodeproj
   ```

3. **Configure Code Signing**:
   - In Xcode, select the **TinyCord** project in the Project Navigator.
   - For both targets (**TinyCord** and **TinyCord Watch App**):
     - Go to the **Signing & Capabilities** tab.
     - Select your Apple Developer Team.
     - Update the **Bundle Identifier** prefix if necessary.

4. **Select Target & Run**:
   - To test on Apple Watch: Select the **TinyCord Watch App** scheme and choose your paired Apple Watch or watchOS Simulator.
   - Press **Cmd + R** to build and launch!

---

## 📱 How to Log In

1. Launch **TinyCord** on your iPhone.
2. Tap **Log in with Discord Web**.
3. Complete authentication in the secure web view. TinyCord will automatically capture your session token and display your profile.
4. *(Alternatively)* Paste your token manually into the **Discord Credentials** section.
5. Tap **Test Connection** to verify.
6. Tap **Sync to Apple Watch** in the Apple Watch section to push your login and preferences directly to your watch.

---

## 📄 License

This software is **proprietary** and source-available for code review, personal evaluation, and security audit purposes only. No modifications, redistributions, reposting, or commercial use are permitted. See the [LICENSE](LICENSE) file for the full terms and restrictions.

---

## ⚠️ Disclaimer

TinyCord is an independent client and is **not** affiliated, associated, authorized, endorsed by, or in any way officially connected with Discord Inc. Discord and all related trademarks and logos are the registered trademarks of Discord Inc. Use at your own discretion in compliance with Discord Terms of Service.

### Chat media loading

Chat media waits for the initial scroll to the latest messages, then loads only
items intersecting the viewport, bottom-first and one at a time. Photos, animated
stickers/GIFs, avatars and link thumbnails share this policy. Older off-screen
media is deferred until you scroll to it; there is no history media prefetch.
Existing memory/disk caches are reused. Downloads already started while visible
may finish and cache their result after scrolling away. Explicitly opening a
photo uses the detail viewer independently of the chat queue.

Run `bash tests/check-chat-media.sh` to check viewport gating, bottom-first order,
serial loading, scroll admission and cancellation behavior.
