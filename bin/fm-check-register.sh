#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
BACKUP=
BACKUP_TMP=
cleanup() {
  local cleanup_path
  if [ -n "$TMP" ]; then
    cleanup_path=$TMP
    TMP=
    rm -f -- "$cleanup_path"
  fi
  if [ -n "$BACKUP_TMP" ]; then
    cleanup_path=$BACKUP_TMP
    BACKUP_TMP=
    rm -f -- "$cleanup_path"
  fi
  if [ -n "$BACKUP" ]; then
    cleanup_path=$BACKUP
    BACKUP=
    rm -f -- "$TRUST"
    mv -f -- "$cleanup_path" "$TRUST" || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
if [ -e "$TRUST" ] && fm_custom_check_trust_read "$STATE" "$ID" \
  && [ "$FM_CUSTOM_CHECK_HASH" = "$HASH" ]; then
  BACKUP_TMP=$(mktemp "$STATE/.fm-custom-check-trust-backup.XXXXXX") || exit 1
  cp -p "$TRUST" "$BACKUP_TMP" || exit 1
  BACKUP=$BACKUP_TMP
  BACKUP_TMP=
fi
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
if ! fm_custom_check_registered "$STATE" "$ID"; then
  [ -n "$BACKUP" ] || rm -f -- "$TRUST"
  exit 1
fi
if [ -n "$BACKUP" ]; then
  rm -f -- "$BACKUP" || exit 1
  BACKUP=
fi
printf 'registered: state/%s.check.sh\n' "$ID"
