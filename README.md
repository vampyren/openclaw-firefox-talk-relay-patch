# OpenClaw Firefox Talk Relay Patch

Patch helper for OpenClaw Web UI **Start Talk** in Firefox.

Tested on:

```text
OpenClaw 2026.5.2 (8b2a6e5)
Ubuntu VM on Proxmox
Firefox 150
OpenAI realtime model: gpt-realtime-1.5
```

## Problem

OpenClaw Web UI Start Talk can fail in Firefox when the browser uses the direct OpenAI WebRTC SDP flow:

```text
Firefox browser -> https://api.openai.com/v1/realtime/calls
Content-Type: application/sdp
Authorization: Bearer <ephemeral realtime client secret>
```

The observed Firefox error was:

```text
NetworkError when attempting to fetch resource.
```

The token was confirmed to be an ephemeral OpenAI realtime client secret, not the real `sk-` / `sk-proj-` OpenAI API key.

OpenClaw already contains a gateway relay path that avoids the fragile browser-direct SDP POST:

```text
Firefox browser -> OpenClaw gateway -> OpenAI realtime websocket
```

This patch forces OpenAI Start Talk through that relay path, allows the relay event through OpenClaw's event scope guard, and adds half-duplex mic gating to prevent Jarvis from interrupting itself while speaking.

## What the patch changes

The script patches three installed OpenClaw bundles.

### 1. Force OpenAI Start Talk to gateway relay

File matched dynamically:

```text
dist/server-methods-*.js
```

Change:

```diff
-if (resolution.provider.createBrowserSession) {
+if (resolution.provider.id !== "openai" && resolution.provider.createBrowserSession) {
```

This skips OpenAI's browser-direct WebRTC SDP session and lets OpenClaw fall back to `gateway-relay`.

### 2. Allow the relay event through event scopes

File matched dynamically:

```text
dist/server.impl-*.js
```

Change:

```diff
 "talk.mode": [WRITE_SCOPE],
+"talk.realtime.relay": [READ_SCOPE],
 "update.available": [],
```

Without this, the backend emits `talk.realtime.relay` but the gateway scope guard drops it, leaving the UI stuck on `Connecting Talk...`.

### 3. Half-duplex mic gate while assistant is speaking

File matched dynamically:

```text
dist/control-ui/assets/index-*.js
```

Change in the gateway-relay mic pump:

```diff
-this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;let t=lG(...)
+this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;if(this.outputContext&&this.playhead>this.outputContext.currentTime+.15)return;let t=lG(...)
```

Meaning:

```text
If assistant audio is queued/playing, do not send microphone audio.
```

This avoids echo/self-interruption loops where the assistant keeps restarting or repeating while speaking.

## Requirements

OpenClaw must already be installed.

The script looks for OpenClaw in this order:

```text
$OPENCLAW_ROOT
$HOME/.npm-global/lib/node_modules/openclaw
/usr/lib/node_modules/openclaw
```

If your install path is different, run with:

```bash
OPENCLAW_ROOT=/path/to/openclaw ./apply-openclaw-firefox-talk-patch.sh
```

## Install patch

```bash
chmod +x apply-openclaw-firefox-talk-patch.sh
./apply-openclaw-firefox-talk-patch.sh
```

The script:

- finds the current hashed OpenClaw bundle filenames
- creates backups under `~/temp/openclaw-firefox-talk-patch-backups/`
- validates each source anchor matches exactly once
- aborts if the installed OpenClaw bundle does not match the expected code
- prints a diff summary and rollback command

## Required OpenClaw Talk config

Configure OpenAI Talk to use the realtime model. This is separate from normal message TTS.

```bash
openclaw config set talk.provider '"openai"' --strict-json
openclaw config set talk.providers.openai.model '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.modelId '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.voice '"marin"' --strict-json
openclaw config set talk.providers.openai.voiceId '"marin"' --strict-json
openclaw config set talk.providers.openai.vadThreshold '0.85' --strict-json
openclaw config set talk.providers.openai.silenceDurationMs '1000' --strict-json
openclaw config set talk.providers.openai.prefixPaddingMs '100' --strict-json
openclaw config validate
openclaw gateway restart
```

You still need a working OpenAI API key configured in OpenClaw, for example through SecretRef/env. Do not paste or commit API keys.

## Verify backend session

```bash
json="$(openclaw gateway call talk.realtime.session --json 2>/dev/null)"

python3 - "$json" <<'PY'
import json, sys

data = json.loads(sys.argv[1])
safe = {
    "provider": data.get("provider"),
    "transport": data.get("transport"),
    "offerUrl_present": bool(data.get("offerUrl")),
    "clientSecret_present": bool(data.get("clientSecret")),
    "relaySessionId_present": bool(data.get("relaySessionId") or data.get("sessionId") or data.get("id")),
    "audio": data.get("audio"),
}
print(json.dumps(safe, indent=2))
PY
```

Expected:

```json
{
  "provider": "openai",
  "transport": "gateway-relay",
  "offerUrl_present": false,
  "clientSecret_present": false,
  "relaySessionId_present": true
}
```

## Verify in Firefox

1. Open the OpenClaw Web UI in Firefox.
2. Hard refresh the page with `Ctrl + Shift + R`.
3. Click **Start Talk**.
4. Speak a short phrase.
5. Confirm the UI leaves `Connecting Talk...`.
6. Confirm the assistant hears and responds.
7. Confirm it does not interrupt/repeat itself while speaking.

## Rollback

Rollback the latest backup:

```bash
./apply-openclaw-firefox-talk-patch.sh --rollback latest
openclaw gateway restart
```

## Notes

- This is a local installed-bundle patch, not an upstream source patch.
- OpenClaw updates can replace the `dist/` files and remove the patch.
- Re-run the script after an update only if the exact source anchors still match.
- If the script aborts after an OpenClaw update, inspect the new source before patching.
- The half-duplex mic gate means you likely cannot interrupt the assistant by speaking while it is already talking. That is intentional for this workaround.

## Security

This patch does not log or expose API keys.

Do not screenshot or paste real tokens. In browser DevTools, an OpenAI realtime token starting with `ek_` / `ek-` is ephemeral. If you ever see a real `sk-` or `sk-proj-` key in the browser, rotate it immediately.
