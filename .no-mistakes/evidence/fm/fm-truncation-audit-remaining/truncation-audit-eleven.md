# UTF-8 truncation audit: all eleven scripts

Audit range: ee6a2b241c1b3e2727c7c1fca2aae6f93deda3c6..0288919b86596f0ee2a89e69aa7a75d030ae362a

| Script | Verdict | Concrete reason |
|---|---|---|
| bin/fm-bootstrap.sh | FIXED | The latest home-summary failure comes from a durable diagnostic log and is printed to the captain at session start. Producer diagnostics may contain accented or non-Latin text, so the existing 200-character cap now truncates decoded UTF-8 characters. |
| bin/fm-home-summary-refresh.sh | FIXED | The last producer stderr line is returned to a direct caller and may later enter the durable failure log. Arbitrary producer text can be non-ASCII, so the existing 500-character cap now truncates decoded UTF-8 after retaining the existing tab, CR, and LF folding. |
| bin/fm-inactive-reconcile.sh | FIXED | A child’s terminal done or failed note is copied into the durable parent channel. That note can contain human-authored non-ASCII text, so the existing 1200-character cap now truncates decoded UTF-8 after retaining control folding. |
| bin/fm-inbox.sh | FIXED | Captain notes, backlog rows, and worker status lines are shown in wake and status previews. These human-authored fields concretely carry accented and non-Latin text, so the existing 100/150/100-character preview caps now truncate decoded UTF-8 while preserving existing newline/tab folding. |
| bin/fm-parent-channel-lib.sh | FIXED | Parent-channel notes are durable, captain-facing free text. The existing 1200-character cap now truncates decoded UTF-8 after retaining tab, CR, and LF folding. |
| bin/fm-push-transition-lib.sh | FIXED | A watcher’s delivery reason is written to .watch-deliveries.log and can be replayed to the user. Wake reasons can contain human text, so the existing 4096-character cap now truncates decoded UTF-8 after retaining control folding. |
| bin/fm-pending-reply-lib.sh | NOT FIXED — SAFE | Before the 16-character cut, the candidate correlation id is lowercased and filtered to a-f0-9. Only single-byte ASCII hexadecimal can reach the cut, so it cannot split UTF-8 or corrupt the durable id consumed later. |
| bin/fm-secondmate-reconcile.sh | NOT FIXED — SAFE | delivery_id truncates the hexadecimal digest emitted by SHA-256 tooling. Its input at the cut is single-byte ASCII hex, so the 16-character id cannot contain or split a multibyte character. |
| bin/fm-spawn.sh | NOT FIXED — SAFE | The cut reads the first six characters of Git’s index mode field from git ls-files --stage and compares it with ASCII 160000. That machine field contains ASCII digits only and is neither free text nor human-authored output. |
| bin/fm-tool-update-check.sh | NOT FIXED — SAFE | The cut abbreviates the first field returned by git ls-remote, a Git object id represented as ASCII hexadecimal. The 12-character label cannot contain or split UTF-8 before it appears in the human update message. |
| bin/fm-watch-arm.sh | NOT FIXED — SAFE | cycle_clean_field receives numeric pids/times/codes, fixed ASCII enum labels, successor labels, and process identity. Linux process identity hex-encodes the command line; the Darwin fallback deliberately runs ps under LC_ALL=C, which renders non-ASCII command bytes as ASCII M- escapes. Therefore only ASCII reaches this diagnostic lifecycle ledger’s cut. |

## PR body requirement

Copy this complete table into the pull request body when the push phase opens the PR. After creation, read the PR body back with the forge API and verify that all eleven script names, each verdict, and each reason are present. This test phase cannot complete that readback because no pull request exists yet and the phase boundary forbids opening one.
