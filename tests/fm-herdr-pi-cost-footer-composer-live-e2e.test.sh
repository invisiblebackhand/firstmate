#!/usr/bin/env bash
# Default-on live guard for the Pi cost/mode footer composer carve-out (task
# fm-pi-codex-auth) against the REAL Pi harness under the REAL Herdr binary.
#
# The defect: a genuinely idle, live Pi renders its own cost/mode footer row
# directly below its separator pair (e.g. `$0.000 (sub) 0.0%/272k (auto) ...`).
# That row's leading `$` satisfies bin/fm-composer-lib.sh's bare shell-glyph
# match, so the cursorless dead-shell staleness rule misread Pi's own live
# footer as a stale shell prompt sitting below the pair, and
# fm_backend_composer_state read a genuinely idle Pi composer as `unknown`.
# bin/fm-control.sh's relaunch refused to type Pi's `/quit` exit command on
# exactly this verdict ("composer state is 'unknown', not proven empty").
#
# This is a harness-dependent check (the verdict rests on Pi's own rendered
# footer text, which no fixture can prove is still what a current Pi release
# draws), so it must be proven against the real binary per
# .agents/skills/firstmate-coding-guidelines. Pi is launched with no prompt
# and quit immediately, so no model token is spent and the shared live gate
# runs it by default wherever both tools are installed.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation).
# Project-local resources are disabled for this run, so a fresh gate worktree
# cannot park on Pi's trust dialog and the guard does not persist a trust choice
# in the operator's user data. Session persistence is disabled for the same
# reason. Neither setting changes Pi's composer or its native Herdr identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_PI_COST_FOOTER_COMPOSER_LIVE_E2E herdr pi jq

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

SESSION="fm-lab-pi-footer-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  local status=$?
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"
WS=$(lab workspace create --label fm-pi-footer --cwd "$ROOT" 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_ID" ] || fail "workspace create did not return a root pane id"
TARGET="$SESSION:$PANE_ID"

registered_status() {
  herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

lab pane run "$PANE_ID" pi --no-approve --no-session >/dev/null 2>&1 \
  || fail "could not start pi in the pane"

STATUS=
for _ in $(seq 1 300); do
  STATUS=$(registered_status)
  [ "$STATUS" = idle ] && break
  sleep 0.2
done
[ "$STATUS" = idle ] || version_fail \
  "pi never settled to an idle lifecycle state in this pane (agent get read '${STATUS:-agent_not_found}' after 60s)"

# Let the TUI finish drawing its footer row before reading the composer.
sleep 1
SCREEN=$(fm_backend_herdr_capture_ansi "$TARGET" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null)
COMPOSER=$(fm_backend_composer_state herdr "$TARGET")
if [ "$COMPOSER" != empty ]; then
  version_fail \
    "a running, idle pi's own composer reads '$COMPOSER' rather than 'empty'; bin/fm-control.sh relaunch would refuse to type pi's /quit exit command. Captured screen tail: $(printf '%s' "$SCREEN" | tail -6 | tr '\n' '|')"
fi
note "pi $PI_VERSION under herdr $HERDR_VERSION: idle composer classified $COMPOSER"
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a running idle pi's own cost/mode footer never reads as a dead shell prompt"
