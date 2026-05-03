# OpenClaw Firefox Talk Relay Patch — Complete Setup Guide

End-to-end walkthrough for applying this patch on a fresh OpenClaw installation, configuring an OpenAI API key, and verifying that **Start Talk** works in Firefox.

> **Tested target:** OpenClaw 2026.5.2 (commit `8b2a6e5`), Ubuntu VM on Proxmox, Firefox 150, OpenAI realtime model `gpt-realtime-1.5`.

---

## What this patch does

OpenClaw's Web UI **Start Talk** can fail in Firefox because the browser-direct WebRTC SDP POST to `https://api.openai.com/v1/realtime/calls` throws `NetworkError when attempting to fetch resource`. OpenClaw already ships an alternative path, **gateway-relay**, where the OpenClaw backend opens the realtime WebSocket to OpenAI and relays audio frames over its own server channel. This patch forces OpenAI Talk through that relay path, opens the `talk.realtime.relay` event in OpenClaw's event scope guard so the UI actually receives relayed audio, and adds a half-duplex mic gate so the browser does not echo the assistant's own voice back to it.

---

## Prerequisites

On the host running OpenClaw:

| Requirement | Check command | Notes |
|-------------|---------------|-------|
| OpenClaw installed | `command -v openclaw && openclaw --version` | Must report `2026.5.2` unless you set `OPENCLAW_ALLOW_UNTESTED=1`. |
| `bash` >= 4 | `bash --version` | Script uses `mapfile`. |
| `python3` | `python3 --version` | Used by patch and key setup logic. |
| `git` | `git --version` | To clone this repo. |
| `find`, `diff`, `sed` | standard | Used for discovery and diff output. |
| Write access to OpenClaw `dist/` | `test -w "$(npm root -g)/openclaw/dist" && echo OK` | If OpenClaw was installed as root, run as the correct user or fix ownership. |
| OpenAI API key | — | Standard `sk-...` or `sk-proj-...` key with realtime access. |

If any of these fail, fix them before continuing.

---

## Where OpenClaw lives

The script auto-detects the install root in this order:

1. `$OPENCLAW_ROOT`, if set
2. `$HOME/.npm-global/lib/node_modules/openclaw`
3. `/usr/lib/node_modules/openclaw`

Find yours:

```bash
ls -d "$HOME/.npm-global/lib/node_modules/openclaw" 2>/dev/null
ls -d /usr/lib/node_modules/openclaw 2>/dev/null
echo "$(npm root -g)/openclaw"
```

If your install is elsewhere, export `OPENCLAW_ROOT` before running:

```bash
export OPENCLAW_ROOT=/opt/openclaw
```

---

## Step 1 — Get the patch

Clone the repo somewhere outside the OpenClaw install tree:

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/vampyren/openclaw-firefox-talk-relay-patch.git
cd openclaw-firefox-talk-relay-patch
chmod +x apply-openclaw-firefox-talk-patch.sh
```

Review the script before running it:

```bash
less apply-openclaw-firefox-talk-patch.sh
```

---

## Step 2 — Set up the OpenAI API key

The script can store the key securely and register it with OpenClaw's `SecretRef` env provider:

```bash
./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
```

What this does:

- Prompts for the key with hidden input, so it is not echoed and not saved in shell history.
- Backs up an existing `~/.openclaw/.env` to `~/.openclaw/.env.bak-<timestamp>`.
- Writes or replaces the `OPENAI_API_KEY=...` line in `~/.openclaw/.env`.
- Sets `~/.openclaw` to `700` and `~/.openclaw/.env` to `600`.
- Runs:

```bash
openclaw config set secrets.providers.default \
    --provider-source env \
    --provider-allowlist OPENAI_API_KEY
openclaw config validate
```

The key is passed to Python over stdin, not as a command-line argument.

Manual alternative:

```bash
mkdir -p ~/.openclaw
chmod 700 ~/.openclaw
umask 077
printf 'OPENAI_API_KEY=sk-...your-key-here...\n' > ~/.openclaw/.env
chmod 600 ~/.openclaw/.env
openclaw config set secrets.providers.default \
    --provider-source env \
    --provider-allowlist OPENAI_API_KEY
openclaw config validate
```

Verify without printing the key:

```bash
test -f ~/.openclaw/.env && echo "env file present"
stat -c '%a %n' ~/.openclaw ~/.openclaw/.env
grep -c '^OPENAI_API_KEY=' ~/.openclaw/.env
```

The last command should print `1`.

---

## Step 3 — Apply the patch

From the cloned repo directory:

```bash
./apply-openclaw-firefox-talk-patch.sh
```

The script will:

1. Locate the three hashed bundles in `<OPENCLAW_ROOT>/dist/`:
   - `server-methods-*.js`
   - `server.impl-*.js`
   - `control-ui/assets/index-*.js`
2. Create a timestamped backup at `~/temp/openclaw-firefox-talk-patch-backups/backup-<YYYYMMDD-HHMMSS>/`.
3. Validate that each source anchor appears exactly once, aborting otherwise.
4. Apply the three changes:
   - Force OpenAI Talk to gateway-relay.
   - Allow `talk.realtime.relay` through `EVENT_SCOPE_GUARDS` with `READ_SCOPE`.
   - Add the half-duplex mic gate, `playhead > currentTime + 0.15` → skip mic upload.
5. Print a `diff -u` summary and rollback command.

If the script aborts with `expected exactly 1 match, found 0`, your OpenClaw build does not match the expected source. Do not edit the script anchors blindly. See [Troubleshooting](#troubleshooting).

---

## Step 4 — Configure OpenClaw Talk

These are independent of the patch but required for OpenAI realtime Talk to work:

```bash
openclaw config set talk.provider '"openai"' --strict-json
openclaw config set talk.providers.openai.model             '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.modelId           '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.voice             '"marin"'            --strict-json
openclaw config set talk.providers.openai.voiceId           '"marin"'            --strict-json
openclaw config set talk.providers.openai.vadThreshold      '0.85'               --strict-json
openclaw config set talk.providers.openai.silenceDurationMs '1000'               --strict-json
openclaw config set talk.providers.openai.prefixPaddingMs   '100'                --strict-json
openclaw config validate
```

Tuning notes:

- `vadThreshold`: higher means less sensitive to background noise. `0.85` is conservative. Try `0.6` if your mic is quiet.
- `silenceDurationMs`: how long silence must persist before the VAD considers you done speaking.
- `prefixPaddingMs`: how much audio just before VAD trigger gets sent to the model.

---

## Step 5 — Restart and verify the backend session

```bash
openclaw gateway restart
```

Then verify the realtime session is created in **gateway-relay** mode:

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
    "relaySessionId_present": bool(
        data.get("relaySessionId") or data.get("sessionId") or data.get("id")
    ),
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

If `transport` is not `gateway-relay`, the `server-methods-*.js` patch did not take effect.

---

## Step 6 — Verify in Firefox

1. Open the OpenClaw Web UI in Firefox.
2. Hard refresh with `Ctrl + Shift + R`.
3. Open DevTools → Network, filter for `realtime`. You should not see any request to `api.openai.com`.
4. Click **Start Talk**.
5. Speak a short phrase, for example: `Hello, can you hear me?`.
6. Confirm:
   - UI leaves `Connecting Talk...` within about 2 seconds.
   - Assistant responds.
   - Speaking while the assistant is replying does not cause it to interrupt or restart itself.

---

## Rollback

Restore the previous bundles:

```bash
./apply-openclaw-firefox-talk-patch.sh --rollback latest
openclaw gateway restart
```

This restores from the most recent `~/temp/openclaw-firefox-talk-patch-backups/backup-*/` directory. Rollback does not remove `~/.openclaw/.env` or revert `openclaw config set` calls. It only restores the patched JS bundles.

To fully undo everything including config:

```bash
./apply-openclaw-firefox-talk-patch.sh --rollback latest
openclaw gateway restart
openclaw config unset talk.provider
openclaw config unset talk.providers.openai.model
# unset other talk.providers.openai.* keys as desired
shred -u ~/.openclaw/.env
```

---

## Troubleshooting

### Script aborts: `expected exactly 1 match, found 0`

The installed OpenClaw bundle no longer matches the patch source anchors. Reasons include:

- OpenClaw was updated past 2026.5.2.
- A previous version of the patch is already partially applied.
- A different patch already modified one of the anchors.

Diagnose:

```bash
ROOT="$(npm root -g)/openclaw"
grep -n 'createBrowserSession' "$ROOT"/dist/server-methods-*.js | head
grep -n 'talk.mode' "$ROOT"/dist/server.impl-*.js | head
grep -n 'onaudioprocess' "$ROOT"/dist/control-ui/assets/index-*.js | head
```

If the surrounding code has shifted, do not edit the anchor strings just to make them match. Re-derive the patch against the current source.

### Script aborts: `expected exactly one ... bundle, found 2`

Usually means a stale `.bak` file got copied into `dist/` next to the real bundle. Move it out:

```bash
ROOT="$(npm root -g)/openclaw"
ls "$ROOT"/dist/server-methods-*.js
```

### Firefox still gets `NetworkError` / still hits `api.openai.com`

- Hard-refresh the page or try a private window.
- Re-run the script and inspect its diff output.
- Verify with the `talk.realtime.session` check from Step 5. The backend should not return `offerUrl` or `clientSecret`.

### `Connecting Talk...` never resolves

Confirm `talk.realtime.relay` made it into `EVENT_SCOPE_GUARDS`:

```bash
ROOT="$(npm root -g)/openclaw"
grep -n 'talk.realtime.relay' "$ROOT"/dist/server.impl-*.js
```

Should print one match.

### Assistant talks over itself / restarts mid-reply

The half-duplex mic gate did not apply. Check:

```bash
ROOT="$(npm root -g)/openclaw"
grep -c 'playhead>this.outputContext.currentTime' "$ROOT"/dist/control-ui/assets/index-*.js
```

Should print `1`. If it prints `0`, re-run the patch and hard-refresh Firefox.

### `openclaw config set` fails after `--setup-openai-key`

The key file is already written. The config call probably failed because the gateway daemon was not running. Start it and retry:

```bash
openclaw gateway start
openclaw config set secrets.providers.default \
    --provider-source env \
    --provider-allowlist OPENAI_API_KEY
openclaw config validate
```

---

## Re-running after an OpenClaw update

OpenClaw updates can replace `dist/` files and remove the patch. After an update:

1. Check the version:

```bash
openclaw --version
```

2. If the version is still `2026.5.2`, re-run normally.
3. If the version changed, treat this patch as not validated for that build. The script will refuse unless you set:

```bash
OPENCLAW_ALLOW_UNTESTED=1 ./apply-openclaw-firefox-talk-patch.sh
```

Even with that override, exact source-anchor validation still protects against patching the wrong code.

---

## Security notes

- The OpenAI key sits in `~/.openclaw/.env` with mode `600`.
- The helper does not pass the key as a command-line argument. It passes it to Python over stdin.
- An OpenAI realtime token observed in the browser starting with `ek_` / `ek-` is ephemeral and short-lived. That is expected.
- If you ever see a real `sk-...` or `sk-proj-...` key in browser DevTools, rotate it immediately at <https://platform.openai.com/api-keys>.
- Do not commit `.env`, paste keys into chat, or screenshot DevTools panels that contain bearer tokens.

---

## Quick reference

```bash
# Prereq sanity
openclaw --version
python3 --version
git --version

# Get patch
mkdir -p ~/src && cd ~/src
git clone https://github.com/vampyren/openclaw-firefox-talk-relay-patch.git
cd openclaw-firefox-talk-relay-patch
chmod +x apply-openclaw-firefox-talk-patch.sh

# Set up key
./apply-openclaw-firefox-talk-patch.sh --setup-openai-key

# Apply patch
./apply-openclaw-firefox-talk-patch.sh

# Configure Talk
openclaw config set talk.provider '"openai"' --strict-json
openclaw config set talk.providers.openai.model             '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.modelId           '"gpt-realtime-1.5"' --strict-json
openclaw config set talk.providers.openai.voice             '"marin"'            --strict-json
openclaw config set talk.providers.openai.voiceId           '"marin"'            --strict-json
openclaw config set talk.providers.openai.vadThreshold      '0.85'               --strict-json
openclaw config set talk.providers.openai.silenceDurationMs '1000'               --strict-json
openclaw config set talk.providers.openai.prefixPaddingMs   '100'                --strict-json
openclaw config validate
openclaw gateway restart

# Verify backend
openclaw gateway call talk.realtime.session --json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('transport'))"
# expect: gateway-relay

# Open Firefox -> Web UI -> Ctrl+Shift+R -> Start Talk

# Rollback if needed
./apply-openclaw-firefox-talk-patch.sh --rollback latest
openclaw gateway restart
```
