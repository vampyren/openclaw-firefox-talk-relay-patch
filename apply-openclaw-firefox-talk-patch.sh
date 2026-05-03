#!/usr/bin/env bash
set -euo pipefail

# OpenClaw Firefox Start Talk gateway-relay patch
#
# Purpose:
#   1. Force OpenAI Web UI Start Talk through gateway-relay instead of browser-direct WebRTC SDP.
#   2. Allow the pushed talk.realtime.relay event through OpenClaw's event scope guard.
#   3. Add half-duplex mic gating so the browser does not send mic audio while assistant audio is playing.
#   4. Optionally set up OPENAI_API_KEY securely for OpenClaw SecretRef/env usage.
#
# Tested against:
#   OpenClaw 2026.5.2
#
# Usage:
#   ./apply-openclaw-firefox-talk-patch.sh
#   ./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
#   ./apply-openclaw-firefox-talk-patch.sh --rollback latest
#
# Optional override:
#   OPENCLAW_ROOT=/path/to/openclaw ./apply-openclaw-firefox-talk-patch.sh

MODE="${1:-apply}"
ROLLBACK_TARGET="${2:-}"

DEFAULT_ROOT="$HOME/.npm-global/lib/node_modules/openclaw"
if [[ -n "${OPENCLAW_ROOT:-}" ]]; then
  ROOT="$OPENCLAW_ROOT"
elif [[ -d "$DEFAULT_ROOT" ]]; then
  ROOT="$DEFAULT_ROOT"
elif [[ -d "/usr/lib/node_modules/openclaw" ]]; then
  ROOT="/usr/lib/node_modules/openclaw"
else
  echo "ERROR: could not find OpenClaw install root." >&2
  echo "Set OPENCLAW_ROOT=/path/to/openclaw and retry." >&2
  exit 1
fi

DIST="$ROOT/dist"
BACKUP_BASE="$HOME/temp/openclaw-firefox-talk-patch-backups"
mkdir -p "$BACKUP_BASE"

setup_openai_key() {
  local env_dir env_file backup_file key
  env_dir="$HOME/.openclaw"
  env_file="$env_dir/.env"

  mkdir -p "$env_dir"
  chmod 700 "$env_dir"

  if [[ -f "$env_file" ]]; then
    backup_file="$env_file.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$env_file" "$backup_file"
    echo "Existing .env backup: $backup_file"
  fi

  printf 'Paste OpenAI API key. Input is hidden: '
  IFS= read -r -s key
  printf '\n'

  if [[ -z "$key" ]]; then
    echo "ERROR: empty key, aborting." >&2
    exit 1
  fi

  if [[ "$key" != sk-* && "$key" != sk-proj-* ]]; then
    echo "WARNING: key does not start with sk- or sk-proj-. Continuing because OpenAI key formats can change." >&2
  fi

  python3 - "$env_file" "$key" <<'PY'
from pathlib import Path
import sys

env_file = Path(sys.argv[1])
key = sys.argv[2]

lines = []
if env_file.exists():
    lines = env_file.read_text().splitlines()

out = []
replaced = False
for line in lines:
    if line.startswith("OPENAI_API_KEY="):
        out.append(f"OPENAI_API_KEY={key}")
        replaced = True
    else:
        out.append(line)

if not replaced:
    out.append(f"OPENAI_API_KEY={key}")

env_file.write_text("\n".join(out).rstrip() + "\n")
PY

  chmod 600 "$env_file"

  echo "Stored OPENAI_API_KEY in: $env_file"
  echo "Permissions:"
  ls -l "$env_file"
  echo
  echo "Configuring OpenClaw SecretRef env provider allowlist for OPENAI_API_KEY..."
  openclaw config set secrets.providers.default --provider-source env --provider-allowlist OPENAI_API_KEY
  openclaw config validate
  echo
  echo "OPENAI_KEY_SETUP_DONE"
  echo "Restart OpenClaw gateway when ready: openclaw gateway restart"
}

find_one() {
  local desc="$1"
  shift
  mapfile -t matches < <(find "$@" 2>/dev/null | sort)
  if [[ "${#matches[@]}" -ne 1 ]]; then
    echo "ERROR: expected exactly one $desc, found ${#matches[@]}" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

SERVER_METHODS="$(find_one 'server-methods bundle' "$DIST" -maxdepth 1 -type f -name 'server-methods-*.js')"
SERVER_IMPL="$(find_one 'server.impl bundle' "$DIST" -maxdepth 1 -type f -name 'server.impl-*.js')"
FRONTEND="$(find_one 'control-ui index bundle' "$DIST/control-ui/assets" -maxdepth 1 -type f -name 'index-*.js')"

rollback_latest() {
  local latest
  latest="$(find "$BACKUP_BASE" -maxdepth 1 -type d -name 'backup-*' | sort | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    echo "ERROR: no backup directory found under $BACKUP_BASE" >&2
    exit 1
  fi
  echo "Rolling back from: $latest"
  cp -a "$latest/server-methods.js.bak" "$SERVER_METHODS"
  cp -a "$latest/server.impl.js.bak" "$SERVER_IMPL"
  cp -a "$latest/control-ui-index.js.bak" "$FRONTEND"
  echo "ROLLBACK_OK"
  echo "Restart OpenClaw gateway after rollback: openclaw gateway restart"
}

if [[ "$MODE" == "--setup-openai-key" ]]; then
  setup_openai_key
  exit 0
fi

if [[ "$MODE" == "--rollback" ]]; then
  if [[ "$ROLLBACK_TARGET" == "latest" || -z "$ROLLBACK_TARGET" ]]; then
    rollback_latest
    exit 0
  fi
  echo "ERROR: only --rollback latest is supported by this helper." >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_BASE/backup-$TS"
mkdir -p "$BACKUP_DIR"

cp -a "$SERVER_METHODS" "$BACKUP_DIR/server-methods.js.bak"
cp -a "$SERVER_IMPL" "$BACKUP_DIR/server.impl.js.bak"
cp -a "$FRONTEND" "$BACKUP_DIR/control-ui-index.js.bak"

python3 - "$SERVER_METHODS" "$SERVER_IMPL" "$FRONTEND" <<'PY'
from pathlib import Path
import sys

server_methods = Path(sys.argv[1])
server_impl = Path(sys.argv[2])
frontend = Path(sys.argv[3])

patches = [
    (
        server_methods,
        'if (resolution.provider.createBrowserSession) {',
        'if (resolution.provider.id !== "openai" && resolution.provider.createBrowserSession) {',
        'force OpenAI talk.realtime.session to gateway-relay',
    ),
    (
        server_impl,
        '\t"talk.mode": [WRITE_SCOPE],\n\t"update.available": [],',
        '\t"talk.mode": [WRITE_SCOPE],\n\t"talk.realtime.relay": [READ_SCOPE],\n\t"update.available": [],',
        'allow talk.realtime.relay event through EVENT_SCOPE_GUARDS',
    ),
    (
        frontend,
        'this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;let t=lG(e.inputBuffer.getChannelData(0));this.ctx.client.request(`talk.realtime.relayAudio`,{relaySessionId:this.session.relaySessionId,audioBase64:sG(t),timestamp:Math.round((this.inputContext?.currentTime??0)*1e3)})}',
        'this.inputProcessor.onaudioprocess=e=>{if(this.closed)return;if(this.outputContext&&this.playhead>this.outputContext.currentTime+.15)return;let t=lG(e.inputBuffer.getChannelData(0));this.ctx.client.request(`talk.realtime.relayAudio`,{relaySessionId:this.session.relaySessionId,audioBase64:sG(t),timestamp:Math.round((this.inputContext?.currentTime??0)*1e3)})}',
        'pause mic relayAudio while assistant audio is queued/playing',
    ),
]

for path, old, new, label in patches:
    text = path.read_text()
    if new in text:
        print(f'SKIP already patched: {label}')
        continue
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'ABORT: {label}: expected exactly 1 match in {path}, found {count}')
    path.write_text(text.replace(old, new, 1))
    print(f'PATCH_OK: {label}')
PY

echo
echo "OpenClaw root: $ROOT"
echo "Backup dir: $BACKUP_DIR"
echo
echo "Changed files:"
echo "  $SERVER_METHODS"
echo "  $SERVER_IMPL"
echo "  $FRONTEND"
echo
echo "Diff summary:"
echo

diff -u "$BACKUP_DIR/server-methods.js.bak" "$SERVER_METHODS" | sed -n '1,80p' || true
echo
diff -u "$BACKUP_DIR/server.impl.js.bak" "$SERVER_IMPL" | sed -n '1,80p' || true
echo
diff -u "$BACKUP_DIR/control-ui-index.js.bak" "$FRONTEND" | sed -n '/onaudioprocess/,+8p' || true

echo
echo "PATCH_DONE"
echo
echo "Optional OpenAI key setup:"
echo "  $0 --setup-openai-key"
echo
echo "Next steps:"
echo "  openclaw config set talk.provider '\"openai\"' --strict-json"
echo "  openclaw config set talk.providers.openai.model '\"gpt-realtime-1.5\"' --strict-json"
echo "  openclaw config set talk.providers.openai.modelId '\"gpt-realtime-1.5\"' --strict-json"
echo "  openclaw config set talk.providers.openai.voice '\"marin\"' --strict-json"
echo "  openclaw config set talk.providers.openai.voiceId '\"marin\"' --strict-json"
echo "  openclaw config set talk.providers.openai.vadThreshold '0.85' --strict-json"
echo "  openclaw config set talk.providers.openai.silenceDurationMs '1000' --strict-json"
echo "  openclaw config set talk.providers.openai.prefixPaddingMs '100' --strict-json"
echo "  openclaw config validate"
echo "  openclaw gateway restart"
echo
echo "Rollback latest backup:"
echo "  $0 --rollback latest"
