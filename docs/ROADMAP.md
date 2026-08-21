# Entanglo — Roadmap

## Phase 0.1 — feature-complete (Mac 0.1.56, Win 0.1.55)

Shipped:

- macOS app shell (SwiftUI, compact, system Light/Dark).
- Discovery: Bonjour (`_entanglo._tcp`), SSDP probe, active LAN scanner,
  port probe, manual IP fallback.
- 5-state pairing model + 6-digit PIN flow (TTL 120 s), trusted device
  persistence.
- Permission surface (Accessibility, Input Monitoring, Local Network)
  with clear "grant in System Settings" actions.
- Input sharing: capture + injection gated by pairing, permissions,
  heartbeat, and triple-Escape emergency stop.
- Edge switching (configurable per-side) + global hotkey toggle.
- Plain-text clipboard sync between trusted devices.
- Chunked file transfer (2 MB frames, in-session resume,
  `~/Downloads/Entanglo/`).
- Printer Bridge (Mac only): send a PDF to a peer that owns a
  Wi-Fi-Direct printer; the bridge swaps Wi-Fi to the printer SSID,
  runs `lpr`, drains the queue, then restores the home network.
- URL push + screenshot-peer Quick Actions.
- Idle Sleep Guard (dual `IOPMAssertion`) while a session is active.
- Network Quality panel (transport, latency, heartbeat, suggested mode).
- Update service (Mac): triple source — local `dist/`, LAN peer push,
  remote poll of `https://entanglo.pages.dev/updates/latest.json`
  every 60 min, all SHA-256 verified.
- Stable self-signed code signing (`Entanglo Local Signing`, RSA-2048,
  hardened runtime) so TCC grants persist across upgrades.
- Windows client (WinUI 3 / .NET 8, 0.1.55): input sharing, edge
  switching, clipboard sync, chunked file transfer, tray + single
  instance, `latest-win.json` manifest, installers via GitHub Releases.
- Unit tests for protocol codec, pairing, edge switching, network
  quality.

Open follow-ups (still 0.1):

- Windows: `RemoteHTTPSource` poller for `latest-win.json` (Mac has it;
  Windows currently updates only via LAN peer push + GitHub Releases).
- Windows: Printer Bridge (Mac-only today).

## Phase 0.2

- Lower input latency (NWConnection tuning, batching, prioritization).
- Better UI: per-device dashboard, sparkline for latency.
- Stronger session crypto: X25519 ECDH key exchange at pair time,
  ChaCha20-Poly1305 per-frame authenticated encryption.
- File transfer resume across reconnects (currently in-session only).

## Phase 0.3

- Extract `Protocol/` + transport into a Rust crate (`entanglo-core`).
- Linux receiver (X11 + Wayland injection paths).
- Cross-platform discovery via Avahi on Linux.

## Out of scope

- Public-internet bridging / NAT traversal. Entanglo is LAN-only and we
  intend to keep it that way until the security model is mature.
- Remote display / screen streaming. Removed from scope — use existing
  tools (Apple Screen Sharing, NoMachine) when needed.
- AI worker routing / model inference orchestration. Removed from scope.
