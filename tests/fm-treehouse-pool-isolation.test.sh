#!/usr/bin/env bash
# tests/fm-treehouse-pool-isolation.test.sh - real-Treehouse regression for
# the cross-clone pool collision and for the CLAUDE.md-ancestor regression an
# earlier in-project fix (root = ".") caused: a non-root home's isolated pool
# must sit outside the active Firstmate home and its root home's directory
# tree, not just outside other clones. It proves the collision, explicit-root
# precedence, out-of-home-tree isolation, legacy-config preservation,
# project-less aliasing avoidance, clean Git porcelain, and acquire-to-return
# lifecycle under competing environment and project roots; fake spawn-harness
# Treehouse stubs cannot cover those facts.
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

# pool_root_for <project> <home> [xdg-state-home]: compute the same absolute
# pool root fm-spawn.sh passes directly to `treehouse get --root`.
pool_root_for() {
  local project=$1 home=$2 xdg_state_home=${3-}
  FM_HOME="$home" FM_STATE_OVERRIDE="$SCRATCH_HOME/helper-state" \
    HOME="$SCRATCH_HOME" XDG_STATE_HOME="$xdg_state_home" bash -c '
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

test_pool_root_falls_back_from_relative_xdg_state_home() {
  local rec hash pool_root slot
  rec=$(make_case relative-xdg)
  read_case "$rec"

  hash=$(printf '%s' "$SECOND_CLONE" | git hash-object --stdin)
  pool_root="$SCRATCH_HOME/.local/state/firstmate/treehouse-pools/$hash"
  [ "$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME" relative-state)" = "$pool_root" ] \
    || fail "relative XDG_STATE_HOME did not fall back to the absolute HOME-based pool"
  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder relative-xdg-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "relative XDG_STATE_HOME fallback could not acquire a Treehouse slot"
  under_tree "$slot" "$pool_root" \
    || fail "relative XDG_STATE_HOME did not fall back to the absolute HOME-based pool: $slot"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "relative-XDG fallback slot could not be returned"
  pass "fm_treehouse_pool_root ignores a relative XDG_STATE_HOME"
}

test_explicit_isolated_pool_fixes_secondmate_collision() {
  local rec pool_root slot root_status isolated_status
  rec=$(make_case fix-collision)
  read_case "$rec"
  prime_shared_pool

  pool_root=$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME")
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
  pass "an explicit isolated root gives the secondmate clone its own pool without touching the root's"
}

test_explicit_root_overrides_project_config_without_mutating_it() {
  local rec config_pool pool_root slot porcelain
  rec=$(make_case project-config)
  read_case "$rec"
  config_pool="$CASE_DIR/operator-pool"
  printf 'root = "%s"\n' "$config_pool" > "$SECOND_CLONE/treehouse.toml"
  git -C "$SECOND_CLONE" add treehouse.toml
  git -C "$SECOND_CLONE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'track project Treehouse config'

  pool_root=$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME")
  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder project-config-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "explicit root could not acquire with a project config present"
  under_tree "$slot" "$pool_root" \
    || fail "project config overrode the explicit isolated root: $slot"
  ! under_tree "$slot" "$config_pool" \
    || fail "explicit root acquisition used the project-configured pool: $slot"
  porcelain=$(git -C "$SECOND_CLONE" status --porcelain)
  [ -z "$porcelain" ] || fail "explicit root acquisition modified the tracked project config: $porcelain"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "the project-config override slot could not be returned"
  pass "an explicit root overrides project config without modifying it"
}

test_explicit_isolated_pool_keeps_project_clean_after_get() {
  local rec pool_root slot porcelain
  rec=$(make_case exclude)
  read_case "$rec"

  pool_root=$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME")
  slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder clean-project-task 2>/dev/null)
  [ -n "$slot" ] && [ -d "$slot" ] || fail "isolated secondmate clone could not draw a Treehouse slot"
  [ ! -e "$SECOND_CLONE/treehouse.toml" ] \
    || fail "explicit isolated acquisition created a project treehouse.toml"
  porcelain=$(git -C "$SECOND_CLONE" status --porcelain)
  [ -z "$porcelain" ] || fail "Treehouse isolation artifacts dirty the secondmate clone: $porcelain"
  treehouse_pool "$SECOND_CLONE" return --force "$slot" >/dev/null 2>&1 \
    || fail "isolated slot could not be returned after the clean-project check"
  pass "an explicit isolated pool leaves the secondmate clone clean"
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
test_explicit_isolated_pool_stays_outside_home_tree() {
  local rec pool_root slot
  rec=$(make_case outside-home)
  read_case "$rec"

  pool_root=$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME")
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
  pass "the explicit pool root and leased worktrees stay outside the active and root homes"
}

# A clone already carrying PR #7's legacy `root = "."` (with a live slot
# leased under it) must remain untouched while the explicit root acquires from
# the new out-of-home-tree pool. `treehouse return` locates a slot from the
# given path, never from the current config, so both slots still return to
# their owning pools.
test_explicit_root_bypasses_legacy_in_project_config() {
  local rec legacy_slot pool_root isolated_slot legacy_status
  rec=$(make_case legacy-migrate)
  read_case "$rec"

  printf 'root = "."\n' > "$SECOND_CLONE/treehouse.toml"
  legacy_slot=$(treehouse_pool "$SECOND_CLONE" get --root . --lease --lease-holder legacy-task 2>/dev/null)
  [ -n "$legacy_slot" ] && [ -d "$legacy_slot" ] || fail "fixture could not lease a slot under the legacy in-project config"
  case "$legacy_slot" in
    "$SECOND_CLONE"/.treehouse/*) : ;;
    *) fail "fixture did not reproduce the legacy in-project pool shape: $legacy_slot" ;;
  esac

  pool_root=$(pool_root_for "$SECOND_CLONE" "$SECOND_HOME")
  isolated_slot=$(treehouse_pool "$SECOND_CLONE" get --root "$pool_root" --lease --lease-holder isolated-task 2>/dev/null)
  [ -n "$isolated_slot" ] && [ -d "$isolated_slot" ] \
    || fail "explicit root could not acquire while the legacy config remained"
  under_tree "$isolated_slot" "$pool_root" \
    || fail "legacy project config overrode the explicit isolated root: $isolated_slot"
  [ "$(cat "$SECOND_CLONE/treehouse.toml")" = 'root = "."' ] \
    || fail "explicit isolated acquisition modified the legacy project config"

  [ -d "$legacy_slot" ] \
    || fail "explicit isolated acquisition disturbed the already-leased legacy slot on disk: $legacy_slot"
  treehouse_pool "$SECOND_CLONE" return --force "$legacy_slot" >/dev/null 2>&1 \
    || fail "the legacy slot could not be returned after explicit isolated acquisition"
  legacy_status=$(treehouse_pool "$SECOND_CLONE" status --root . --json 2>/dev/null)
  assert_contains "$legacy_status" '"status":"available"' \
    "returned legacy slot did not become available again in its own (legacy) in-project pool"
  treehouse_pool "$SECOND_CLONE" return --force "$isolated_slot" >/dev/null 2>&1 \
    || fail "the explicit isolated slot could not be returned"
  pass "an explicit root bypasses legacy project config without disturbing its live slot"
}

# A project-less secondmate home's crews take pooled worktrees of the home's
# own firstmate checkout (its "project" is the home directory itself). Under
# the legacy in-project `root = "."`, Treehouse resolves the relative "."
# against the repository's git-discovered main worktree rather than the
# caller's cwd, so two different project-less homes - both linked worktrees of
# one shared origin - could alias the SAME pool. Computing an absolute root
# from each home's own resolved path, as fm_treehouse_pool_root does, never
# depends on that relative resolution and so never aliases them.
test_pool_root_avoids_projectless_home_aliasing() {
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

  root_a=$(pool_root_for "$home_a" "$home_a")
  root_b=$(pool_root_for "$home_b" "$home_b")
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
test_pool_root_falls_back_from_relative_xdg_state_home
test_explicit_isolated_pool_fixes_secondmate_collision
test_explicit_root_overrides_project_config_without_mutating_it
test_explicit_isolated_pool_keeps_project_clean_after_get
test_explicit_isolated_pool_stays_outside_home_tree
test_explicit_root_bypasses_legacy_in_project_config
test_pool_root_avoids_projectless_home_aliasing

echo "# all fm-treehouse-pool-isolation tests passed"
