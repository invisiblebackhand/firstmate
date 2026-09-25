#!/usr/bin/env bash
# tests/fm-treehouse-pool-isolation.test.sh - regression test for the
# cross-home Treehouse pool collision fixed by bin/fm-wake-lib.sh's
# fm_treehouse_ensure_isolated_pool (called from bin/fm-spawn.sh before every
# `treehouse get`).
#
# Root cause (verified live against the installed treehouse v2.3.0 in a
# disposable sandbox, 2026-09-24): Treehouse keys a pool by
# "<repo-basename>-<sha256(origin-url)[:6]>" under one shared root, never by
# which local clone asked. Two independent clones of the same project - the
# root firstmate home's own clone and a secondmate home's standalone clone,
# both named the same and sharing an origin - therefore resolve to the
# identical pool, and a `treehouse get` from either clone can be handed a
# pre-existing slot that is a linked worktree of the OTHER clone.
# bin/fm-claude-trust.sh correctly refuses that slot (it is not a worktree of
# the project the spawn was given), so the secondmate could never dispatch a
# worker for that project at all. See data/fm-pool-fix/dispatch-blocker.md
# for the field report this fixes.
#
# These tests exercise the REAL treehouse binary end to end (not the fake
# spawn-harness stub other fm-spawn tests use, which stubs treehouse as a
# no-op), because the bug lives entirely inside Treehouse's own pool-naming
# behavior and the fix leans on Treehouse's own supported per-project config.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-isolation)

# make_case <name>: a shared bare origin plus a root-home clone and a
# secondmate-home clone of it, both named "myproj" - the exact shape that
# collides (same basename, same origin, two homes) - plus a scratch $HOME so
# any default resolution stays disposable rather than touching the operator's
# actual home directory. Echoes
# "<case>|<root_home>|<secondmate_home>|<root_clone>|<second_clone>|<scratch_home>".
make_case() {
  local name=$1 case_dir root_home second_home seed origin root_clone second_clone scratch_home
  case_dir="$TMP_ROOT/$name"
  root_home="$case_dir/root-home"
  second_home="$case_dir/secondmate-home"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  scratch_home="$case_dir/scratch-home"
  mkdir -p "$root_home/projects" "$second_home/projects" "$scratch_home"

  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin" >/dev/null

  root_clone="$root_home/projects/myproj"
  second_clone="$second_home/projects/myproj"
  git clone --quiet "$origin" "$root_clone"
  git clone --quiet "$origin" "$second_clone"

  cat > "$second_home/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$root_home
EOF

  printf '%s|%s|%s|%s|%s|%s\n' \
    "$case_dir" "$root_home" "$second_home" "$root_clone" "$second_clone" "$scratch_home"
}

read_case() {
  IFS='|' read -r CASE_DIR ROOT_HOME SECOND_HOME ROOT_CLONE SECOND_CLONE SCRATCH_HOME <<EOF
$1
EOF
}

# slot_common_dir <path>: physically resolved git-common-dir of a Treehouse slot.
slot_common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# treehouse_pool <clone-dir> <treehouse-args...>: run treehouse from
# <clone-dir> with a case-local competing TREEHOUSE_ROOT, as a spawn can
# inherit. Raw calls resolve to that shared pool; a non-root home's acquisition
# must pass --root . to keep its pool inside its own clone. $HOME is also
# case-local so no fallback can touch the operator's actual ~/.treehouse.
treehouse_pool() {
  local clone=$1
  shift
  ( cd "$clone" && HOME="$SCRATCH_HOME" TREEHOUSE_ROOT="$CASE_DIR/shared-treehouse" treehouse "$@" )
}

# prime_shared_pool: acquire and return one slot from the root clone, exactly
# like an earlier root-home spawn that finished and went back to the pool -
# the state every collision starts from in the field report.
prime_shared_pool() {
  local slot
  slot=$(treehouse_pool "$ROOT_CLONE" get --lease --lease-holder root-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "fixture could not prime the shared pool from the root clone"
  treehouse_pool "$ROOT_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "fixture could not return the priming slot to the pool"
}

# run_ensure <project> <home>: fm_treehouse_ensure_isolated_pool in a subshell
# with its own scratch FM_HOME, so sourcing bin/fm-wake-lib.sh never touches
# this real worktree's own state/ directory (it mkdir -p's $FM_HOME/state at
# source time).
run_ensure() {
  local project=$1 home=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    set -u
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_treehouse_ensure_isolated_pool "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$project" "$home"
}

test_reproduces_cross_home_pool_collision() {
  local rec slot
  rec=$(make_case reproduce)
  read_case "$rec"
  prime_shared_pool

  # Without any isolation, the secondmate's own clone reuses that same
  # available slot - a linked worktree of the ROOT's clone, not its own -
  # exactly the refusal bin/fm-claude-trust.sh reported in the field.
  slot=$(treehouse_pool "$SECOND_CLONE" get --lease --lease-holder second-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "fixture could not draw a slot from the shared pool via the secondmate clone"
  [ "$(slot_common_dir "$slot")" = "$(slot_common_dir "$ROOT_CLONE")" ] \
    || fail "fixture did not reproduce the collision: the slot did not come from the root clone"
  [ "$(slot_common_dir "$slot")" != "$(slot_common_dir "$SECOND_CLONE")" ] \
    || fail "fixture did not reproduce the collision: the slot unexpectedly already matched the secondmate clone"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "fixture could not return the collided slot to the shared pool"
  pass "reproduced: an unmodified Treehouse pool hands a secondmate clone a slot linked to the root's own clone"
}

test_ensure_isolated_pool_is_noop_for_root_home() {
  local rec out status
  rec=$(make_case root-noop)
  read_case "$rec"

  out=$(run_ensure "$ROOT_CLONE" "$ROOT_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "fm_treehouse_ensure_isolated_pool should succeed for the root home"$'\n'"$out"
  [ ! -e "$ROOT_CLONE/treehouse.toml" ] \
    || fail "fm_treehouse_ensure_isolated_pool wrote a treehouse.toml for the root home; its pool location must never move"
  pass "fm_treehouse_ensure_isolated_pool is a no-op for the root home's own clone"
}

test_ensure_isolated_pool_fixes_secondmate_collision() {
  local rec out status slot root_status isolated_status
  rec=$(make_case fix-collision)
  read_case "$rec"
  prime_shared_pool

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "fm_treehouse_ensure_isolated_pool should isolate the secondmate's clone"$'\n'"$out"

  slot=$(treehouse_pool "$SECOND_CLONE" get --root . --lease --lease-holder second-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  [ "$(slot_common_dir "$slot")" = "$(slot_common_dir "$SECOND_CLONE")" ] \
    || fail "fix did not resolve the collision: the slot is still not a worktree of the secondmate's own clone"
  case "$slot" in
    "$SECOND_CLONE"/*) : ;;
    *) fail "fix did not place the isolated pool in-project under the secondmate's own clone: $slot" ;;
  esac

  root_status=$(treehouse_pool "$ROOT_CLONE" status --json 2>/dev/null)
  assert_contains "$root_status" '"status":"available"' \
    "fixing the secondmate's pool disturbed the root home's own pool"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot return followed the competing TREEHOUSE_ROOT instead of the slot's owning pool"
  isolated_status=$(treehouse_pool "$SECOND_CLONE" status --root . --json 2>/dev/null)
  assert_contains "$isolated_status" '"status":"available"' \
    "returned isolated slot did not become available in its in-project pool"
  pass "fm_treehouse_ensure_isolated_pool gives the secondmate clone its own in-project pool without touching the root's"
}

test_ensure_isolated_pool_is_idempotent() {
  local rec out status before after
  rec=$(make_case idempotent)
  read_case "$rec"

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "first isolation call should succeed"$'\n'"$out"
  before=$(cat "$SECOND_CLONE/treehouse.toml")

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "repeating the isolation call should be idempotent"$'\n'"$out"
  after=$(cat "$SECOND_CLONE/treehouse.toml")
  [ "$before" = "$after" ] || fail "repeating fm_treehouse_ensure_isolated_pool changed the existing config"
  pass "fm_treehouse_ensure_isolated_pool is idempotent"
}

test_ensure_isolated_pool_refuses_incompatible_existing_config() {
  local rec out status
  rec=$(make_case incompatible)
  read_case "$rec"
  printf 'root = "/custom/pool"\n' > "$SECOND_CLONE/treehouse.toml"

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm_treehouse_ensure_isolated_pool overwrote an existing treehouse.toml it did not recognize"
  assert_contains "$out" "already exists" "refusal did not explain the pre-existing config"
  [ "$(cat "$SECOND_CLONE/treehouse.toml")" = 'root = "/custom/pool"' ] \
    || fail "fm_treehouse_ensure_isolated_pool modified a pre-existing config it should have left alone"
  pass "fm_treehouse_ensure_isolated_pool refuses to overwrite an incompatible pre-existing treehouse.toml"
}

test_ensure_isolated_pool_keeps_project_clean_after_get() {
  local rec out status slot porcelain
  rec=$(make_case exclude)
  read_case "$rec"

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "isolation call should succeed"$'\n'"$out"
  slot=$(treehouse_pool "$SECOND_CLONE" get --root . --lease --lease-holder clean-project-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  case "$slot" in
    "$SECOND_CLONE/.treehouse/"*) : ;;
    *) fail "in-project Treehouse pool was not created under .treehouse/: $slot" ;;
  esac
  porcelain=$(git -C "$SECOND_CLONE" status --porcelain)
  [ -z "$porcelain" ] || fail "Treehouse isolation artifacts dirty the secondmate clone: $porcelain"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot could not be returned after the clean-project check"
  pass "Treehouse isolation config and pool state leave the secondmate clone clean"
}

test_reproduces_cross_home_pool_collision
test_ensure_isolated_pool_is_noop_for_root_home
test_ensure_isolated_pool_fixes_secondmate_collision
test_ensure_isolated_pool_is_idempotent
test_ensure_isolated_pool_refuses_incompatible_existing_config
test_ensure_isolated_pool_keeps_project_clean_after_get

echo "# all fm-treehouse-pool-isolation tests passed"
