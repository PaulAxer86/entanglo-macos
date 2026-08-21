# Entanglo — Required macOS Permissions

Entanglo never bypasses macOS privacy permissions. Each feature that needs
a permission stays disabled (and visibly says so) until the user grants it
manually from **System Settings**.

## Accessibility

- **Used by:** `InputCaptureService`, `InputInjectionService`.
- **Why:** Capturing global keyboard + mouse events from any app, and
  synthesizing those events back into the system on the Receiver, requires
  the Accessibility entitlement. Apple deliberately gates this behind a
  user prompt.
- **How to grant:**
  System Settings → Privacy & Security → Accessibility → toggle Entanglo on.
  You may need to relaunch the app after toggling.

## Input Monitoring

- **Used by:** `InputCaptureService`.
- **Why:** macOS 10.15+ requires apps that observe keystrokes globally to
  hold an additional Input Monitoring permission, separate from
  Accessibility. Some Macs only need Accessibility; some need both.
- **How to grant:**
  System Settings → Privacy & Security → Input Monitoring → toggle Entanglo on.

## Local Network

- **Used by:** `DiscoveryService` (Bonjour browse + advertise).
- **Why:** Apple prompts apps the first time they try to discover or
  contact other devices on the LAN.
- **How to grant:**
  Accept the system prompt the first time Entanglo discovers a peer; if
  you have already dismissed it, toggle it back on from
  System Settings → Privacy & Security → Local Network.

## Screen Recording (optional)

- **Used by:** `ScreenshotCapturer`, only when a peer invokes the
  screenshot Quick Action against this Mac.
- **Why:** Capturing a full-display PNG snapshot requires the Screen
  Recording entitlement on macOS 10.15+.
- **How to grant:**
  System Settings → Privacy & Security → Screen Recording → toggle
  Entanglo on. Relaunch the app.
- Denying this permission only disables incoming screenshot requests;
  every other feature keeps working.

## What Entanglo will *not* do

- It will not call any private API to silently grant itself permissions.
- It will not advise the user to disable SIP, AMFI, or TCC.
- It will not run an installer with elevated privileges to plant a TCC
  override.
- It will not advertise its discovery service on any network beyond the
  current local subnet.
- If a permission is missing, Entanglo will refuse to perform the gated
  action and will tell you exactly which switch to flip.
