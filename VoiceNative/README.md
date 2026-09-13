# Watch voice dependencies

Outgoing calls use Discord's MIT-licensed **libdave**, Cisco **mlspp**,
**BoringSSL**, **nlohmann/json**, and Xiph **Opus**. Exact upstream commit IDs are
pinned in `scripts/fetch-voice-native.py`. The Watch bundles their license texts
in `ThirdPartyLicenses`. No server-side audio processing or key storage is used.

Install CMake and Ninja (`brew install cmake ninja`) and use Python 3.12+.
The Watch target's **Build Voice Native** phase downloads the pinned sources
on its first build and compiles static libraries for each requested architecture.
Downloads require network access; subsequent builds reuse the local sources.
Sources and build products under this directory are ignored by Git.

```bash
bash scripts/build-voice-native.sh watchos arm64_32
bash scripts/build-voice-native.sh watchos arm64
bash scripts/build-voice-native.sh watchsimulator arm64
bash tests/check-voice.sh
```

The test runs on an Apple Silicon Mac. It uses libdave's test external sender to
establish a real two-member MLS group, checks that media waits for the matching
transition, round-trips Opus through DAVE and RTP AES-GCM, checks rejection of the removed XChaCha mode
and tamper rejection, and exercises jitter sequence wraparound.
It does not contact Discord or use account credentials. Test-only support is
excluded from the Watch archive.

`CMakeLists.txt` builds the native source files with libdave's required
`mlspp` namespace, BoringSSL backend, disabled GREASE, and ephemeral identities.
Assembly is disabled for portability across arm64 and arm64_32. `prepare-voice-crypto.py` generates copies of two pinned BoringSSL source files
without XChaCha/HChaCha definitions. The originals remain untouched. No XChaCha
shim or fallback is linked; native archives are checked for those symbols.
Calls require the server's AES-GCM RTP mode. DAVE/MLS still uses bundled standard
cryptography, so removal of XChaCha does not make the app OS-encryption-only.

The remaining DAVE/MLS libraries still implement standard cryptography outside
Apple's operating system. Removing XChaCha does not make this an HTTPS-only app.
Review the encryption declaration and distribution requirements for the actual
submitted build. This change does not set `ITSAppUsesNonExemptEncryption` or an
Apple-issued compliance code.
See [Apple's encryption guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
