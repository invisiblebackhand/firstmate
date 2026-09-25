#!/usr/bin/env bash
# tests/fm-treehouse-pool-isolation.test.sh - real-Treehouse regression for
# the cross-clone pool collision described by
# fm_treehouse_ensure_isolated_pool in bin/fm-wake-lib.sh, and for the
# CLAUDE.md-ancestor regression an earlier in-project fix (root = ".") caused:
# a non-root home's isolated pool must sit outside every Firstmate home's own
# directory tree, not just outside other clones.
# It proves the collision, root-home no-op, out-of-home-tree isolation, config
# refusal, legacy in-project migration, project-less aliasing avoidance, clean
# Git porcelain, and acquire-to-return lifecycle under a competing
# TREEHOUSE_ROOT; fake spawn-harness Treehouse stubs cannot cover those facts.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-isolation)

# make_case <name>: a shared bare origin plus a root-home clone and a
# secondmate-home clone of it, both named "myproj" - the exact shape that
# collides (same basename, same origin, two homes) - plus a scratch $HOME so
# any default resolution, including fm_treehouse_pool_root's XDG_STATE_HOME
# fallback, stays disposable rather than touching the operator's actual home
# directory. Echoes
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

  # A CLAUDE.md importing outside the project tree, exactly the shape every
  # Firstmate home carries (AGENTS.md via @AGENTS.md), so a test can assert an
  # isolated pool path never lands under either home.
  printf '@AGENTS.md\n' > "$second_home/CLAUDE.md"
  printf '# scratch home AGENTS\n' > "$second_home/AGENTS.md"

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

# under_tree <path> <tree>: true when <path> is <tree> itself or nested under it.
under_tree() {
  case "$1" in
    "$2" | "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# treehouse_pool <clone-dir> <treehouse-args...>: run treehouse from
# <clone-dir> with a case-local competing TREEHOUSE_ROOT, as a spawn can
# inherit. Raw calls resolve to that shared pool; a non-root home's acquisition
# must pass an explicit --root to keep its pool out of that shared location.
# $HOME is also case-local so no fallback can touch the operator's actual
# ~/.treehouse or ~/.local/state.
treehouse_pool() {
  local clone=$1
  shift
  ( cd "$clone" && HOME="$SCRATCH_HOME" TREEHOUSE_ROOT="$CASE_DIR/shared-treehouse" treehouse "$@" )
}

# prime_shared_pool: acquire and return one slot from the root clone so the
# shared pool can hand that clone's available worktree to another clone.
prime_shared_pool() {
  local slot
  slot=$(treehouse_pool "$ROOT_CLONE" get --lease --lease-holder root-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "fixture could not prime the shared pool from the root clone"
  treehouse_pool "$ROOT_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "fixture could not return the priming slot to the pool"
}

# run_ensure <project> <home>: fm_treehouse_ensure_isolated_pool in a subshell
# with its own scratch FM_HOME and HOME, so sourcing bin/fm-wake-lib.sh never
# touches this real worktree's own state/ directory (it mkdir -p's
# $FM_HOME/state at source time), and fm_treehouse_pool_root's
# ${XDG_STATE_HOME:-$HOME/.local/state} fallback never touches the operator's
# real machine state either.
run_ensure() {
  local project=$1 home=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" HOME="$SCRATCH_HOME" \
    XDG_STATE_HOME='' bash -c '
    set -u
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_treehouse_ensure_isolated_pool "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$project" "$home"
}

# pool_root_for <project>: the same absolute pool root fm_treehouse_ensure_isolated_pool
# writes for <project>, computed directly so tests can pass it to `treehouse`
# explicitly - exactly how fm-spawn.sh's own --root flag is built.
pool_root_for() {
  local project=$1
  HOME="$SCRATCH_HOME" XDG_STATE_HOME='' bash -c '
    set -u
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_treehouse_pool_root "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$project"
}

test_reproduces_cross_home_pool_collision() {
  local rec slot
  rec=$(make_case reproduce)
  read_case "$rec"
  prime_shared_pool

  # Without isolation, the secondmate's clone reuses the root clone's available
  # slot, which is not a linked worktree of the project the spawn was given.
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
  local rec out status pool_root slot root_status isolated_status
  rec=$(make_case fix-collision)
  read_case "$rec"
  prime_shared_pool

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "fm_treehouse_ensure_isolated_pool should isolate the secondmate's clone"$'\n'"$out"
  pool_root=$(pool_root_for "$SECOND_CLONE")
  [ -n "$pool_root" ] || fail "could not compute the secondmate clone's isolated pool root"

  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder second-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  [ "$(slot_common_dir "$slot")" = "$(slot_common_dir "$SECOND_CLONE")" ] \
    || fail "fix did not resolve the collision: the slot is still not a worktree of the secondmate's own clone"

  root_status=$(treehouse_pool "$ROOT_CLONE" status --json 2>/dev/null)
  assert_contains "$root_status" '"status":"available"' \
    "fixing the secondmate's pool disturbed the root home's own pool"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot return followed the competing TREEHOUSE_ROOT instead of the slot's owning pool"
  isolated_status=$(treehouse_pool "$SECOND_CLONE" status --root "$pool_root" --json 2>/dev/null)
  assert_contains "$isolated_status" '"status":"available"' \
    "returned isolated slot did not become available in its own isolated pool"
  pass "fm_treehouse_ensure_isolated_pool gives the secondmate clone its own pool without touching the root's"
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
  local rec out status pool_root slot porcelain
  rec=$(make_case exclude)
  read_case "$rec"

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "isolation call should succeed"$'\n'"$out"
  pool_root=$(pool_root_for "$SECOND_CLONE")
  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder clean-project-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  porcelain=$(git -C "$SECOND_CLONE" status --porcelain)
  [ -z "$porcelain" ] || fail "Treehouse isolation artifacts dirty the secondmate clone: $porcelain"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot could not be returned after the clean-project check"
  pass "Treehouse isolation config and pool state leave the secondmate clone clean"
}

# The regression this whole isolation exists to avoid now: PR #7's in-project
# `root = "."` kept a non-root home's pool inside that home's own directory
# tree, so Claude Code discovered the home's own CLAUDE.md as an ancestor of
# every leased worktree and gated each first launch behind its
# "Allow external CLAUDE.md file imports?" dialog - a dialog `fm-control.sh
# interrupt`'s Escape does not merely dismiss on Claude Code 2.1.282, it
# answers with an explicit decline that then wedges every later launch. The
# isolated pool root, and the leased worktree Treehouse creates under it, must
# never sit inside the home's own directory tree.
test_ensure_isolated_pool_keeps_pool_outside_home_tree() {
  local rec out status pool_root slot
  rec=$(make_case outside-home)
  read_case "$rec"

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "isolation call should succeed"$'\n'"$out"
  pool_root=$(pool_root_for "$SECOND_CLONE")
  [ -n "$pool_root" ] || fail "could not compute the secondmate clone's isolated pool root"
  ! under_tree "$pool_root" "$SECOND_HOME" \
    || fail "isolated pool root sits inside the secondmate home's own directory tree: $pool_root"
  ! under_tree "$pool_root" "$ROOT_HOME" \
    || fail "isolated pool root sits inside the root home's own directory tree: $pool_root"

  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder outside-home-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  ! under_tree "$slot" "$SECOND_HOME" \
    || fail "leased worktree sits inside the secondmate home's own directory tree, inheriting its CLAUDE.md: $slot"
  ! under_tree "$slot" "$ROOT_HOME" \
    || fail "leased worktree sits inside the root home's own directory tree, inheriting its CLAUDE.md: $slot"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot could not be returned after the outside-home-tree check"
  pass "fm_treehouse_ensure_isolated_pool's pool root and leased worktrees stay outside every home's directory tree"
}

# A clone already carrying PR #7's legacy `root = "."` (with a live slot
# leased under it) must migrate its config pointer to the new out-of-home-tree
# root without disturbing that slot: `treehouse return` locates a slot from
# the given path, never from the current config, so the old slot keeps
# tearing down correctly even after the config changes underneath it.
test_ensure_isolated_pool_migrates_legacy_in_project_config() {
  local rec out status legacy_slot pool_root migrated_slot new_status
  rec=$(make_case legacy-migrate)
  read_case "$rec"

  printf 'root = "."\n' > "$SECOND_CLONE/treehouse.toml"
  legacy_slot=$(treehouse_pool "$SECOND_CLONE" get --root . --lease --lease-holder legacy-task 2>/dev/null)
  [ -n "$legacy_slot" ] && [ -d "$legacy_slot" ] || fail "fixture could not lease a slot under the legacy in-project config"
  case "$legacy_slot" in
    "$SECOND_CLONE"/.treehouse/*) : ;;
    *) fail "fixture did not reproduce the legacy in-project pool shape: $legacy_slot" ;;
  esac

  out=$(run_ensure "$SECOND_CLONE" "$SECOND_HOME" 2>&1)
  status=$?
  expect_code 0 "$status" "migrating a legacy in-project config should succeed"$'\n'"$out"
  pool_root=$(pool_root_for "$SECOND_CLONE")
  migrated_slot=$(
    cd "$SECOND_CLONE" || exit 1
    unset TREEHOUSE_ROOT
    HOME="$SCRATCH_HOME" treehouse get --lease --lease-holder migrated-task 2>/dev/null
  )
  [ -n "$migrated_slot" ] && [ -d "$migrated_slot" ] \
    || fail "migrated project config could not acquire a Treehouse slot"
  under_tree "$migrated_slot" "$pool_root" \
    || fail "migrated project config acquired a slot outside the isolated pool root: $migrated_slot"

  [ -d "$legacy_slot" ] \
    || fail "migrating the config pointer disturbed the already-leased legacy slot on disk: $legacy_slot"
  treehouse_pool "$SECOND_CLONE" return --force "$legacy_slot" >/dev/null 2>&1 \
    || fail "the legacy slot could not be returned after the config migrated - teardown would strand it"
  new_status=$(treehouse_pool "$SECOND_CLONE" status --root . --json 2>/dev/null)
  assert_contains "$new_status" '"status":"available"' \
    "returned legacy slot did not become available again in its own (legacy) in-project pool"
  treehouse_pool "$SECOND_CLONE" return --force "$migrated_slot" >/dev/null 2>&1 \
    || fail "the config-resolved migrated slot could not be returned"
  pass "fm_treehouse_ensure_isolated_pool migrates a legacy in-project config while still returning its live slot"
}

# A project-less secondmate home's crews take pooled worktrees of the home's
# own firstmate checkout (its "project" is the home directory itself). Under
# the legacy in-project `root = "."`, Treehouse resolves the relative "."
# against the repository's git-discovered main worktree rather than the
# caller's cwd, so two different project-less homes - both linked worktrees of
# one shared origin - could alias the SAME pool. Computing an absolute root
# from each home's own resolved path, as fm_treehouse_pool_root does, never
# depends on that relative resolution and so never aliases them.
test_ensure_isolated_pool_avoids_projectless_home_aliasing() {
  local case_dir seed home_a home_b root_a root_b slot_a slot_b
  case_dir="$TMP_ROOT/projectless"
  seed="$case_dir/seed"
  home_a="$case_dir/home-a"
  home_b="$case_dir/home-b"
  SCRATCH_HOME="$case_dir/scratch-home"
  mkdir -p "$SCRATCH_HOME"

  # Two project-less homes are two linked worktrees of one shared firstmate
  # repo, exactly like real secondmate homes leased from the root's own pool.
  fm_git_worktree "$seed" "$home_a" home-a-branch
  git -C "$seed" worktree add --quiet -b home-b-branch "$home_b"

  root_a=$(pool_root_for "$home_a")
  root_b=$(pool_root_for "$home_b")
  [ -n "$root_a" ] && [ -n "$root_b" ] || fail "could not compute pool roots for the project-less homes"
  [ "$root_a" != "$root_b" ] \
    || fail "two different project-less homes computed the same isolated pool root: $root_a"

  CASE_DIR=$case_dir
  slot_a=$(treehouse_pool "$home_a" get --root "$root_a" --lease --lease-holder home-a-task 2>/dev/null)
  slot_b=$(treehouse_pool "$home_b" get --root "$root_b" --lease --lease-holder home-b-task 2>/dev/null)
  [ -n "$slot_a" ] && [ -d "$slot_a" ] || fail "home-a could not draw a slot from its own isolated pool"
  [ -n "$slot_b" ] && [ -d "$slot_b" ] || fail "home-b could not draw a slot from its own isolated pool"
  # Both homes are linked worktrees of the SAME shared repo, so their slots'
  # git-common-dir is expected to match (that is what "worktree of the shared
  # repo" means) - the property under test is that each home's slot physically
  # lives under that home's OWN pool root and never the other home's, which is
  # exactly what a shared-root aliasing bug would violate.
  [ "$(slot_common_dir "$slot_a")" = "$(slot_common_dir "$home_a")" ] \
    || fail "home-a's slot is not a worktree of the shared checkout: $slot_a"
  [ "$(slot_common_dir "$slot_b")" = "$(slot_common_dir "$home_b")" ] \
    || fail "home-b's slot is not a worktree of the shared checkout: $slot_b"
  under_tree "$slot_a" "$root_a" \
    || fail "home-a's slot did not land under home-a's own isolated pool root: $slot_a"
  under_tree "$slot_b" "$root_b" \
    || fail "home-b's slot did not land under home-b's own isolated pool root: $slot_b"
  ! under_tree "$slot_a" "$root_b" \
    || fail "home-a's slot landed under home-b's isolated pool root, an aliasing collision: $slot_a"
  ! under_tree "$slot_b" "$root_a" \
    || fail "home-b's slot landed under home-a's isolated pool root, an aliasing collision: $slot_b"

  treehouse_pool "$home_a" return --root "$root_a" --force "$slot_a" >/dev/null 2>&1 \
    || fail "home-a's slot could not be returned"
  treehouse_pool "$home_b" return --root "$root_b" --force "$slot_b" >/dev/null 2>&1 \
    || fail "home-b's slot could not be returned"
  pass "fm_treehouse_pool_root gives two project-less homes of one shared repo distinct, non-aliasing pools"
}

test_reproduces_cross_home_pool_collision
test_ensure_isolated_pool_is_noop_for_root_home
test_ensure_isolated_pool_fixes_secondmate_collision
test_ensure_isolated_pool_is_idempotent
test_ensure_isolated_pool_refuses_incompatible_existing_config
test_ensure_isolated_pool_keeps_project_clean_after_get
test_ensure_isolated_pool_keeps_pool_outside_home_tree
test_ensure_isolated_pool_migrates_legacy_in_project_config
test_ensure_isolated_pool_avoids_projectless_home_aliasing

echo "# all fm-treehouse-pool-isolation tests passed"
