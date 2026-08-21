# Entanglo

Compact macOS app for connecting multiple Macs on the same LAN with shared
keyboard/mouse, clipboard sync, chunked file transfer, and a printer bridge.

This is **v0.1** — a foundation, not a polished product. Current release:
**0.1.58** (2026-08-08).

## What v0.1 can do

- Launch as a SwiftUI macOS app with compact (~760×520), system-following
  Light/Dark UI.
- Show the local device identity (name, role, interfaces) on the Dashboard.
- Discover other Entanglo instances on the LAN via Bonjour
  (`_entanglo._tcp`), plus an SSDP probe and an active LAN scanner with
  OUI vendor lookup on the Network page.
- Connect manually by IP as a fallback.
- Enforce a 5-state pairing model (Not Paired → Pairing Requested → PIN
  Required → Trusted / Blocked) with a 6-digit PIN flow.
- Persist trusted devices and settings as JSON in
  `~/Library/Application Support/Entanglo`.
- Check Accessibility, Input Monitoring, and Local Network permissions and
  report status from the Settings page.
- Capture local keyboard / mouse events via CoreGraphics and inject events
  on the receiver — both gated behind pairing, permissions, heartbeat, and
  an emergency stop. Injected events are tagged so they don't loop back
  through the local tap.
- Configurable edge switching (left/right) and a global hotkey toggle.
- Triple-Escape emergency stop returns control to the local machine.
- Heartbeat with timeout; on lost heartbeat injection is stopped immediately.
- Versioned JSON message protocol with `Codable` envelope and explicit
  rejection of unknown protocol versions.
- Plain-text clipboard sync between trusted devices.
- Chunked file transfer between trusted devices (resumes within a session,
  saves to `~/Downloads/Entanglo/`).
- **Printer Bridge** (0.1.32+): send a PDF to a peer that owns a Wi-Fi-Direct
  printer; the bridge swaps Wi-Fi to the printer SSID, runs `lpr`, waits for
  the queue to drain, then power-cycles Wi-Fi so macOS auto-rejoins the home
  network. See the Print tab and Settings → Printer Bridge.
- **Auto-update / replace** (`UpdateService`): triple source — local
  `dist/` folder in dev, LAN peers pushing a signed bundle, and a remote
  HTTPS poll of `https://entanglo.pages.dev/updates/latest.json` every
  60 min. Bundles are SHA-256 verified before install. Since 0.1.54 the
  install helper preserves TCC grants across upgrades (stable signing —
  see below).
  - **Release workflow**: build a DMG with
    `ENTANGLO_VERSION=X.Y.Z ./scripts/make-dmg.sh`, then from the
    `website/` repo run `./scripts/publish-release.sh path/to/Entanglo-X.Y.Z.dmg`.
    That copies the DMG into `public/downloads/`, rewrites
    `public/updates/latest.json` with the fresh SHA-256 + size, and
    commits fall to `main` — Cloudflare Pages rebuilds on push, and
    every Mac running Entanglo picks up the manifest within its 60-min
    poll window (or on next launch). No push notifications needed:
    once the JSON is live, peers auto-fetch → verify → surface the
    Install button in News & Updates → user clicks once.
  - **Release notes are triple-sync'd**: every version bump updates
    `Entanglo/Resources/release-notes.json` (bundled in the app),
    `website/src/data/release-notes.json` (drives the Changelog page),
    and `website/public/updates/release-notes.json` (served to peers).
    All three must be byte-identical — verified with `md5 -q` at
    publish time.
- Quick actions: capture a screenshot and ship it to a peer, or grab the
  frontmost browser URL and send it across.
- Idle-sleep guard while a session is active, so the Mac doesn't fall asleep
  mid-screen-share / mid-transfer.
- Network Quality panel with current transport, latency, last heartbeat, and
  a suggested mode (Ethernet Preferred / Wi-Fi OK / Unstable).
- Compact log panel filtered by Network / Pairing / Input / Files / Error.
  Keystroke content is never logged.
- Unit tests for message codec, pairing state machine, edge switching, and
  network quality.

## What v0.1 **cannot** do

- Remote display / screen streaming — **out of scope** for entanglo. Use
  Apple Screen Sharing or NoMachine if you need that.
- AI worker routing / model inference orchestration — **out of scope**.
- Public-internet bridging / NAT traversal — LAN-only by design.
- Bandwidth bonding across Wi-Fi + Ethernet. v0.1 chooses the best route
  and fails over via `NetworkQualityService`.
- Linux clients (not started). A **Windows client** (WinUI 3 / .NET 8)
  ships separately and pairs with Mac peers via the same wire protocol —
  see `entanglo-windows-port/`.
- Strong end-to-end encryption beyond pairing-derived session keys.
  X25519 ECDH + ChaCha20-Poly1305 are planned for Phase 0.2.

## macOS permissions required

| Permission        | Why it is needed                                            |
|-------------------|-------------------------------------------------------------|
| Accessibility     | To capture and synthesize keyboard / mouse events.          |
| Input Monitoring  | To observe key and mouse events on macOS 10.15+.            |
| Local Network     | To advertise / browse Bonjour services on the LAN.          |
| Screen Recording  | Only if a peer runs the screenshot Quick Action against you.|

See `docs/PERMISSIONS.md` for step-by-step grant instructions. Entanglo
never bypasses or weakens these prompts — features stay disabled if a
permission is missing.

> **Sequoia TCC note.** From 0.1.50 the app is signed with a stable
> self-signed cert (`Entanglo Local Signing`, RSA-2048, valid to 2036)
> and a Designated Requirement based on that cert leaf, so TCC grants
> (Accessibility, Input Monitoring, Screen Recording, Local Network)
> survive upgrades. If you rebuild manually with a *different* signing
> identity the CDHash changes and the old grant becomes orphaned —
> symptom: "mouse moves on the receiver but clicks / keys do nothing".
> Fix by removing + re-adding Entanglo in
> System Settings → Privacy & Security → Accessibility and Input Monitoring.

## Build

The repository is organized so you can either:

- **Run the tests from the command line** with Swift Package Manager:
  ```bash
  cd Entanglo
  swift test
  ```
  This builds the pure-logic core (`Protocol/`, `Models/`, and the testable
  parts of `Services/`) and runs the unit tests.

  > **Toolchain note.** `swift test` needs a real Xcode installation, not
  > just the Command Line Tools. Install Xcode 15+ and either run
  > `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once,
  > or invoke `xcrun --toolchain default swift test`.

- **Build the full app in Xcode 15+** via XcodeGen:
  ```bash
  cd Entanglo
  xcodegen generate
  open Entanglo.xcodeproj
  ```
  Then Build & Run. The project is configured for stable self-signed
  code signing (`CODE_SIGN_IDENTITY: "Entanglo Local Signing"`,
  hardened runtime on), bundle id `com.paoloasara.entanglo`,
  deployment target macOS 13.

- **Ship a DMG**:
  ```bash
  ENTANGLO_VERSION=0.1.58 ./scripts/make-dmg.sh
  ```
  Output lands in `dist/Entanglo-<version>.dmg` (hdiutil, signed with
  `Entanglo Local Signing`).

## Safety notes

- LAN-only by default. Entanglo does not open any port to the public
  internet.
- Remote input injection is **always** gated by:
  pairing + permissions + heartbeat alive + emergency-stop not active.
- The triple-Escape emergency stop is always armed.
- No private Apple APIs, no kernel extensions, no SIP disabling.
- No keystroke text is ever logged. Debug mode must be explicitly turned on
  to log raw key codes, and even then no Unicode strings are reconstructed.
- Printer Bridge stores the printer SSID + password in `UserDefaults` (not
  Keychain). Acceptable for home use, not security-grade.

## Roadmap

See `docs/ROADMAP.md`. Briefly:

- **0.1** — App shell, discovery, pairing, input sharing, clipboard sync,
  file transfer, printer bridge, network diagnostics, auto-update,
  Windows client at protocol parity. **Feature-complete.**
- **0.2** — Lower input latency, X25519 ECDH + ChaCha20-Poly1305 session
  crypto, file-transfer resume across reconnects, per-device dashboard.
- **0.3** — Extract `Protocol/` + transport into a Rust crate
  (`entanglo-core`); Linux receiver.
