# Outgoing Watch call prototype

Open a one-to-one DM, tap the phone icon, then confirm **Call** in the system alert.
CallKit presents the call screen; there is no separate TinyCord call page.
During a call the phone button offers native mute/end controls. After audio activation
and Discord's confirmation of the DM join, TinyCord requests ringing while the
separate voice-server/UDP/encryption negotiation continues.
Calls implement microphone audio, received audio, mute, and hangup.
The prototype requires a user account and does not handle incoming calls, group
DMs, guild voice channels, automatic reconnection, or video.

## Connection ownership

The normal messaging architecture is unchanged: REST uses HTTPS, and optional
Companion owns live messages, typing, and requested presence. The Watch creates
no WebSocket at login, on foreground activation, or for settings connection tests.

CallKit creates an outgoing call and activates its audio session before
`VoiceCallTransport` opens any socket. That transport owns:

1. A temporary **main Discord Gateway** connection using the profile's call
   Gateway URL. It sends the voice-state join and consumes voice negotiation
   events. It does not publish chat events or send presence/activity updates.
2. A separate **Voice Gateway** connection to the Discord-provided voice endpoint.
3. A UDP connection for IP discovery and encrypted RTP audio.

Both WebSockets and UDP close on hangup, CallKit reset/deactivation, connection
failure, logout, or endpoint/credential changes. The main Gateway has no resume
or retry loop. Discord controls the visible status of concurrent sessions;
check presence alongside a live call with a second account.

Companion retains its existing three-second renewal and ten-second foreground
lease. Wrist-down/background does not extend that lease for a call. CallKit and
the Watch app's `UIBackgroundModes: [audio, voip]` own the independent call lifecycle.
Companion's HTTPS messaging fallback and sticker endpoint stay available.

## Endpoints

In the iPhone profile editor, edit **Voice Call Gateway**. On Watch, select a
custom profile and use **Endpoints → Configure Call Gateway**. Host auto-fill
generates `wss://gateway.<base-host>/?v=10&encoding=json` again. The field remains
part of WatchConnectivity profile sync and legacy profile decoding; a blank
value uses Discord's official Gateway. Only WSS is accepted. The app normalizes
Gateway version 10 and JSON encoding and disables compressed Gateway streams.

The custom main Gateway proxy does **not** proxy the separate Voice Gateway or
UDP audio. These connect directly to Discord's negotiated servers. A network
that blocks Discord voice traffic may still load chats and connect to the main
Gateway while calls fail. Deployment addresses do not belong in this repository.

## Media and encryption

Capture is converted to 48 kHz stereo, encoded as 20 ms Opus frames, encrypted
on the Watch by libdave, and wrapped in RTP transport encryption. AES-256-GCM is
the only supported RTP transport. XChaCha20-Poly1305 has been removed; if the
server does not advertise AES-GCM, the call fails with a compatibility message. A bounded
60 ms jitter warmup reorders received frames and uses Opus loss concealment.
Incoming PCM is pulled by an AVAudioSourceNode at the audio engine's sample clock,
with a short buffered runway; packet duration determines decoded sample count.
Capture uses the actual tap buffer format, explicitly converts to planar 48 kHz
stereo and interleaves the channels for Opus. Whole tap buffers enter a bounded
FIFO, then a monotonic clock emits one 20 ms packet per slot. Large tap callbacks
must not burst packets or discard everything beyond three frames. Muted/dropped
slots advance RTP time; executor stalls never trigger catch-up packet bursts.
Capture, playback, and network queues have limits to avoid unbounded latency.

MLS keys are ephemeral. Audio is not sent before a verified DAVE transition,
and there is no plaintext downgrade. An empty call may temporarily negotiate
transport-only mode while ringing; media stays disabled until DAVE is ready.
The first prototype terminates on
unsupported protocol changes or voice-server migration; start a fresh call.

Build prerequisites and synthetic tests: [VoiceNative](../VoiceNative/README.md).

## Physical Watch acceptance checks

Simulator/build success is not evidence that watchOS allows the live transport.
Use two test accounts and a physical Watch before treating this as working call
support. Do not ring other users as an automated test.

- With no call active, verify that Watch traffic remains HTTPS-only and online
  status/live messages work through Companion.
- Use headphones for the first outgoing call; confirm the second account rings,
  both directions of audio work, and mute/hangup work from the Watch and system UI.
- Lower the wrist, navigate away from the call view, and return. Confirm the call
  persists only while CallKit owns active audio. Measure battery use and latency.
- Exercise Wi-Fi and cellular with the paired iPhone unavailable, route changes,
  another system call, loss of UDP/WSS, and remote hangup. A failed call must stop
  capture and sockets and require an explicit new Call tap.
- Log out or sync a different active profile mid-call; verify immediate teardown.
- Check presence and message delivery while the direct call Gateway and Companion
  coexist. Main-Gateway chat events must never enter the message publishers.

User-account Gateway/voice integration remains unofficial. The synthetic tests
validate the native media stack, not Discord's current acceptance of a user
IDENTIFY, DM voice-state request, or ringing endpoint.

## CallKit rejects the start request

`com.apple.CallKit.error.requesttransaction`, code 1, means CallKit denied the
app's call access. On watchOS the Watch app must declare **audio** and **voip**
in **UIBackgroundModes**. `WKBackgroundModes` is for Watch-specific activities
such as workouts and extended-runtime sessions; `WKBackgroundModes: [audio]`
does not grant CallKit VoIP access. In this failure state neither call Gateway
has connected, so changing the proxy cannot resolve it.

Rebuild and reinstall the Watch app after changing `Configuration/Watch-Info.plist`.
Check the installed app's plist, not just the source. CallKit logs should no
longer show `hasVoIPBackgroundMode=0` or reject creation of its call source.

## Stuck waiting for call audio in Simulator

The watchOS 27 simulator can accept and fulfill `CXStartCallAction` while its
system call service fails to activate audio. Observed logs report
`Unsupported property: kAudioSessionPropertyXPC_HostProcessAttribution` followed
by `Error setting audio active to true` / `NSOSStatusErrorDomain Code=-50`.
In that state CallKit never invokes `provider(_:didActivate:)`, neither
WebSocket opens, and Discord receives no join or ring request. Changing the
Gateway endpoint cannot fix a failure that occurs before any network connection.

TinyCord shows the audio-wait stage and ends it after 15 seconds with a specific
simulator/device explanation. Microphone permission is requested before that
deadline starts. Call startup milestones use the `VoiceCall` OSLog category
under `com.candyrect.tinycord`; logs contain no tokens, peer IDs, or payloads.
Verify ringing and two-way audio on a physical Watch. Do not bypass the audio
activation gate to make simulator networking appear to work.

## System call interface

The outgoing call already uses the public CallKit provider and transaction APIs,
including recipient metadata and connecting/connected/ended reports. Mute and
hangup from TinyCord also pass through CallKit. CallKit owns system presentation;
its public watchOS API does not expose a command to force the Phone call screen
to open. TinyCord uses a SwiftUI system alert to confirm outgoing calls, a native
confirmation dialog for mute/end, and an alert for failures after returning to
the app. There is no custom in-call page. Verify system presentation on hardware as part
of the acceptance checks above.

## Audio engine fails after CallKit activation

On hardware, a native call screen followed by TinyCord's audio-start error means
CallKit activated audio but local audio setup failed before a Gateway opened.
The audio engine is created after activation. Both I/O nodes are initialized
before requesting voice processing, and the mixer output matches the duplex
I/O format; Opus conversion remains 48 kHz stereo independently of the route.

If voice-processing setup or engine start throws, TinyCord destroys the failed
graph and makes one attempt with normal audio I/O. Use headphones if the app
shows the fallback notice, since that path does not provide engine echo
cancellation. Missing input/output routes fail without retrying. Errors retain
the failing stage and NSError domain/code, without framework payloads. The
`VoiceAudio` log category records formats and fallback diagnostics. This recovery
path requires hardware verification; a successful build or injected failure test
does not prove that a particular Watch audio route works.

## Crash when the Voice Gateway starts on arm64_32

Apple Watch Series 7 uses the arm64_32 ABI, where Swift `Int` is 32 bits. The
original Voice Gateway heartbeat converted Unix milliseconds (about 1.8 trillion)
to `Int`, which traps on that hardware even though it succeeds in a 64-bit
simulator. A crash after joining the DM can leave Discord showing a joinable
call until the disconnected session is cleaned up by the server.

Heartbeat timestamps now use `Int64` through JSON serialization. The regression
test verifies exact millisecond values beyond the 32-bit range, including beyond
2038. Device builds must include arm64_32; simulator tests alone cannot reproduce
that ABI's integer overflow. A device crash report is still needed to confirm
that this was the termination reason for a particular installed build.

## Audio quality and ringing timing checks

Synthetic tests feed 24 kHz mono and 44.1/48 kHz stereo tones through the actual
capture converter and verify duration, pitch, channel separation and retention
of every 20 ms frame from large callbacks. Renderer tests verify sample order
across variable render sizes and silence on underrun. Device acceptance still
needs both speakers, microphones and Bluetooth routes tested in a real call.
Call stage logs include elapsed time from the Call tap so audio activation,
Gateway login, DM join, ring HTTP and voice negotiation delays can be separated.
Earlier ringing removes voice negotiation from the wait before notification;
it does not guarantee a specific startup time on every network.

## Foreground presence and setup concurrency

An inactive scene (including wrist-down or a dimmed foreground display) preserves
the current Companion session. Entering the background disconnects it. Ordinary
presence remains HTTPS-only, with the existing three-second renewal and ten-second
lease. If watchOS suspends execution, the server cannot distinguish that from a
lost Watch; it still expires the lease. No silent audio or background call is
started to retain presence.

After CallKit activates audio, the call Gateway starts immediately while audio
engine configuration runs on a separate serial queue. Connection is only reported
when both audio startup and DAVE negotiation have completed. This removes local
audio setup from the sequential path to ringing; actual network and activation
latencies still need to be measured on hardware.
