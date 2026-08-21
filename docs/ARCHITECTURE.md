# Entanglo — Architecture (v0.1)

## Layers

```
┌──────────────────────────────────────────────────────────┐
│  Views/         SwiftUI screens, observe AppState        │
├──────────────────────────────────────────────────────────┤
│  AppState       ObservableObject, glue between services  │
├──────────────────────────────────────────────────────────┤
│  Services/      Discovery, Pairing, Transport, Input,    │
│                 Permission, Clipboard, FileTransfer,     │
│                 NetworkQuality, AppLog                   │
├──────────────────────────────────────────────────────────┤
│  Protocol/      Codable message envelope + codec         │
├──────────────────────────────────────────────────────────┤
│  Models/        Plain value types (Device, …)            │
└──────────────────────────────────────────────────────────┘
```

The lower layers (`Models`, `Protocol`, and the pure-logic parts of
`Services`) are platform-agnostic and built by `Package.swift`. The upper
layers (`Views`, `AppState`, AppKit-bound services) require Xcode.

## Services overview

| Service                  | Responsibility                                                                |
|--------------------------|-------------------------------------------------------------------------------|
| DiscoveryService         | Bonjour advertise + browse (`_entanglo._tcp`).                                |
| LANScannerService        | Active subnet sweep + OUI vendor lookup for the Network page.                 |
| SSDPDiscoverer           | SSDP probe for peers that miss the Bonjour advertisement.                     |
| PortProbeService         | TCP probe on manually entered IPs (fallback discovery).                       |
| PairingService           | 5-state pairing machine + 6-digit PIN flow + trusted-device persistence.      |
| NetworkTransport         | `Network.framework` listener/connection, heartbeat, JSON message I/O.         |
| ConnectionCoordinator    | Dial reconciler, safety-gate refresher, live transport state per peer.        |
| InputCaptureService      | CGEventTap on Controller, normalizes events into `InputEventMessage`.         |
| InputInjectionService    | CGEvent post on Receiver, only after all safety gates pass.                   |
| LocalInputWatcher        | Detects local input on the Receiver → sends `releaseControl` upstream.        |
| GlobalHotkeyManager      | Cmd+Shift+U toggle, Cmd+Shift+S screenshot Quick Action.                      |
| PermissionService        | Inspects Accessibility / Input Monitoring / Local Network / Screen Recording. |
| ClipboardSyncService     | Plain-text clipboard sync between trusted devices, off by default.            |
| FileTransferService      | Chunked file send/receive between trusted devices (2 MB frames, resume).      |
| PrinterBridgeService     | Received PDFs → Wi-Fi swap → `lpr` → power-cycle Wi-Fi to restore home LAN.   |
| ScreenshotCapturer       | Full-display PNG capture for the `screenshotRequest` peer Quick Action.       |
| URLGrabber               | Grabs the frontmost browser URL for the `urlPush` Quick Action.               |
| IdleSleepGuardService    | Dual `IOPMAssertion` guard while a session is active.                         |
| NetworkQualityService    | Computes a suggested transport mode from latency / loss / interface info.     |
| NetworkQualityMonitor    | Publishes RTT + link quality samples to the UI.                               |
| UpdateService            | Triple-source updater (local `dist/`, LAN peer push, HTTPS poll) + SHA-256.   |
| SettingsStore            | JSON persistence under `~/Library/Application Support/Entanglo`.              |
| SoundService             | Discreet feedback tones for pairing / transfers / errors.                     |
| AppLogService            | OSLog + in-memory ring buffer for the Logs view.                              |

## Message flow

```
                +-------------------+
   Local input  | InputCaptureSvc   |
   on Controller| (CGEventTap)      |
                +---------+---------+
                          |
                          v
                  InputEventMessage
                          |
              MessageCodec.encode
                          |
                          v
                +-------------------+
                | NetworkTransport  |  ---heartbeat--->
                | (NWConnection)    |
                +---------+---------+
                          |
                  TCP / Bonjour LAN
                          |
                          v
                +-------------------+
                | NetworkTransport  |  on Receiver
                | (NWListener)      |
                +---------+---------+
                          |
              MessageCodec.decode
                          |
                          v
            +---------------------------+
            | Safety gates (all must    |
            | pass before injection):   |
            |  - device is Trusted      |
            |  - Receiver role enabled  |
            |  - Accessibility granted  |
            |  - heartbeat alive        |
            |  - emergency-stop off     |
            +-------------+-------------+
                          |
                          v
                +-------------------+
                | InputInjectionSvc |
                | (CGEvent post)    |
                +-------------------+
```

## Controller / Receiver flow

1. User toggles control with the hotkey or by moving the mouse to a
   configured screen edge.
2. `InputCaptureService` swaps from "local" to "remote target" mode and
   begins forwarding normalized events.
3. The local cursor is parked at the edge while remote input is active.
4. Triple-Escape, lost heartbeat, or hotkey toggle returns to local mode.

## File transfer flow

1. Sender picks a file in the Files view and selects a trusted peer.
2. `FileTransferService` chunks the file into fixed-size frames and
   sends them as `fileTransferChunk` messages over the existing
   `NWConnection`.
3. Receiver writes incoming chunks to a destination chosen at acceptance
   time; rejects transfers from non-trusted peers.
4. Transfer state is surfaced live in the UI; cancelled transfers leave
   a `.partial` file behind so the user can decide what to do.
