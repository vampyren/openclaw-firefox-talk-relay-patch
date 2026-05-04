#!/usr/bin/env bash
set -euo pipefail

# OpenClaw Firefox Start Talk gateway-relay patch (hardened v2.7.4)
#
# Purpose:
#   1. Force OpenAI Web UI Start Talk through gateway-relay instead of browser-direct WebRTC SDP.
#   2. Allow the pushed talk.realtime.relay event through OpenClaw's event scope guard.
#   3. Add half-duplex mic gating so the browser does not send mic audio while assistant
#      audio is playing. Gate threshold is configurable at runtime via
#      localStorage["openclaw.micGateMs"]  (milliseconds, default 150).
#   4. Add a manual mute button + Ctrl+M shortcut for users on speakers (where acoustic
#      feedback can defeat any automatic gate). Mute state persists across reloads in
#      localStorage["openclaw.micMuted"].
#   5. Optionally set up OPENAI_API_KEY securely for OpenClaw SecretRef/env usage.
#
# Changes in v2.7.4:
#   - The patch now also bumps OpenClaw's SW cache name (dist/control-ui/sw.js).
#     OpenClaw's SW is cache-first for /assets/*.js with a static cache name, so
#     once a bundle URL is cached the SW served the old version forever -- our
#     patches never reached the browser without a manual SW unregister. With the
#     cache name bumped, the SW's existing activate-handler cleanup deletes the
#     stale cache on next page load and the patched bundle is served cleanly.
#     Patch target #4. JS validation, backup, and rollback all extended to sw.js.
#
# Changes in v2.7.3:
#   - Mute button now hides on non-chat pages (Agents, Channels, etc.) instead of
#     falling back to fixed-mode floating over unrelated UI. ensureAttached() checks
#     for the .shell--chat marker; when absent the button is detached and not rendered.
#     Returning to chat re-attaches inline via the existing MutationObserver self-heal.
#     The original "toolbar selector broke on chat page -> fixed-mode fallback" intent
#     is preserved (chat shell present + toolbar absent still falls back to fixed).
#   - IIFE marker bumped V27 -> V28; older V27 block is stripped on apply.
#
# Changes in v2.7.2:
#   - --dry-run flag: runs preflight, discovery, anchor checks, and reports what WOULD
#     be patched, but does not modify any file. Useful as a "check before commit" pass
#     after OpenClaw upgrades. Exits non-zero if any anchor check would fail.
#   - Post-write JS validation: after each patched bundle is written, the script runs
#     'node --check' against it. If validation fails, the just-made backup is restored
#     automatically and the script aborts. Catches the rare case where a write produces
#     unparseable JS (autolink corruption, partial write, write-during-update, etc.).
#     If 'node' is not on PATH, validation is skipped with a warning, not an abort.
#
# Changes in v2.7.1:
#   - Compatibility with OpenClaw 2026.5.3, which split server-methods bundle into two
#     files (the original server-methods-*.js plus a new server-methods-list-*.js).
#     The discovery glob now excludes the -list- variant so we patch the right file.
#     The patch anchor itself is unchanged and still matches.
#
# Changes in v2.7:
#   - Bugfix: when the IIFE ran before React had mounted the chat toolbar, v2.6 fell
#     back to fixed positioning and then the MutationObserver's fast-path early-return
#     prevented it from upgrading to inline-mode once the toolbar appeared. v2.7 tracks
#     attach-mode separately and always re-checks for the toolbar while in fixed-mode,
#     so it transitions to inline as soon as the toolbar exists.
#   - Defensive cleanup at init: removes any pre-existing button with our id before
#     attaching, in case of leftover state from prior IIFE runs.
#
# Changes in v2.6:
#   - Mute button DOM-anchored to .agent-chat__toolbar-left (no fixed pixel coords).
#   - rAF batching for MutationObserver callbacks.
#
# Changes in v2.5:
#   - Default fallback button position changed to left:399px top:843px.
#
# Changes in v2.4:
#   - Right-edge anchor + four position knobs + MutationObserver self-healing.
#
# Changes in v2.3:
#   - Mute sends silence frames (zero-fill) instead of skipping the relay call, keeping
#     the realtime session healthy and the assistant talking while you can't be heard.
#   - Unmute resets the gate so voice reaches the API immediately, triggering OpenAI's
#     natural barge-in. (Local audio buffer drain is out of scope -- expect "trails off".)
#
# Changes in v2.2:
#   - Floating mute button + Ctrl+M shortcut.
#
# Changes in v2.1:
#   - Key is passed to Python via file descriptor 3 instead of an env var,
#     so it is no longer visible in /proc/<pid>/environ during the python process.
#   - Reject extra positional arguments (e.g. "./script.sh --setup-openai-key garbage").
#
# Tested against: OpenClaw 2026.5.2, 2026.5.3
#
# Changes in v2.7:
#   - Bugfix: when the IIFE ran before React had mounted the chat toolbar, v2.6 fell
#     back to fixed positioning and then the MutationObserver's fast-path early-return
#     prevented it from upgrading to inline-mode once the toolbar appeared. v2.7 tracks
#     attach-mode separately and always re-checks for the toolbar while in fixed-mode,
#     so it transitions to inline as soon as the toolbar exists.
#   - Defensive cleanup at init: removes any pre-existing button with our id before
#     attaching, in case of leftover state from prior IIFE runs.
#
# Changes in v2.6:
#   - Mute button DOM-anchored to .agent-chat__toolbar-left (no fixed pixel coords).
#   - rAF batching for MutationObserver callbacks.
#
# Changes in v2.5:
#   - Default fallback button position changed to left:399px top:843px.
#
# Changes in v2.4:
#   - Right-edge anchor + four position knobs + MutationObserver self-healing.
#
# Changes in v2.3:
#   - Mute sends silence frames (zero-fill) instead of skipping the relay call, keeping
#     the realtime session healthy and the assistant talking while you can't be heard.
#   - Unmute resets the gate so voice reaches the API immediately, triggering OpenAI's
#     natural barge-in. (Local audio buffer drain is out of scope -- expect "trails off".)
#
# Changes in v2.2:
#   - Floating mute button + Ctrl+M shortcut.
#
# Changes in v2.1:
#   - Key is passed to Python via file descriptor 3 instead of an env var,
#     so it is no longer visible in /proc/<pid>/environ during the python process.
#   - Reject extra positional arguments (e.g. "./script.sh --setup-openai-key garbage").
#
# Tested against: OpenClaw 2026.5.2, 2026.5.3
#
# Usage:
#   ./apply-openclaw-firefox-talk-patch.sh
#   ./apply-openclaw-firefox-talk-patch.sh --setup-openai-key
#   ./apply-openclaw-firefox-talk-patch.sh --rollback latest
#   ./apply-openclaw-firefox-talk-patch.sh --prune-backups [N]
#   ./apply-openclaw-firefox-talk-patch.sh --help
#
# Environment overrides:
#   OPENCLAW_ROOT=/path/to/openclaw
#   KEEP_BACKUPS=20                  # backups to retain after auto-prune (default 10)

MODE="${1:-apply}"
ARG2="${2:-}"

if (( $# > 2 )); then
    echo "ERROR: too many arguments. Run with --help for usage." >&2
    exit 1
fi

DEFAULT_ROOT="$HOME/.npm-global/lib/node_modules/openclaw"
BACKUP_BASE="$HOME/temp/openclaw-firefox-talk-patch-backups"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"

mkdir -p "$BACKUP_BASE"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

print_help() {
    cat <<EOF
OpenClaw Firefox Start Talk gateway-relay patch (hardened v2.7.4)

Usage:
  $(basename "$0")                       Apply the patch.
  $(basename "$0") --dry-run             Show what would be patched, without writing.
  $(basename "$0") --setup-openai-key    Store OpenAI API key in ~/.openclaw/.env (mode 600).
  $(basename "$0") --rollback latest     Restore the most recent backup.
  $(basename "$0") --prune-backups [N]   Prune old backups, keeping last N (default \$KEEP_BACKUPS=$KEEP_BACKUPS).
  $(basename "$0") --help                Show this message.

Environment:
  OPENCLAW_ROOT      Override OpenClaw install path detection.
  KEEP_BACKUPS       How many backups to retain (default 10).

Runtime mic-gate tuning (browser DevTools console on the OpenClaw page):
  localStorage.setItem('openclaw.micGateMs', '250')    # stricter, less echo, slower barge-in
  localStorage.setItem('openclaw.micGateMs', '60')     # looser, faster barge-in, more echo risk
  localStorage.removeItem('openclaw.micGateMs')        # back to default 150 ms
  (Hard-refresh the OpenClaw page after changing this.)
EOF
}

resolve_root() {
    if [[ -n "${OPENCLAW_ROOT:-}" ]]; then
        ROOT="$OPENCLAW_ROOT"
    elif [[ -d "$DEFAULT_ROOT" ]]; then
        ROOT="$DEFAULT_ROOT"
    elif [[ -d "/usr/lib/node_modules/openclaw" ]]; then
        ROOT="/usr/lib/node_modules/openclaw"
    else
        die "could not find OpenClaw install root. Set OPENCLAW_ROOT=/path/to/openclaw and retry."
    fi
    DIST="$ROOT/dist"
    [[ -d "$DIST" ]] || die "OpenClaw root '$ROOT' has no dist/ directory."
}

preflight_common() {
    command -v python3 >/dev/null || die "python3 is required but not on PATH."
}

preflight_setup_key() {
    preflight_common
    command -v openclaw >/dev/null || die "openclaw is not on PATH (e.g. add ~/.npm-global/bin to PATH)."
}

preflight_apply() {
    preflight_common
    resolve_root
    find_bundles
    local f
    for f in "$SERVER_METHODS" "$SERVER_IMPL" "$FRONTEND" "$SW_BUNDLE"; do
        [[ -w "$f" ]] || die "no write permission on $f. Run with sudo or fix ownership."
    done
}

find_one() {
    local desc="$1"; shift
    mapfile -t matches < <(find "$@" 2>/dev/null | sort)
    if [[ "${#matches[@]}" -ne 1 ]]; then
        echo "ERROR: expected exactly one $desc, found ${#matches[@]}" >&2
        printf '  %s\n' "${matches[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

find_bundles() {
    # OpenClaw 2026.5.3 introduced a separate server-methods-list-*.js (just a
    # method-name registry, not the bundle we patch). Exclude it explicitly so
    # discovery still resolves to exactly one server-methods bundle.
    SERVER_METHODS="$(find_one 'server-methods bundle' "$DIST" -maxdepth 1 -type f -name 'server-methods-*.js' -not -name 'server-methods-list-*.js')"
    SERVER_IMPL="$(find_one 'server.impl bundle' "$DIST" -maxdepth 1 -type f -name 'server.impl-*.js')"
    FRONTEND="$(find_one 'control-ui index bundle' "$DIST/control-ui/assets" -maxdepth 1 -type f -name 'index-*.js')"
    SW_BUNDLE="$(find_one 'control-ui service worker' "$DIST/control-ui" -maxdepth 1 -type f -name 'sw.js')"
}

prune_backups() {
    local keep="${1:-$KEEP_BACKUPS}"
    [[ "$keep" =~ ^[0-9]+$ ]] || die "prune_backups: keep count must be a non-negative integer (got '$keep')."
    [[ -d "$BACKUP_BASE" ]] || return 0

    local dirs=()
    while IFS= read -r d; do
        dirs+=("$d")
    done < <(find "$BACKUP_BASE" -maxdepth 1 -type d -name 'backup-*' | sort)

    local total="${#dirs[@]}"
    if (( total <= keep )); then
        echo "Backup pruning: $total backup(s) under $BACKUP_BASE, keeping all (limit $keep)."
        return 0
    fi

    local del=$((total - keep))
    echo "Backup pruning: $total backup(s), removing oldest $del (keeping $keep)."
    local i
    for ((i=0; i<del; i++)); do
        echo "  rm -rf ${dirs[$i]}"
        rm -rf "${dirs[$i]}" 2>/dev/null || echo "    WARNING: could not remove ${dirs[$i]}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# OpenAI API key setup
# ---------------------------------------------------------------------------
setup_openai_key() {
    preflight_setup_key

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
    [[ -n "$key" ]] || die "empty key, aborting."

    if [[ "$key" != sk-* && "$key" != sk-proj-* ]]; then
        echo "WARNING: key does not start with sk- or sk-proj-. Continuing because OpenAI key formats can change." >&2
    fi

    # Pass the key via file descriptor 3 (NOT argv, NOT env var):
    #   - argv would expose the key to `ps` for any local user.
    #   - env vars are visible in /proc/<pid>/environ to the same UID and root
    #     for the lifetime of the python process.
    #   - fd-3 here-string lives only in the kernel pipe buffer for this single
    #     python invocation, then disappears.
    python3 - "$env_file" 3<<<"$key" <<'PY'
import sys
from pathlib import Path

env_file = Path(sys.argv[1])

with open(3, 'r', encoding='utf-8') as fd:
    key = fd.read().rstrip('\n')

if not key:
    sys.exit('ERROR: key not received from caller')

lines = env_file.read_text().splitlines() if env_file.exists() else []

out = []
replaced = False
for line in lines:
    if line.startswith('OPENAI_API_KEY='):
        out.append(f'OPENAI_API_KEY={key}')
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f'OPENAI_API_KEY={key}')

env_file.write_text('\n'.join(out).rstrip() + '\n')
PY
    unset key

    chmod 600 "$env_file"
    echo "Stored OPENAI_API_KEY in: $env_file"
    echo "Permissions:"
    ls -l "$env_file"
    echo

    echo "Configuring OpenClaw SecretRef env provider allowlist for OPENAI_API_KEY..."
    if openclaw config set secrets.providers.default \
            --provider-source env --provider-allowlist OPENAI_API_KEY \
        && openclaw config validate; then
        echo
        echo "OPENAI_KEY_SETUP_DONE"
        echo "Restart OpenClaw gateway when ready: openclaw gateway restart"
    else
        cat >&2 <<EOF

WARNING: openclaw config update failed.
The key file is in place at: $env_file
Run these once the gateway is reachable:
  openclaw config set secrets.providers.default --provider-source env --provider-allowlist OPENAI_API_KEY
  openclaw config validate
  openclaw gateway restart
EOF
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
rollback_latest() {
    resolve_root
    find_bundles

    local latest
    latest="$(find "$BACKUP_BASE" -maxdepth 1 -type d -name 'backup-*' | sort | tail -1 || true)"
    [[ -n "$latest" ]] || die "no backup directory found under $BACKUP_BASE"

    echo "Rolling back from: $latest"
    cp -a "$latest/server-methods.js.bak"   "$SERVER_METHODS"
    cp -a "$latest/server.impl.js.bak"      "$SERVER_IMPL"
    cp -a "$latest/control-ui-index.js.bak" "$FRONTEND"
    # sw.js.bak only present in v2.7.4+ backups; skip silently for older ones.
    if [[ -f "$latest/sw.js.bak" ]]; then
        cp -a "$latest/sw.js.bak"           "$SW_BUNDLE"
    else
        echo "Note: backup pre-dates v2.7.4 (no sw.js.bak); SW cache name not rolled back." >&2
    fi

    echo "ROLLBACK_OK"
    echo "Restart OpenClaw gateway after rollback: openclaw gateway restart"
}

# ---------------------------------------------------------------------------
# Apply patch
# ---------------------------------------------------------------------------
apply_patch() {
    local DRY_RUN="${1:-0}"

    preflight_apply

    local TS BACKUP_DIR
    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$BACKUP_BASE/backup-$TS"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: discovery and anchor checks only. No files will be modified."
        echo
    else
        mkdir -p "$BACKUP_DIR"
        cp -a "$SERVER_METHODS" "$BACKUP_DIR/server-methods.js.bak"
        cp -a "$SERVER_IMPL"    "$BACKUP_DIR/server.impl.js.bak"
        cp -a "$FRONTEND"       "$BACKUP_DIR/control-ui-index.js.bak"
        cp -a "$SW_BUNDLE"      "$BACKUP_DIR/sw.js.bak"
    fi

    OPENCLAW_PATCH_DRY_RUN="$DRY_RUN" python3 - "$SERVER_METHODS" "$SERVER_IMPL" "$FRONTEND" "$SW_BUNDLE" <<'PY'
import os, re, sys
from pathlib import Path

DRY_RUN = os.environ.get('OPENCLAW_PATCH_DRY_RUN', '0') == '1'

def _ok(msg):
    print(('WOULD_PATCH: ' if DRY_RUN else 'PATCH_OK: ') + msg)

server_methods = Path(sys.argv[1])
server_impl    = Path(sys.argv[2])
frontend       = Path(sys.argv[3])
sw_bundle      = Path(sys.argv[4])

# ---- Patch 1: server-methods (literal, semantically-stable anchor) ----
SM_OLD = 'if (resolution.provider.createBrowserSession) {'
SM_NEW = 'if (resolution.provider.id !== "openai" && resolution.provider.createBrowserSession) {'

# ---- Patch 2: server.impl (literal, semantically-stable anchor) ----
SI_OLD = '\t"talk.mode": [WRITE_SCOPE],\n\t"update.available": [],'
SI_NEW = ('\t"talk.mode": [WRITE_SCOPE],\n'
          '\t"talk.realtime.relay": [READ_SCOPE],\n'
          '\t"update.available": [],')

# ---- Patch 3: frontend (regex anchor, mangled-name resilient) ----
# Locks on the structural shape of the onaudioprocess arrow and the SEMANTIC
# string `talk.realtime.relayAudio`. Helper functions (lG, sG, ...) can be
# renamed by the minifier across rebuilds without breaking the anchor.
FE_PATTERN = re.compile(
    r'this\.inputProcessor\.onaudioprocess=e=>\{'
    r'if\(this\.closed\)return;'
    r'(let \w+=\w+\(e\.inputBuffer\.getChannelData\(0\)\);'
    r'this\.ctx\.client\.request\(`talk\.realtime\.relayAudio`)'
)
# Replacement: re-emit the head, inject the (cached) gate, then the captured tail.
# this._mgS  = mic-gate seconds, read once per processor instance from
#              localStorage["openclaw.micGateMs"] (ms). Falls back to 0.15 s.
FE_REPL = (
    'this.inputProcessor.onaudioprocess=e=>{'
    'if(this.closed)return;'
    'if(this._mgS===void 0){'
        'try{'
            'const v=parseFloat(localStorage.getItem("openclaw.micGateMs"));'
            'this._mgS=isFinite(v)&&v>=0?v/1000:.15'
        '}catch(_){this._mgS=.15}'
    '}'
    'if(this.outputContext&&this.playhead>this.outputContext.currentTime+this._mgS)return;'
    r'\1'
)
FE_MARKER     = 'this._mgS'                    # presence -> gate (v2.x) already applied
FE_V1_MARKER  = 'currentTime+.15)return;let'   # presence -> v1 patch (hardcoded gate) applied

# ---- Patch 3b (v2.3): silence-frame mute + barge-in on unmute ----
# Anchor matches BOTH unpatched and v2.1-patched bundles -- they share this prefix.
# v2.3 logic:
#   - while muted: zero the input buffer (silence frames flow normally)
#   - on transition mute->unmute: reset playhead so the gate doesn't suppress the next
#     mic frames, letting voice reach OpenAI's VAD immediately to trigger barge-in
MUTE_PATTERN = re.compile(
    r'(this\.inputProcessor\.onaudioprocess=e=>\{if\(this\.closed\)return;)'
)
MUTE_INSERT = (
    'const _m=localStorage.getItem("openclaw.micMuted")==="1";'
    'if(_m)e.inputBuffer.getChannelData(0).fill(0);'
    'else if(this._wasMuted&&this.outputContext)this.playhead=this.outputContext.currentTime;'
    'this._wasMuted=_m;'
)
MUTE_REPL = r'\1' + MUTE_INSERT
MUTE_MARKER_V23 = 'this._wasMuted'
# v2.2 used a simple early-return; if we see that, we replace it with the v2.3 expression.
MUTE_V22_TEXT = 'if(localStorage.getItem("openclaw.micMuted")==="1")return;'

# ---- Patch 3c (v2.8): floating mute button + Ctrl+M shortcut, DOM-anchored ----
# Inserts the mute button as a sibling INSIDE OpenClaw's chat toolbar
# (.agent-chat__toolbar-left), right after the "Start Talk" button.
# v2.8 fix: previous v2.7 attached a fixed-mode floating button on every page
# without a toolbar, which meant Agents/Channels/etc. got the button floating
# over unrelated UI. v2.8 gates attach on the .shell--chat marker: no chat shell
# means no button. The intentional "chat shell present but toolbar selector
# broken" fallback to fixed-mode is preserved.
# v2.7 fix (retained): previous v2.6 had a state-machine bug where if the IIFE ran
# before React mounted the toolbar, the button got stuck in fallback fixed-mode and
# never upgraded to inline-mode when the toolbar appeared. v2.7 tracks attach-mode
# and always re-checks for the toolbar while in fixed-mode.
UI_MARKER_V22 = '/*__OPENCLAW_MUTE_BUTTON_V22__*/'
UI_MARKER_V23 = '/*__OPENCLAW_MUTE_BUTTON_V23__*/'
UI_MARKER_V24 = '/*__OPENCLAW_MUTE_BUTTON_V24__*/'
UI_MARKER_V25 = '/*__OPENCLAW_MUTE_BUTTON_V25__*/'
UI_MARKER_V26 = '/*__OPENCLAW_MUTE_BUTTON_V26__*/'
UI_MARKER_V27 = '/*__OPENCLAW_MUTE_BUTTON_V27__*/'
UI_MARKER_V28 = '/*__OPENCLAW_MUTE_BUTTON_V28__*/'
UI_BLOCK = '\n;' + UI_MARKER_V28 + '''(function(){
if(window.__openclawMuteBtn)return;
window.__openclawMuteBtn=true;
var btn=null;
var attachTarget=null;
var attachMode=null;
var pending=false;
function findInsertionPoint(){
var talkBtn=document.querySelector('button[aria-label="Start Talk"]');
if(talkBtn&&talkBtn.parentElement)return{container:talkBtn.parentElement,after:talkBtn};
var toolbar=document.querySelector('.agent-chat__toolbar-left');
if(toolbar)return{container:toolbar,after:null};
return null;
}
function build(mode){
var b=document.createElement("button");
b.id="__openclaw-mute-btn";
b.title="Toggle microphone (Ctrl+M)";
var base={padding:"6px 12px",border:"none",borderRadius:"6px",cursor:"pointer",fontSize:"12px",fontWeight:"600",fontFamily:"system-ui,sans-serif",letterSpacing:"0.4px",color:"#fff",userSelect:"none",height:"32px",lineHeight:"20px"};
if(mode==="inline"){
Object.assign(b.style,base,{position:"static",marginLeft:"8px",flexShrink:"0",verticalAlign:"middle"});
}else{
var bL=localStorage.getItem("openclaw.muteBtnLeft");
var bR=localStorage.getItem("openclaw.muteBtnRight");
var bT=localStorage.getItem("openclaw.muteBtnTop");
var bB=localStorage.getItem("openclaw.muteBtnBottom");
var fx={position:"fixed",zIndex:"2147483647",boxShadow:"0 2px 6px rgba(0,0,0,0.3)"};
if(bL)fx.left=bL;else if(bR)fx.right=bR;else fx.left="399px";
if(bT)fx.top=bT;else if(bB)fx.bottom=bB;else fx.top="843px";
Object.assign(b.style,base,fx);
}
b.addEventListener("click",toggle);
return b;
}
function render(){if(!btn)return;var m=localStorage.getItem("openclaw.micMuted")==="1";btn.style.backgroundColor=m?"#dc2626":"#10b981";btn.textContent=m?"MIC MUTED":"MIC ON";btn.setAttribute("aria-pressed",String(m));}
function toggle(){var m=localStorage.getItem("openclaw.micMuted")==="1";if(m)localStorage.removeItem("openclaw.micMuted");else localStorage.setItem("openclaw.micMuted","1");render();}
function ensureAttached(){
if(!document.body)return;
// Gate: only show on chat pages. .shell--chat is OpenClaw's BEM modifier on the
// top-level shell when chat mode is active (absent on Agents/Channels/etc.).
var onChat=!!document.querySelector(".shell--chat");
if(!onChat){
if(attachMode==="absent")return;
if(btn&&btn.parentElement)btn.parentElement.removeChild(btn);
btn=null;attachTarget=null;attachMode="absent";
return;
}
// Fast-return ONLY if inline-mode and stable. Fixed-mode always re-checks
// because we want to upgrade to inline as soon as the toolbar appears.
if(attachMode==="inline"&&btn&&attachTarget&&attachTarget.contains(btn)&&document.body.contains(attachTarget))return;
var ip=findInsertionPoint();
// Fast-return if no toolbar AND already fixed-attached: nothing to upgrade to.
if(!ip&&attachMode==="fixed"&&btn&&document.body.contains(btn))return;
// (Re)attach.
if(btn&&btn.parentElement)btn.parentElement.removeChild(btn);
btn=null;
if(ip){
btn=build("inline");
if(ip.after)ip.after.parentNode.insertBefore(btn,ip.after.nextSibling);
else ip.container.appendChild(btn);
attachTarget=ip.container;
attachMode="inline";
}else{
btn=build("fixed");
document.body.appendChild(btn);
attachTarget=document.body;
attachMode="fixed";
}
render();
}
function scheduleCheck(){if(pending)return;pending=true;requestAnimationFrame(function(){pending=false;ensureAttached();});}
function init(){
if(!document.body){setTimeout(init,100);return;}
// Defensive: remove any leftover button with our id from prior IIFE state.
var stale=document.getElementById("__openclaw-mute-btn");
if(stale&&stale.parentElement)stale.parentElement.removeChild(stale);
ensureAttached();
try{var obs=new MutationObserver(scheduleCheck);obs.observe(document.body,{childList:true,subtree:true});}catch(_){}
}
document.addEventListener("keydown",function(e){if(e.ctrlKey&&!e.shiftKey&&!e.altKey&&!e.metaKey&&(e.key==="m"||e.key==="M")){e.preventDefault();toggle();}});
if(document.readyState!=="loading")init();
else document.addEventListener("DOMContentLoaded",init);
})();
'''

def patch_literal(path, old, new, label):
    text = path.read_text()
    if new in text:
        print(f'SKIP already patched: {label}')
        return
    n = text.count(old)
    if n != 1:
        sys.exit(f'ABORT: {label}: expected exactly 1 match in {path.name}, found {n}')
    if not DRY_RUN:
        path.write_text(text.replace(old, new, 1))
    _ok(label)

# ---- Patch 4 (v2.7.4): bump SW cache name to invalidate stale assets ----
# OpenClaw's SW (dist/control-ui/sw.js) is cache-first for /assets/*.js with a
# static cache name ("openclaw-control-v1"). Once an asset URL is cached, it's
# served forever -- our patched bundle never reaches the browser unless the user
# manually unregisters the SW. Bumping CACHE_NAME triggers the SW's existing
# activate-handler cache cleanup (any cache name that doesn't match the current
# CACHE_NAME is deleted), so the new name fills cache-first from network on the
# next page load and the patched bundle is served cleanly.
#
# The replacement suffix ("-mute-v28") is tied to the IIFE marker version, so
# future IIFE bumps automatically also bump this cache name without a separate
# change required here.
SW_PATTERN = re.compile(r'const CACHE_NAME = "openclaw-control-v1[^"]*";')
SW_REPL    = 'const CACHE_NAME = "openclaw-control-v1-mute-v28";'
SW_MARKER  = 'openclaw-control-v1-mute-v28'   # presence -> already patched

def patch_sw(path):
    text = path.read_text()
    label = 'bump SW cache name so re-applied patches actually reach the browser (v2.7.4)'
    if SW_MARKER in text:
        print(f'SKIP already patched: {label}')
        return
    matches = SW_PATTERN.findall(text)
    if len(matches) != 1:
        sys.exit(
            f'ABORT: {label}: expected exactly 1 regex match in {path.name}, found {len(matches)}'
        )
    if not DRY_RUN:
        path.write_text(SW_PATTERN.sub(SW_REPL, text, count=1))
    _ok(label)

def patch_frontend(path):
    text = path.read_text()
    changed = False

    # 3a: gate (v2.x)
    gate_label = 'pause mic relayAudio while assistant audio is queued/playing (configurable gate)'
    if FE_V1_MARKER in text:
        sys.exit(
            f'ABORT: {gate_label}: detected v1 patch (hardcoded 150 ms gate). '
            f'Run --rollback latest first, then re-apply for the configurable gate.'
        )
    if FE_MARKER in text:
        print(f'SKIP already patched: {gate_label}')
    else:
        matches = FE_PATTERN.findall(text)
        if len(matches) != 1:
            sys.exit(
                f'ABORT: {gate_label}: expected exactly 1 regex match in {path.name}, found {len(matches)}'
            )
        text = FE_PATTERN.sub(FE_REPL, text, count=1)
        changed = True
        _ok(gate_label)

    # 3b: silence-frame mute + barge-in on unmute (v2.3)
    mute_label = 'silence-frame mute + barge-in on unmute (v2.3)'
    if MUTE_MARKER_V23 in text:
        print(f'SKIP already patched: {mute_label}')
    elif MUTE_V22_TEXT in text:
        # In-place upgrade from v2.2's early-return mute to v2.3 silence-frame mute.
        text = text.replace(MUTE_V22_TEXT, MUTE_INSERT, 1)
        changed = True
        _ok(mute_label + ' (upgraded from v2.2)')
    else:
        # Fresh insert.
        matches = MUTE_PATTERN.findall(text)
        if len(matches) != 1:
            sys.exit(
                f'ABORT: {mute_label}: expected exactly 1 regex match in {path.name}, found {len(matches)}'
            )
        text = MUTE_PATTERN.sub(MUTE_REPL, text, count=1)
        changed = True
        _ok(mute_label)

    # 3c: UI bootstrap (v2.8: hides on non-chat pages via .shell--chat marker)
    ui_label = 'inject mute button + Ctrl+M shortcut (v2.8, hides on non-chat pages)'
    if UI_MARKER_V28 in text:
        print(f'SKIP already patched: {ui_label}')
    else:
        # Strip any earlier UI block (we appended each at end-of-file with leading '\n;').
        for older_marker, name in (
            (UI_MARKER_V27, 'v2.7'),
            (UI_MARKER_V26, 'v2.6'),
            (UI_MARKER_V25, 'v2.5'),
            (UI_MARKER_V24, 'v2.4'),
            (UI_MARKER_V23, 'v2.3'),
            (UI_MARKER_V22, 'v2.2'),
        ):
            older_start = '\n;' + older_marker
            if older_start in text:
                text = text[:text.index(older_start)]
                print(f'  ... removed {name} UI block')
        text = text + UI_BLOCK
        changed = True
        _ok(ui_label)

    if changed:
        if DRY_RUN:
            print('WOULD_WRITE: control-ui index bundle (gate/mute/UI changes)')
        else:
            path.write_text(text)

patch_literal(server_methods, SM_OLD, SM_NEW,
              'force OpenAI talk.realtime.session to gateway-relay')
patch_literal(server_impl,    SI_OLD, SI_NEW,
              'allow talk.realtime.relay event through EVENT_SCOPE_GUARDS')
patch_frontend(frontend)
patch_sw(sw_bundle)
PY
    local PY_RC=$?
    if (( PY_RC != 0 )); then
        die "patch step failed (Python exit $PY_RC). No file should be in a half-patched state — review the ABORT message above."
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo
        echo "DRY-RUN complete. No files modified."
        echo "Run without --dry-run to apply for real."
        return 0
    fi

    # Post-write JS validation: parse-check each patched bundle. If any fails,
    # restore from the just-made backup and abort.
    if command -v node >/dev/null 2>&1; then
        local check_failed=""
        for pair in \
            "$SERVER_METHODS:server-methods.js.bak" \
            "$SERVER_IMPL:server.impl.js.bak" \
            "$FRONTEND:control-ui-index.js.bak" \
            "$SW_BUNDLE:sw.js.bak"
        do
            local path="${pair%%:*}"
            if ! node --check "$path" >/dev/null 2>&1; then
                echo "ERROR: post-write JS validation failed for $path" >&2
                check_failed="$pair"
                break
            fi
        done
        if [[ -n "$check_failed" ]]; then
            echo "Restoring from backup: $BACKUP_DIR" >&2
            cp -a "$BACKUP_DIR/server-methods.js.bak"   "$SERVER_METHODS"
            cp -a "$BACKUP_DIR/server.impl.js.bak"      "$SERVER_IMPL"
            cp -a "$BACKUP_DIR/control-ui-index.js.bak" "$FRONTEND"
            cp -a "$BACKUP_DIR/sw.js.bak"               "$SW_BUNDLE"
            die "patched file did not parse cleanly. Backups restored. No further changes made."
        fi
        echo "JS validation passed (node --check on all 4 bundles)."
    else
        echo "WARNING: 'node' not on PATH; skipping post-write JS validation." >&2
    fi

    echo
    echo "OpenClaw root: $ROOT"
    echo "Backup dir:    $BACKUP_DIR"
    echo
    echo "Changed files:"
    echo "  $SERVER_METHODS"
    echo "  $SERVER_IMPL"
    echo "  $FRONTEND"
    echo "  $SW_BUNDLE"
    echo
    echo "Diff summary:"
    echo
    diff -u "$BACKUP_DIR/server-methods.js.bak" "$SERVER_METHODS" | sed -n '1,80p' || true
    echo
    diff -u "$BACKUP_DIR/server.impl.js.bak"    "$SERVER_IMPL"    | sed -n '1,80p' || true
    echo
    diff -u "$BACKUP_DIR/control-ui-index.js.bak" "$FRONTEND" | sed -n '/onaudioprocess/,+8p' || true
    echo
    diff -u "$BACKUP_DIR/sw.js.bak" "$SW_BUNDLE" | sed -n '/CACHE_NAME/,+1p' || true
    echo

    prune_backups "$KEEP_BACKUPS" || \
        echo "WARNING: backup pruning had errors; patch was applied successfully." >&2

    echo
    echo "PATCH_DONE"
    echo
    echo "Mute button (v2.8):"
    echo "  Floating MIC ON / MIC MUTED button injected into the OpenClaw chat toolbar,"
    echo "  next to the existing 'Start Talk' button. Anchors to the toolbar DOM, so it"
    echo "  moves with the layout (no fixed pixel coords)."
    echo "  Click it or press Ctrl+M to toggle. State persists in localStorage."
    echo "  - While muted: silence frames flow normally (assistant keeps talking, you"
    echo "    just can't be heard). Connection stays healthy."
    echo "  - On unmute: gate is reset so your voice reaches the API immediately,"
    echo "    triggering OpenAI's natural barge-in to stop the assistant's response."
    echo "  - On non-chat pages (Agents, Channels, etc.): button is hidden. It"
    echo "    re-attaches inline when you return to a chat page."
    echo "  Fallback: on a chat page where the toolbar selector has changed but the"
    echo "  chat shell is still present, the button falls back to fixed positioning"
    echo "  at left:399px top:843px (or your saved knobs)."
    echo
    echo "Tune the mic gate (browser DevTools console on the OpenClaw page):"
    echo "  localStorage.setItem('openclaw.micGateMs', '250')   // stricter no-echo"
    echo "  localStorage.setItem('openclaw.micGateMs', '60')    // faster barge-in"
    echo "  localStorage.removeItem('openclaw.micGateMs')       // back to default 150 ms"
    echo "  Hard-refresh the OpenClaw page after changing this."
    echo
    echo "Optional OpenAI key setup:"
    echo "  $0 --setup-openai-key"
    echo
    echo "Next steps:"
    echo "  openclaw config set talk.provider '\"openai\"' --strict-json"
    echo "  openclaw config set talk.providers.openai.model            '\"gpt-realtime-1.5\"' --strict-json"
    echo "  openclaw config set talk.providers.openai.modelId          '\"gpt-realtime-1.5\"' --strict-json"
    echo "  openclaw config set talk.providers.openai.voice            '\"marin\"'            --strict-json"
    echo "  openclaw config set talk.providers.openai.voiceId          '\"marin\"'            --strict-json"
    echo "  openclaw config set talk.providers.openai.vadThreshold     '0.85'               --strict-json"
    echo "  openclaw config set talk.providers.openai.silenceDurationMs '1000'              --strict-json"
    echo "  openclaw config set talk.providers.openai.prefixPaddingMs   '100'               --strict-json"
    echo "  openclaw config validate"
    echo "  openclaw gateway restart"
    echo
    echo "Rollback latest backup:"
    echo "  $0 --rollback latest"
}

# ---------------------------------------------------------------------------
# Mode dispatch (BEFORE any heavy preflight)
# ---------------------------------------------------------------------------
case "$MODE" in
    apply)
        [[ -z "$ARG2" ]] || die "apply mode does not accept extra arguments. Run with --help for usage."
        apply_patch 0
        ;;
    --dry-run)
        [[ -z "$ARG2" ]] || die "--dry-run does not accept extra arguments."
        apply_patch 1
        ;;
    --setup-openai-key)
        [[ -z "$ARG2" ]] || die "--setup-openai-key does not accept extra arguments."
        setup_openai_key
        ;;
    --rollback)
        if [[ -n "$ARG2" && "$ARG2" != "latest" ]]; then
            die "only '--rollback latest' is supported."
        fi
        rollback_latest
        ;;
    --prune-backups)
        if [[ -z "$ARG2" ]]; then
            prune_backups "$KEEP_BACKUPS"
        else
            [[ "$ARG2" =~ ^[0-9]+$ ]] || die "--prune-backups N requires a non-negative integer."
            prune_backups "$ARG2"
        fi
        ;;
    --help|-h)
        [[ -z "$ARG2" ]] || die "--help does not accept extra arguments."
        print_help
        ;;
    *)
        die "unknown mode: '$MODE'. Run with --help for usage."
        ;;
esac
