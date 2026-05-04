# OpenClaw Firefox Talk Relay Patch

Patch helper for OpenClaw Web UI **Start Talk** in Firefox.

Tested on:

```
OpenClaw 2026.5.2 (8b2a6e5)
Ubuntu VM on Proxmox
Firefox 150
OpenAI realtime model: gpt-realtime-1.5
```

---

## Problem

OpenClaw Web UI **Start Talk** can fail in Firefox when the browser uses the direct OpenAI WebRTC SDP flow:

```
Firefox browser -> https://api.openai.com/v1/realtime/calls
Content-Type: application/sdp
Authorization: Bearer <ephemeral realtime client secret>
```

The observed Firefox error was:

```
NetworkError when attempting to fetch resource.
```

The token was confirmed to be an ephemeral OpenAI realtime client secret, not the real `sk-` / `sk-proj-` OpenAI API key.

OpenClaw already contains a gateway-relay path that avoids the fragile browser-direct SDP POST:

```
Firefox browser -> OpenClaw gateway -> OpenAI realtime websocket
```

This patch forces OpenAI Start Talk through that relay path, allows the relay event through OpenClaw's event-scope guard, and adds half-duplex mic gating so the assistant doesn't echo or interrupt itself while speaking.

---

## What the patch changes

The script patches three installed OpenClaw bundles.

### 1. Force OpenAI Start Talk to gateway-relay

File matched dynamically:

```
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

```
dist/server.impl-*.js
```

Change:

```diff
 "talk.mode": [WRITE_SCOPE],
+"talk.realtime.relay": [READ_SCOPE],
 "update.available": [],
```

Without this, the backend emits `talk.realtime.relay` but the gateway scope guard drops it and the UI stalls on `Connecting Talk...`.

### 3. Half-duplex mic gate while assistant is speaking (configurable)

File matched dynamically:

```
dist/control-ui/assets/index-*.js
```

The relay-mic pump is wrapped with a runtime gate. The threshold is read once per Talk session from `localStorage["openclaw.micGateMs"]` (milliseconds), with 150 ms as the default.

```diff
-this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;let t=lG(...)
+this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;
+  if(this._mgS===void 0){
+    try{
+      const v=parseFloat(localStorage.getItem("openclaw.micGateMs"));
+      this._mgS=isFinite(v)&&v>=0?v/1000:.15
+    }catch(_){this._mgS=.15}
+  }
+  if(this.outputContext&&this.playhead>this.outputContext.currentTime+this._mgS)return;
+  let t=lG(...)
```

Meaning:

> If more than `micGateMs` of assistant audio is still queued ahead of the playback head, do not send microphone audio.

Why a gate at all: without it, your mic picks up the assistant's own voice from the speakers, the realtime API treats it as new user input, and the assistant either interrupts itself or starts repeating.

The frontend anchor uses a regex that locks on the **structural shape** of the `onaudioprocess` arrow plus the **semantic** string `` `talk.realtime.relayAudio` ``. Helper functions (`lG`, `sG`, ...) can be renamed by the minifier across rebuilds without breaking the anchor.

### 4. Manual mute button + Ctrl+M shortcut + barge-in on unmute (v2.5)

A small floating button is injected next to the existing broadcast/Talk icon (default `left: 399px; top: 843px` — tunable):

- **MIC ON** (green) — relay pump sends mic audio normally.
- **MIC MUTED** (red) — relay pump sends silence frames (the connection stays alive, the assistant keeps talking, you just can't be heard).

Click or press `Ctrl+M` to toggle. State persists in `localStorage["openclaw.micMuted"]`.

The button auto-anchors to the right edge of the viewport (stable across sidebar collapse/expand) and self-heals via a `MutationObserver` — if React removes it during a re-render, it gets re-attached automatically. Position is tunable via four `localStorage` knobs (see below).

**On unmute**, the gate is reset so your voice reaches OpenAI's VAD immediately, triggering the realtime API's natural barge-in. The assistant stops generating new audio. Note that any audio already buffered in your browser will still play out as it drains — barge-in cancels generation, not local playback.

This complements the automatic gate — the gate handles the common case (assistant audio queued, mic silent), the manual mute handles the edge case the gate can't fully solve (acoustic feedback from open speakers, where the assistant's own voice reaches your microphone over the air and trips OpenAI's VAD regardless of any client-side gating).

---

## Requirements

OpenClaw must already be installed.

The script looks for OpenClaw in this order:

```
$OPENCLAW_ROOT
$HOME/.npm-global/lib/node_modules/openclaw
/usr/lib/node_modules/openclaw
```

If your install path is different, run with:

```bash
OPENCLAW_ROOT=/path/to/openclaw ./apply-openclaw-firefox-talk-patch.sh
```

Other prerequisites: `bash`, `python3`, `find`, `diff`, `sed`, the `openclaw` CLI on PATH, and write access to the three target bundle files.

---

## Optional: set up OpenAI API key securely

The helper can store `OPENAI_API_KEY` in `~/.openclaw/.env` and configure OpenClaw's env SecretRef provider allowlist.

```bash
chmod +x apply-openclaw-firefox-talk-patch.sh
./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
```

It will:

* prompt for the OpenAI API key with hidden input
* create or update `~/.openclaw/.env`
* back up an existing `.env` before changing it
* set `~/.openclaw` to `700`
* set `~/.openclaw/.env` to `600`
* add/update only the `OPENAI_API_KEY=` line
* run:
  ```bash
  openclaw config set secrets.providers.default --provider-source env --provider-allowlist OPENAI_API_KEY
  openclaw config validate
  ```

The key is passed from the script to Python via file descriptor 3 (a here-string), not via argv and not via an environment variable. This means the key is not visible in `ps` (argv) and not visible in `/proc/<pid>/environ` (env vars) during the python process's lifetime. The key is never echoed to logs. Do not commit `.env` or paste keys into chat/logs/screenshots.

If the post-write `openclaw config` step fails, the script reports clearly that the key file is in place and prints the exact commands to run manually once the gateway is reachable.

---

## Install patch

```bash
chmod +x apply-openclaw-firefox-talk-patch.sh
./apply-openclaw-firefox-talk-patch.sh
```

The script:

* runs preflight checks (`python3` present, OpenClaw root resolves, all three target files writable)
* finds the current hashed OpenClaw bundle filenames
* creates a backup under `~/temp/openclaw-firefox-talk-patch-backups/backup-<timestamp>/`
* validates each source anchor matches exactly once (regex for the frontend, literal for the others)
* aborts cleanly if the installed OpenClaw bundle does not match the expected code (no half-patched state)
* prints a diff summary and the rollback command
* auto-prunes old backups, keeping the most recent `KEEP_BACKUPS` (default 10)

---

## Tune the mic gate (runtime, no rebuild)

Open the OpenClaw page in Firefox, then in DevTools Console:

```js
localStorage.setItem('openclaw.micGateMs', '250')   // stricter no-echo, slower barge-in
localStorage.setItem('openclaw.micGateMs', '60')    // looser, faster barge-in, more echo risk
localStorage.removeItem('openclaw.micGateMs')       // back to default 150 ms
```

Hard-refresh the page (`Ctrl+Shift+R`) after changing the value — the script reads it once at the start of each Talk session and caches it on the processor instance.

Rough guidance:

| Environment | Suggested `micGateMs` |
|---|---|
| Headphones, no acoustic loop | 60–100 |
| Quiet room, near-field speakers | 150 (default) |
| Open speakers in a small/echoey room | 250–400 |

---

## Manual mute button (v2.5)

The patch injects a small floating button into the OpenClaw UI (default position: next to the broadcast/Talk icon) that toggles the microphone:

- **MIC ON** (green) — relay pump sends mic audio normally.
- **MIC MUTED** (red) — relay pump replaces every mic frame with silence (zero-fill of the input buffer). The realtime session and the OpenClaw relay both stay healthy; the assistant keeps generating audio while you're muted.

Click the button or press **`Ctrl+M`** anywhere on the page to toggle. The keyboard shortcut works whether the button has focus or not.

State persists across reloads in `localStorage["openclaw.micMuted"]` (`"1"` when muted, absent when on).

### Self-healing (v2.4)

The button is created via an IIFE appended to the bundle. OpenClaw's React app sometimes replaces `document.body`'s children when it re-renders, which removes any externally-injected DOM. v2.4 watches for this with a `MutationObserver` on `document.body` and re-attaches the button whenever it detects the removal. From the user's perspective, the button stays put across page refreshes and React re-renders — no need to unregister the service worker just to make it reappear.

### Barge-in on unmute (v2.3+)

When you toggle from MUTED back to ON during the assistant's reply, the gate's `playhead` is reset so the next mic frames flow immediately to OpenAI's realtime API. The API's VAD detects your voice and issues a barge-in event, which causes the assistant to stop generating new audio.

**Caveat:** local audio that's already been buffered in your browser will keep playing as it drains — typically a few seconds, sometimes longer if the assistant has just generated a long reply. Barge-in cancels generation on OpenAI's side, not local playback. Cleanly clearing the local AudioContext queue is more invasive than this patch reaches.

In practice the flow is: mute → listen → unmute and start speaking → assistant trails off over a couple of seconds, then your turn.

### Button position (v2.5)

Default is `left: 399px; top: 843px` from the viewport — chosen to land next to the existing broadcast/Talk icon on a typical OpenClaw layout. Pixel coords are tied to viewport size, so if you resize the window or move to a different machine you may need to re-position. Override via any of four runtime knobs:

```js
// Distance from edges (use whichever pair fits your layout)
localStorage.setItem('openclaw.muteBtnLeft', '399px')   // default 399px
localStorage.setItem('openclaw.muteBtnTop',  '843px')   // default 843px

// Or anchor from the opposite edge (these override Left/Top)
localStorage.setItem('openclaw.muteBtnRight',  '16px')  // pin to a specific x from right
localStorage.setItem('openclaw.muteBtnBottom', '80px')  // pin to a specific y from bottom

// Reload (or close-and-reopen the OpenClaw tab) to apply
```

Setting `Right` makes the button right-anchored and the default `Left` is ignored. Same for `Bottom` over the default `Top`. To revert to the v2.5 defaults, `removeItem` all four knobs and reload.

To toggle the mute state from the console (e.g. for scripting or testing):

```js
localStorage.setItem('openclaw.micMuted', '1')      // mute
localStorage.removeItem('openclaw.micMuted')        // unmute
```

The relay pump re-reads `localStorage` on every audio frame, so toggling takes effect immediately — no need to restart Talk.

---

## Required OpenClaw Talk config

Configure OpenAI Talk to use the realtime model. This is independent of normal message TTS.

```bash
openclaw config set talk.provider '"openai"' --strict-json
openclaw config set talk.providers.openai.model            '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.modelId          '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.voice            '"marin"'            --strict-json
openclaw config set talk.providers.openai.voiceId          '"marin"'            --strict-json
openclaw config set talk.providers.openai.vadThreshold     '0.85'               --strict-json
openclaw config set talk.providers.openai.silenceDurationMs '1000'              --strict-json
openclaw config set talk.providers.openai.prefixPaddingMs   '100'               --strict-json
openclaw config validate
openclaw gateway restart
```

You also need a working OpenAI API key configured in OpenClaw. The recommended helper is:

```bash
./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
```

---

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

---

## Verify in Firefox

1. Open the OpenClaw Web UI in Firefox.
2. Hard refresh with `Ctrl + Shift + R`.
3. Open DevTools → Network, filter for `realtime`. You should **not** see any request to `api.openai.com`.
4. Click **Start Talk**.
5. Speak a short phrase.
6. Confirm the UI leaves `Connecting Talk...`.
7. Confirm the assistant hears and responds.
8. Confirm it does not interrupt or repeat itself while speaking.

---

## Rollback

```bash
./apply-openclaw-firefox-talk-patch.sh --rollback latest
openclaw gateway restart
```

Rollback restores the most recent backup of the three patched bundles. It does **not** remove `~/.openclaw/.env` or undo `openclaw config set` calls.

---

## Backup management

After every successful apply, the script keeps the most recent `$KEEP_BACKUPS` backup directories under `~/temp/openclaw-firefox-talk-patch-backups/` and removes older ones. Default is 10.

Override the retention count:

```bash
KEEP_BACKUPS=20 ./apply-openclaw-firefox-talk-patch.sh
```

Manual prune at any time:

```bash
./apply-openclaw-firefox-talk-patch.sh --prune-backups        # use $KEEP_BACKUPS / default 10
./apply-openclaw-firefox-talk-patch.sh --prune-backups 5      # keep last 5
./apply-openclaw-firefox-talk-patch.sh --prune-backups 0      # remove all
```

---

## Migration from v1 of this patch

The v1 patch hardcoded the gate at `+.15` seconds and relied on a long literal frontend anchor. v2 uses a regex anchor and a runtime `localStorage` knob.

If a host already has v1 applied, the v2 script will detect the v1 marker and abort with:

```
ABORT: ... detected v1 patch (hardcoded 150 ms gate). Run --rollback latest first, then re-apply for the configurable gate.
```

The migration is two commands plus a restart:

```bash
./apply-openclaw-firefox-talk-patch.sh --rollback latest
./apply-openclaw-firefox-talk-patch.sh
openclaw gateway restart
```

---

## Upgrading from v2.1 / v2.2 / v2.3 / v2.4 to v2.5

Just re-run the script. v2.5's patcher detects whichever earlier version is on the bundle, keeps the unchanged pieces, strips the old UI block, and appends the v2.5 UI block (default position: next to the broadcast/Talk icon).

- **v2.1** (gate only): adds the v2.3 silence-frame mute logic and the v2.4 UI block.
- **v2.2** (gate + early-return mute + bottom-right UI): replaces the early-return mute with v2.3's silence-frame + barge-in logic, strips the v2.2 UI block, appends the v2.4 UI block.
- **v2.3** (gate + silence-frame mute + bottom-left UI): keeps the mute logic (it's identical), strips the v2.3 UI block, appends the v2.4 UI block (right-anchored + self-healing).

```bash
./apply-openclaw-firefox-talk-patch.sh
openclaw gateway restart
```

After the gateway restart, **unregister the OpenClaw service worker** in Firefox (`about:debugging#/runtime/this-firefox` → find `127.0.0.1:18789/sw.js` → Unregister), then close and reopen the OpenClaw tab. Without this step, Firefox keeps serving the previous cached bundle and you won't see the new behavior.

---

## Notes

* This is a local installed-bundle patch, not an upstream source patch.
* OpenClaw updates can replace `dist/` files and remove the patch.
* If the script aborts after an OpenClaw update, inspect the new source before patching — do not edit the anchors blindly. The abort is a safety feature.
* The half-duplex mic gate means barge-in (interrupting the assistant by speaking over it) is reduced. Lower `openclaw.micGateMs` if you want faster barge-in at the cost of more echo risk.

---

## Security

This patch does not log or expose API keys.

* The optional key helper stores the API key in `~/.openclaw/.env` with file mode `600` and `~/.openclaw` set to `700`.
* The key is passed from the shell script to Python via file descriptor 3 (a here-string). This means it is **not** visible in `ps` (argv) and **not** visible in `/proc/<pid>/environ` (env vars) during the python process's lifetime — it lives only in the kernel pipe buffer for that single invocation, then disappears.
* In browser DevTools, an OpenAI realtime token starting with `ek_` / `ek-` is **ephemeral** and short-lived — that's expected. If you ever see a real `sk-…` or `sk-proj-…` key in the browser, **rotate it immediately** at <https://platform.openai.com/api-keys>.
* Do not screenshot or paste real tokens.

---

## Usage summary

```
./apply-openclaw-firefox-talk-patch.sh                       # apply
./apply-openclaw-firefox-talk-patch.sh --setup-openai-key    # store API key
./apply-openclaw-firefox-talk-patch.sh --rollback latest     # restore most recent backup
./apply-openclaw-firefox-talk-patch.sh --prune-backups [N]   # prune old backups, keep last N
./apply-openclaw-firefox-talk-patch.sh --help                # usage
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OPENCLAW_ROOT` | (autodetect) | Override OpenClaw install path |
| `KEEP_BACKUPS`  | `10`         | Backups to retain after auto-prune |
