# UTF-8 truncation live evidence

Target: `3f1e42db133c99880ecef5ab1a2f2be56c1f65b7`  
Baseline: `ee6a2b241c1b3e2727c7c1fca2aae6f93deda3c6`  
Locale: `LC_ALL=C`

The baseline and target executables were driven with multibyte `é` placed exactly at each retained character boundary. The inbox input also contained a tab, proving the existing control-character fold still changes it to one space. “Valid UTF-8” below comes from decoding the emitted CLI or durable-record bytes with Python's strict UTF-8 decoder.

| Executed product path | Baseline valid UTF-8 | Target valid UTF-8 | Target observable cap | Baseline bytes at boundary | Target bytes at boundary |
|---|---:|---:|---|---|---|
| Inbox wake summary | no | yes | 100-character summary; input tab folded to a space | `6262626262626262c3` | `6262626262626262c3a9` |
| Home-summary producer diagnostic | no | yes | 500-character excerpt | `7373737373737373c3` | `7373737373737373c3a9` |
| Parent-channel note cleaner | no | yes | 1200-character note | `7070707070707070c3` | `7070707070707070c3a9` |
| Watcher delivery ledger reason | no | yes | 4096-character reason | `7777777777777777c3` | `7777777777777777c3a9` |

The baseline boundary bytes end with the leading byte `c3` of `é`; the target retains the complete `c3a9` character and excludes the following literal `tail`.

## Eleven-script audit

| Script | Verdict | Reason |
|---|---|---|
| `bin/fm-bootstrap.sh` | Fix warranted and present | A free-text durable home-summary failure is shown to the captain; the existing 200-character cap now keeps complete UTF-8 characters. |
| `bin/fm-home-summary-refresh.sh` | Fix warranted and present | Producer stderr is copied into a human diagnostic and best-effort failure log; the existing 500-character cap now keeps complete UTF-8 characters. |
| `bin/fm-inactive-reconcile.sh` | Fix warranted and present | Child terminal prose is copied into durable parent delivery and captain-facing output; the existing 1200-character cap now keeps complete UTF-8 characters. |
| `bin/fm-inbox.sh` | Fix warranted and present | Captain note wakes, backlog rows, and worker status are durable or human-facing free text; all existing 100/150/100-character caps now keep complete UTF-8 characters. |
| `bin/fm-parent-channel-lib.sh` | Fix warranted and present | Captain-facing secondmate notes are persisted to the parent channel; the existing 1200-character cap now keeps complete UTF-8 characters. |
| `bin/fm-push-transition-lib.sh` | Fix warranted and present | Watch delivery reasons are persisted in `.watch-deliveries.log`; the existing 4096-character cap now keeps complete UTF-8 characters. |
| `bin/fm-pending-reply-lib.sh` | No fix warranted | The value is filtered to lowercase ASCII hex before the 16-character cap, so non-ASCII cannot reach `cut`. |
| `bin/fm-secondmate-reconcile.sh` | No fix warranted | The capped value is a SHA-256 digest consisting only of ASCII hex. |
| `bin/fm-spawn.sh` | No fix warranted | The capped value is Git's six-byte ASCII numeric mode field and is compared with `160000`. |
| `bin/fm-tool-update-check.sh` | No fix warranted | The capped value is a Git object ID consisting only of ASCII hex. |
| `bin/fm-watch-arm.sh` | No fix warranted | Lifecycle fields are generated ASCII enums/numbers; PID identity is hex on `/proc` systems and `fm_pid_identity` forces `LC_ALL=C` for the Darwin `ps` fallback, which renders non-ASCII command-path bytes as ASCII escape notation before this diagnostic ledger cap. |

## Focused executable checks

- `bash tests/fm-inbox.test.sh`
- `bash tests/fm-home-summary-refresh.test.sh`
- `bash tests/fm-inactive-reconcile.test.sh`
- `bash tests/fm-pending-reply.test.sh`
- `bash tests/fm-watch-arm.test.sh`

All five completed successfully after correcting the home-summary regression fixture so its UTF-8 boundary text was the last failure record, matching the product's established “last failure” contract.

## Direct target CLI check

A real isolated `bin/fm-bootstrap.sh` detect-only run under `LC_ALL=C` read two durable failure records and emitted the 200-character last-failure excerpt as strict UTF-8. Its excerpt ended with the complete boundary character `é`, and the following literal `tail` was absent.

A real isolated `bin/fm-watch.sh` run under `LC_ALL=C` observed `state/café.status`, emitted `signal: …/café.status`, and persisted the same valid UTF-8 reason to `.watch-deliveries.log`.

A real isolated `bin/fm-inactive-reconcile.sh report child` run under `LC_ALL=C` delivered a 1200-character child note ending in `é` to the parent’s durable `mate.status`; strict UTF-8 decoding succeeded and `tail` was absent.

A real isolated `bin/fm-inbox.sh` run under `LC_ALL=C` persisted a captain-note wake ending in `é`; its real `status` command displayed backlog and worker previews ending in `é`. All three strict UTF-8 decodes succeeded and excluded `tail` beyond the existing caps.
