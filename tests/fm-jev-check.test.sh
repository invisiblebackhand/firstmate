#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-check.sh.
#
# The fake curl serves a fixture models listing, so these checks never contact
# TypeSafe and still exercise the public watcher-check interface end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-jev-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-check)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
MODELS="$TMP_ROOT/models.json"
CALLS="$TMP_ROOT/curl.calls"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -D) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'called\n' >> "${FAKE_CURL_CALLS:?}"
cp "${FAKE_CURL_MODELS:?}" "$out"
printf 200
SH
chmod 0700 "$FAKEBIN/curl"

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state"
  printf 'TYPESAFE_API_KEY=fixture-key\n' > "$home/.env"
  printf '%s\n' "$home"
}

write_models() {  # <release date>
  cat > "$MODELS" <<JSON
{"models":[{"name":"jev-latest","description":"Current Jev alias.","release_date":"$1"}]}
JSON
}

run_check() {  # <home> <output> [<now-epoch>]
  local home=$1 out=$2 now=${3:-1760000000} status=0
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_CALLS="$CALLS" FAKE_CURL_MODELS="$MODELS" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_JEV_CHECK_NOW="$now" "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "Jev check exits"
}

test_alias_move_records_baseline_then_alerts_once() {
  local home out
  home=$(make_home alias)
  out="$TMP_ROOT/alias/out"
  write_models 2026-09-10
  : > "$CALLS"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the first alias observation must establish a baseline, got: $(cat "$out")"
  assert_equals '2026-09-10' "$(cat "$home/state/.jev-monitor-alias")" "baseline release date was not stored"
  assert_equals '1' "$(wc -l < "$CALLS" | tr -d '[:space:]')" "the alias check did not make one fixture request"

  write_models 2026-10-01
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev alias moved: jev-latest release_date 2026-09-10 -> 2026-10-01' "an alias move was not reported"
  assert_contains "$(cat "$out")" 'replay dispatch tests before any pin bump' "the alias report omitted the replay requirement"

  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged alias move repeated: $(cat "$out")"
  pass "Jev alias move establishes a baseline and reports once with the replay gate"
}

test_spend_thresholds_use_the_per_home_resolver_ledger() {
  local home out ledger
  home=$(make_home spend)
  out="$TMP_ROOT/spend/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_fixture"}' > "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev spend alert: per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "the daily threshold was not calculated from fixture tokens"
  assert_not_contains "$(cat "$out")" 'month-to-date' "the month threshold fired below 10 USD"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged spend threshold repeated: $(cat "$out")"

  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":220000000,"x-typesafe-request-id":"req_fixture_2"}' >> "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.29 USD reaches the 10 USD local threshold' "the monthly threshold was not calculated from fixture tokens"
  printf '%s\n' '{"at":1760000000,"task":"fixture","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":1000000,"x-typesafe-request-id":"req_fixture_3"}' >> "$ledger"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "additional spend above an already-crossed threshold repeated: $(cat "$out")"
  pass "Jev spend thresholds read the per-home resolver ledger without repeating alerts"
}

test_malformed_local_record_fails_closed() {
  local home out ledger
  home=$(make_home malformed-ledger)
  out="$TMP_ROOT/malformed-ledger/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf '%s\n' '{"at":1760000000,"input_tokens":"25000000"}' > "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev spend check failed: ledger is malformed' "a malformed local record was silently omitted"
  assert_not_contains "$(cat "$out")" 'Jev spend alert:' "a malformed local record produced a spend total"
  pass "malformed local records fail closed instead of undercounting spend"
}

test_models_response_requires_the_full_listing_schema() {
  local home out fixture
  home=$(make_home malformed-models)
  out="$TMP_ROOT/malformed-models/out"
  for fixture in \
    '{"debug":{"name":"jev-latest","release_date":7}}' \
    '{"models":[{"name":"jev-latest","description":"one","release_date":"2026-09-10"},{"name":"jev-latest","description":"two","release_date":"2026-10-01"}]}' \
    '{"models":[{"name":"jev-latest","description":"alias","release_date":7}]}' \
    '{"models":[{"name":"jev-latest","description":"alias","release_date":"2026-09-10"},{"name":"jev-1.13.0","release_date":"2026-09-10"}]}'; do
    printf '%s\n' "$fixture" > "$MODELS"
    run_check "$home" "$out"
    assert_contains "$(cat "$out")" 'Jev alias check failed: models response is malformed' "a malformed models listing was accepted"
    assert_absent "$home/state/.jev-monitor-alias" "a malformed models listing changed the alias baseline"
  done
  pass "Jev alias checks require one fully typed alias in a valid models listing"
}

test_impossible_release_dates_never_change_alias_state() {
  local home out invalid
  home=$(make_home impossible-dates)
  out="$TMP_ROOT/impossible-dates/out"
  printf '%s\n' '2026-09-10' > "$home/state/.jev-monitor-alias"
  for invalid in 2026-13-99 2026-02-30; do
    write_models "$invalid"
    run_check "$home" "$out"
    assert_contains "$(cat "$out")" 'Jev alias check failed: models response is malformed' "$invalid was accepted as a release date"
    assert_not_contains "$(cat "$out")" 'Jev alias moved:' "$invalid produced a false alias alert"
    assert_equals '2026-09-10' "$(cat "$home/state/.jev-monitor-alias")" "$invalid changed the alias baseline"
  done
  pass "impossible release dates cannot update or alert from alias state"
}

test_future_records_do_not_count_toward_spend() {
  local home out ledger
  home=$(make_home future)
  out="$TMP_ROOT/future/out"
  ledger="$home/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf '%s\n' '{"at":1760000001,"task":"future","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":250000000,"x-typesafe-request-id":"req_future"}' > "$ledger"
  run_check "$home" "$out"
  assert_not_contains "$(cat "$out")" 'Jev spend alert:' "future-dated usage counted toward a spend window"
  pass "future-dated local records are excluded from daily and monthly spend"
}

test_local_homes_keep_separate_resolver_ledgers() {
  local root home out ledger
  root=$(make_home parent-home)
  home=$(make_home local-child)
  out="$TMP_ROOT/local-child/out"
  ledger="$root/state/jev-usage.jsonl"
  write_models 2026-09-10
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$home/.fm-secondmate-parent"
  printf '%s\n' '{"at":1760000000,"task":"primary","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_primary"}' > "$ledger"
  run_check "$home" "$out"
  assert_not_contains "$(cat "$out")" 'Jev spend alert:' "a local child counted its parent's resolver ledger"

  ledger="$home/state/jev-usage.jsonl"
  printf '%s\n' '{"at":1760000000,"task":"child","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_child"}' > "$ledger"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'Jev spend alert: per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "a local child did not count its own resolver ledger"
  pass "local homes keep separate resolver ledgers"
}

test_daily_threshold_does_not_cross_utc_midnight() {
  local home out ledger state
  home=$(make_home daily-midnight)
  out="$TMP_ROOT/daily-midnight/out"
  ledger="$home/state/jev-usage.jsonl"
  state="$home/state/.jev-monitor-spend"
  write_models 2026-09-10

  printf '%s\n' '{"at":1767225540,"task":"december-close","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":25000000,"x-typesafe-request-id":"req_december_close"}' > "$ledger"
  run_check "$home" "$out" 1767225540
  assert_contains "$(cat "$out")" 'per-home resolver ledger UTC calendar day 1.05 USD reaches the 1 USD daily threshold' "the 23:59 UTC call did not alert on its own day"
  assert_equals '2025-12-31' "$(jq -r '.daily.period' "$state")" "the first daily alert used the wrong UTC date"

  run_check "$home" "$out" 1767225660
  [ ! -s "$out" ] || fail "the prior-day call alerted again after UTC midnight: $(cat "$out")"
  assert_equals '2026-01-01' "$(jq -r '.daily.period' "$state")" "the daily state did not advance at UTC midnight"
  assert_equals 'false' "$(jq -r '.daily.alert' "$state")" "the prior-day call counted in the new UTC day"
  pass "daily spend is counted and deduplicated within one UTC calendar day"
}

test_threshold_state_is_period_aware() {
  local home out ledger state
  home=$(make_home periods)
  out="$TMP_ROOT/periods/out"
  ledger="$home/state/jev-usage.jsonl"
  state="$home/state/.jev-monitor-spend"
  write_models 2026-09-10

  printf '%s\n' '{"at":1764547200,"task":"december","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":240000000,"x-typesafe-request-id":"req_december"}' > "$ledger"
  run_check "$home" "$out" 1767139200
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.08 USD reaches the 10 USD local threshold' "December did not raise its monthly alert"
  assert_equals '2025-12' "$(jq -r '.monthly.period' "$state")" "December monthly state omitted its period"
  assert_equals 'false' "$(jq -r '.daily.alert' "$state")" "old December usage incorrectly raised the daily flag"

  printf '%s\n' '{"at":1767225600,"task":"january","status":"clear","rule":"rule_1","confidence":0.9,"model":"jev-1.13.0","input_tokens":240000000,"x-typesafe-request-id":"req_january"}' > "$ledger"
  run_check "$home" "$out" 1769817600
  assert_contains "$(cat "$out")" 'per-home resolver ledger month-to-date 10.08 USD reaches the 10 USD local threshold' "January reused December's monthly dedupe state"
  assert_equals '2026-01' "$(jq -r '.monthly.period' "$state")" "January monthly state omitted its period"
  assert_equals '2026-01-31' "$(jq -r '.daily.period' "$state")" "January daily state omitted its period"
  pass "monthly and daily alert state carries independent UTC periods"
}

test_absent_key_never_calls_the_models_endpoint() {
  local home out status
  home="$TMP_ROOT/off/home"
  mkdir -p "$home/state"
  out="$TMP_ROOT/off/out"
  : > "$CALLS"
  status=0
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_CALLS="$CALLS" FAKE_CURL_MODELS="$MODELS" FM_HOME="$home" "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "absent-key check exit"
  [ ! -s "$out" ] || fail "absent-key check wrote output: $(cat "$out")"
  [ ! -s "$CALLS" ] || fail "absent-key check called the TypeSafe fixture"
  pass "Jev monitor is inert without a key"
}

test_arm_registers_a_watcher_shim_without_running_the_check() {
  local home status
  home=$(make_home arm)
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/jev-monitor.check.sh" "arm did not write the watcher shim"
  assert_present "$home/state/jev-monitor.check-trust" "arm did not bind the watcher shim"
  [ "$(stat -c %a "$home/state/jev-monitor.check.sh" 2>/dev/null || stat -f %Lp "$home/state/jev-monitor.check.sh")" = 700 ] \
    || fail "the watcher shim has the wrong mode"
  pass "Jev monitor arms through the registered custom-check contract"
}

test_disarm_refuses_a_symlinked_state_directory() {
  local home target link out status
  home=$(make_home disarm-symlink)
  target="$TMP_ROOT/disarm-symlink/target"
  link="$TMP_ROOT/disarm-symlink/state-link"
  out="$TMP_ROOT/disarm-symlink/out"
  mkdir -p "$target"
  printf '%s\n' '2026-09-10' > "$target/.jev-monitor-alias"
  printf '%s\n' '{"monthly":{"period":"2026-09","alert":false},"daily":{"period":"2026-09-23","alert":false}}' > "$target/.jev-monitor-spend"
  ln -s "$target" "$link"

  status=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$link" "$CHECK" disarm >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "symlinked-state disarm exit"
  assert_contains "$(cat "$out")" 'refusing to disarm with unavailable state directory' "disarm did not report the unsafe state directory"
  assert_equals '2026-09-10' "$(cat "$target/.jev-monitor-alias")" "disarm followed the state symlink and removed alias state"
  assert_present "$target/.jev-monitor-spend" "disarm followed the state symlink and removed spend state"
  pass "Jev monitor disarm refuses symlinked state before cleanup"
}

test_alias_move_records_baseline_then_alerts_once
test_spend_thresholds_use_the_per_home_resolver_ledger
test_malformed_local_record_fails_closed
test_models_response_requires_the_full_listing_schema
test_impossible_release_dates_never_change_alias_state
test_future_records_do_not_count_toward_spend
test_local_homes_keep_separate_resolver_ledgers
test_daily_threshold_does_not_cross_utc_midnight
test_threshold_state_is_period_aware
test_absent_key_never_calls_the_models_endpoint
test_arm_registers_a_watcher_shim_without_running_the_check
test_disarm_refuses_a_symlinked_state_directory

printf '# all fm-jev-check tests passed\n'
