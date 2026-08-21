# Entanglo — Wire Protocol (v0.1)

## Protocol version

- **Current version:** `1` (constant `MessageCodec.currentProtocolVersion`).
- Receivers MUST reject any message with `protocolVersion != 1`. v0.1 fails
  closed; there is no negotiation yet.

## Transport

- TCP framing via `Network.framework` (`NWConnection`).
- Each message is a length-prefixed JSON object:
  ```
  [4-byte big-endian length N][N bytes of UTF-8 JSON]
  ```
- 4 MB hard cap on a single message in v0.1 (`MessageCodec.maxMessageBytes`).

## Envelope

All messages share this envelope (`EntangloMessage`):

```jsonc
{
  "protocolVersion": 1,
  "messageType": "inputEvent",
  "senderDeviceId": "DCEE2B8A-...",
  "sessionId": "B5C2...",
  "timestamp": 1718812345.123,
  "payload": "<base64-encoded JSON of the message-specific struct>"
}
```

- `messageType` is one of:
  `hello`, `pairRequest`, `pairResponse`, `heartbeat`, `inputEvent`,
  `clipboardText`, `releaseControl`, `fileOffer`, `fileChunk`, `fileAck`,
  `urlPush`, `screenshotRequest`, `screenshotResult`, `error`.
- `payload` is the JSON encoding of the type-specific struct, transported
  inside the envelope as base64 so the envelope itself stays a single JSON
  document. This keeps decoding simple and forward-compatible.

## Message examples

### hello

Sent right after a connection is established.

```jsonc
{
  "deviceName": "Paolo's iMac",
  "deviceModel": "iMac12,2",
  "appVersion": "0.1.56",
  "roles": ["controller", "receiver"],
  "platform": "macOS"
}
```

`platform` is optional and coarse (`"macOS"`, `"Windows"`, `"Linux"`) so
cross-platform peers can branch on it. Older peers omit it.

### pairRequest

```jsonc
{
  "requesterDeviceId": "...",
  "requesterDeviceName": "Paolo's iMac",
  "pinHash": "sha256(pin + sessionSalt)"
}
```

### pairResponse

```jsonc
{
  "accepted": true,
  "trustedDeviceId": "...",
  "rejectionReason": null
}
```

### heartbeat

```jsonc
{
  "sequence": 42,
  "lastRttMs": 7.4
}
```

### inputEvent

See `InputEventMessage`:

```jsonc
{
  "kind": "mouseMove",
  "x": 1024.0,
  "y": 580.0,
  "deltaX": 0.0,
  "deltaY": 0.0,
  "button": null,
  "keyCode": null,
  "modifierFlags": 0,
  "pressed": null
}
```

`kind` ∈ `mouseMove | mouseDown | mouseUp | scroll | keyDown | keyUp`.

### releaseControl

Sent by the receiver back to the controller when local input is detected
on the receiver — the controller must stop forwarding events and return
the cursor to the local Mac.

```jsonc
{
  "reason": "local_input"
}
```

### fileOffer / fileChunk / fileAck

Chunked file transfer between trusted peers. The sender emits a single
`fileOffer` (transfer metadata) followed by N `fileChunk` frames; the
receiver replies with `fileAck` once the transfer completes or fails.

```jsonc
// fileOffer
{
  "transferId": "…",
  "name": "report.pdf",
  "sizeBytes": 1048576,
  "totalChunks": 1,
  "chunkSize": 2097152,
  "kind": null           // "printJob" for Printer Bridge submissions
}

// fileChunk
{
  "transferId": "…",
  "sequence": 0,
  "data": "<base64 bytes>"
}

// fileAck
{
  "transferId": "…",
  "ok": true,
  "failureReason": null
}
```

### urlPush

Sent by the controller to push a URL into the receiver's default browser
(the URL Grabber Quick Action).

```jsonc
{
  "url": "https://example.com/page"
}
```

### screenshotRequest / screenshotResult

The controller asks a peer for a full-display screenshot; the receiver
captures its screen and returns compressed PNG bytes inline (subject to
the 4 MB frame cap).

```jsonc
// screenshotRequest
{ "requestId": "…" }

// screenshotResult
{
  "requestId": "…",
  "pngData": "<base64 PNG or null>",
  "error": null
}
```

### error

```jsonc
{
  "code": "unknownProtocolVersion",
  "message": "Sender announced protocolVersion=2."
}
```

## Pairing flow

```
Controller                       Receiver
   |                                 |
   |  hello                          |
   |-------------------------------->|
   |                                 |  hello (ack)
   |<--------------------------------|
   |                                 |
   |  pairRequest (pinHash)          |  PairingState: pinRequired
   |-------------------------------->|
   |                                 |  user types PIN on Receiver UI
   |                                 |  Receiver hashes PIN + sessionSalt
   |                                 |  compares — accepted or rejected
   |                                 |
   |  pairResponse (accepted=true)   |  PairingState: trusted
   |<--------------------------------|
   |                                 |
```

Until `pairResponse.accepted = true`:
- Receiver **must not** dispatch any `inputEvent`.
- Receiver **must not** apply any `clipboardText`.
- Receiver **must not** accept any `fileOffer`, `urlPush`, or
  `screenshotRequest`.

## Heartbeat flow

- Controller sends a `heartbeat` every `1.0 s`.
- Receiver echoes a `heartbeat` with the matching `sequence`.
- If the Controller does not see an echo within `3.0 s`, it considers the
  link dead and stops sending input.
- If the Receiver does not see a `heartbeat` for `3.0 s` (configurable via
  `NetworkTransport.heartbeatTimeout`), it stops injecting events
  immediately and surfaces a clear UI warning.

## Error handling

- Unknown `protocolVersion` → send `error` with `code = "unknownProtocolVersion"`, then close.
- Unknown `messageType` → log + drop, keep the connection alive.
- Malformed JSON / wrong frame length → close the connection.
- Any safety-gate failure on the Receiver (not paired, missing permission,
  emergency stop) → send `error` with the specific code and ignore the
  message.
