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
#   OPENCLAW_ALLOW_UNTESTED=1 ./apply-openclaw-firefox-talk-patch.sh

usage() {
  cat <<'USAGE'
Usage:
  ./apply-openclaw-firefox-talk-patch.sh
  ./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
  ./apply-openclaw-firefox-talk-patch.sh --rollback latest

Environment overrides:
  OPENCLAW_ROOT=/path/to/openclaw
  OPENCLAW_ALLOW_UNTESTED=1    # bypass OpenClaw 2026.5.2 version guard
USAGE
}

MODE="apply"
ROLLBACK_TARGET=""

case "${1:-}" in
  "")
    MODE="apply"
    ;;
  --setup-openai-key)
    MODE="setup-openai-key"
    if [[ $# -ne 1 ]]; then
      usage >&2
      exit 2
    fi
    ;;
  --rollback)
    MODE="rollback"
    ROLLBACK_TARGET="${2:-latest}"
    if [[ $# -gt 2 ]]; then
      usage >&2
      exit 2
    fi
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

require_common_tools() {
  require_cmd bash
  require_cmd python3
  require_cmd find
  require_cmd sed
  require_cmd diff
}

resolve_root() {
  local default_root
  default_root="$HOME/.npm-global/lib/node_modules/openclaw"

  if [[ -n "${OPENCLAW_ROOT:-}" ]]; then
    ROOT="$OPENCLAW_ROOT"
  elif [[ -d "$default_root" ]]; then
    ROOT="$default_root"
  elif [[ -d "/usr/lib/node_modules/openclaw" ]]; then
    ROOT="/usr/lib/node_modules/openclaw"
  else
    echo "ERROR: could not find OpenClaw install root." >&2
    echo "Set OPENCLAW_ROOT=/path/to/openclaw and retry." >&2
    exit 1
  fi

  if [[ ! -d "$ROOT/dist" ]]; then
    echo "ERROR: OpenClaw root does not contain dist/: $ROOT" >&2
    exit 1
  fi

  DIST="$ROOT/dist"
}

check_openclaw_cli() {
  require_cmd openclaw
}

check_openclaw_version() {
  local version_output
  version_output="$(openclaw --version 2>/dev/null || true)"
  if [[ -z "$version_output" ]]; then
    echo "WARNING: could not read OpenClaw version with: openclaw --version" >&2
    return 0
  fi

  if [[ "$version_output" != *"2026.5.2"* ]]; then
    cat >&2 <<EOF_VERSION
ERROR: this patch was tested against OpenClaw 2026.5.2.
Detected:
$version_output

Refusing to patch untested OpenClaw build.
Set OPENCLAW_ALLOW_UNTESTED=1 to bypass this guard and rely on exact source-anchor validation.
EOF_VERSION
    if [[ "${OPENCLAW_ALLOW_UNTESTED:-}" != "1" ]]; then
      exit 1
    fi
    echo "OPENCLAW_ALLOW_UNTESTED=1 set, continuing despite version mismatch." >&2
  fi
}

setup_openai_key() {
  require_common_tools
  check_openclaw_cli

  local env_dir env_file backup_file key py_script
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

  py_script="$(mktemp)"
  chmod 700 "$py_script"
  trap 'rm -f "$py_script"' RETURN

  cat > "$py_script" <<'PY'
from pathlib import Path
import sys

env_file = Path(sys.argv[1])
key = sys.stdin.read().rstrip("\n")

if not key:
    raise SystemExit("empty key on stdin")

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

  printf '%s' "$key" | python3 "$py_script" "$env_file"
  unset key
  rm -f "$py_script"
  trap - RETURN

  chmod 600 "$env_file"

  echo "Stored OPENAI_API_KEY in: $env_file"
  echo "Permissions:"
  ls -l "$env_file"
  echo
  echo "Configuring OpenClaw SecretRef env provider allowlist for OPENAI_API_KEY..."

  if ! openclaw config set secrets.providers.default --provider-source env --provider-allowlist OPENAI_API_KEY; then
    cat >&2 <<'EOF_CONFIG'

KEY_STORED_BUT_CONFIG_UPDATE_FAILED
The key was stored successfully, but OpenClaw config update failed.
Make sure the OpenClaw gateway is installed/running, then run:

  openclaw config set secrets.providers.default --provider-source env --provider-allowlist OPENAI_API_KEY
  openclaw config validate
  openclaw gateway restart
EOF_CONFIG
    exit 1
  fi

  if ! openclaw config validate; then
    cat >&2 <<'EOF_VALIDATE'

KEY_STORED_BUT_CONFIG_VALIDATE_FAILED
The key was stored and the SecretRef provider command ran, but config validation failed.
Check OpenClaw config, then run:

  openclaw config validate
  openclaw gateway restart
EOF_VALIDATE
    exit 1
  fi

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

discover_bundles() {
  SERVER_METHODS="$(find_one 'server-methods bundle' "$DIST" -maxdepth 1 -type f -name 'server-methods-*.js')"
  SERVER_IMPL="$(find_one 'server.impl bundle' "$DIST" -maxdepth 1 -type f -name 'server.impl-*.js')"
  FRONTEND="$(find_one 'control-ui index bundle' "$DIST/control-ui/assets" -maxdepth 1 -type f -name 'index-*.js')"
}

check_writable() {
  local f
  for f in "$SERVER_METHODS" "$SERVER_IMPL" "$FRONTEND"; do
    if [[ ! -w "$f" ]]; then
      echo "ERROR: file is not writable by current user: $f" >&2
      echo "Run as the user that installed OpenClaw, fix ownership, or use sudo if this is a root-owned install." >&2
      exit 1
    fi
  done
}

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

apply_patch() {
  check_openclaw_cli
  check_openclaw_version
  check_writable

  local ts backup_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$BACKUP_BASE/backup-$ts"
  mkdir -p "$backup_dir"

  cp -a "$SERVER_METHODS" "$backup_dir/server-methods.js.bak"
  cp -a "$SERVER_IMPL" "$backup_dir/server.impl.js.bak"
  cp -a "$FRONTEND" "$backup_dir/control-ui-index.js.bak"

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

texts = {path: path.read_text() for path, _, _, _ in patches}
planned = []

for path, old, new, label in patches:
    text = texts[path]
    if new in text:
        print(f'SKIP already patched: {label}')
        planned.append((path, text))
        continue
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'ABORT: {label}: expected exactly 1 match in {path}, found {count}')
    planned.append((path, text.replace(old, new, 1)))

for path, new_text in planned:
    path.write_text(new_text)

for path, old, new, label in patches:
    if new in path.read_text():
        if old in texts[path]:
            print(f'PATCH_OK: {label}')
PY

  echo
  echo "OpenClaw root: $ROOT"
  echo "Backup dir: $backup_dir"
  echo
  echo "Changed files:"
  echo "  $SERVER_METHODS"
  echo "  $SERVER_IMPL"
  echo "  $FRONTEND"
  echo
  echo "Diff summary:"
  echo

  diff -u "$backup_dir/server-methods.js.bak" "$SERVER_METHODS" | sed -n '1,80p' || true
  echo
  diff -u "$backup_dir/server.impl.js.bak" "$SERVER_IMPL" | sed -n '1,80p' || true
  echo
  diff -u "$backup_dir/control-ui-index.js.bak" "$FRONTEND" | sed -n '/onaudioprocess/,+8p' || true

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
}

require_common_tools

BACKUP_BASE="$HOME/temp/openclaw-firefox-talk-patch-backups"
mkdir -p "$BACKUP_BASE"

case "$MODE" in
  setup-openai-key)
    setup_openai_key
    ;;
  apply)
    resolve_root
    discover_bundles
    apply_patch
    ;;
  rollback)
    resolve_root
    discover_bundles
    if [[ "$ROLLBACK_TARGET" == "latest" || -z "$ROLLBACK_TARGET" ]]; then
      rollback_latest
    else
      echo "ERROR: only --rollback latest is supported by this helper." >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: internal mode bug: $MODE" >&2
    exit 2
    ;;
esac
