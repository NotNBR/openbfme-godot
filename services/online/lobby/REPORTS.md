# Player reports

The lobby report API is intentionally separate from game, relay, sighting, and
enforcement records:

- `POST /v1/reports` (`submitPlayerReport`) accepts a participating player's
  report while a game is active or during the 24-hour window after the
  authoritative game end.
- `GET /v1/admin/mod/reports` (`readLobbyPlayerReports`) lists reports newest
  first; `GET /v1/admin/mod/reports/{id}` reads one report. These routes use
  `MOD_KEY` and the existing signed-request canonical form, including the
  literal trailing `?` before the query string.

Report sources are retained for 90 days. Idempotency receipts and duplicate
guards are retained for 24 hours. The authoritative end is observed by the
relay completion, room closure, or lobby idle expiry; a client cannot declare
its own end. Roster history is retained independently for the reporting window.

Attempts are limited to five per install in a rolling hour and 20 in a rolling
day, with a global admission limit of 1,000 per UTC day. Authenticated invalid
report attempts consume the install quota; a replay of the same key and
canonical body does not. Oversized bodies are rejected without buffering and
charged after bearer/install authentication. Invalid authentication, transport
timeouts, and overload rejections do not create report attempts.

The file adapter stores reports in a standard-library-only append-only journal.
Transactions are serialized and fsynced before activation. Startup rejects
malformed or incomplete journal records. Compaction writes and fsyncs an atomic
snapshot no more than once per day, so deleted report reasons eventually leave
the journal file. Cleanup is bounded and throttled; logical expiry is enforced
even before physical cleanup.

Set `MOD_KEY` to a distinct secret from `ADMIN_KEY`; `REQUIRE_INSTALL=1`
rejects legacy guest sessions without install identity. For local development,
create an obvious synthetic key with a command such as
`printf '%064d\n' 1`; do not use generated or production secrets in source.

## Private moderator game commands

The signed `MOD_KEY` projection at `GET /v1/admin/mod/games` includes each
game's `seq` and each slot's `account` (`null` for an empty slot). These fields
are private and do not change the public console API.

Private kick requests use `POST /v1/admin/mod/games/{id}/kick` with exactly:

```json
{"v":1,"command_id":"moderator-command-01","expected_seq":12,"slot":1,"expected_account":"guest:0123456789abcdef","expected_install":"0123456789abcdef0123456789abcdef","reason":"moderation reason"}
```

For an account with no install identity, `expected_install` is exactly `null`;
it is never a wildcard. Private close requests use
`POST /v1/admin/mod/games/{id}/close` with exactly
`{"v":1,"command_id":"moderator-command-02","expected_seq":12,"reason":"moderation reason"}`.
Command IDs are 8–64 URL-safe characters. Both operations compare the captured
revision and exact selected target before mutation. Fresh mismatches return
`409 stale_game` or `409 stale_target`.

Each command ID has a durable receipt independent of game lifetime. The
receipt fingerprint covers the operation, HTTP method, game path, query, and
exact raw body bytes. Whitespace changes therefore conflict. Signature
headers and signing timestamps are excluded, so a byte-identical request can
be re-signed after `MOD_KEY` rotation. Reusing an ID for another fingerprint
returns `409 command_conflict`; replaying a completed command returns its
original status and response even after the game changes or is deleted. A
matching pending/interrupted command returns `409 command_pending` and is
never automatically re-executed.

The Node file store writes write-ahead claims and completions durably; the
Durable Object stores receipts in SQLite. Receipts do not expire or have
automatic cleanup: disk usage grows with every distinct moderator command.
If a crash or storage error leaves a pending receipt, an operator must
reconcile the game and report effects before any manual cleanup. Receipt
cleanup is not an API operation and must not happen automatically. Cross-store
effects are not one atomic transaction, so a pending receipt may require
reconciliation of a partially applied kick or close.

The WP-B command adapter must capture a signed private game projection when it
first prepares a POST, then persist the revision- and target-bound private
request before its first send. It must reuse that exact body for retries and
never rebind it after a `409`. An earlier UI selection is not bound by the
frozen public `{v,slot,reason}` request shape, so it is not protected from
stale-selection retries.

## Privacy migrations and backups

New game writes do not store the originating IP. Node startup sanitizes legacy
game files before loading them; Durable Object startup paginates and sanitizes
all legacy game records before the lobby becomes ready. A failed migration
keeps the Worker unready rather than serving partially migrated data.

Legacy platforms outside `windows`, `linux`, and `macos` become unknown
(`null`). The bounded KV and SQLite migrations perform this normalization even
when the older identity migration has already completed.

Previously exported backups may still contain legacy game IPs or unsupported
platform values. This code does not rewrite backup copies; operators must
apply their retention and purge policy to existing exports. No external backup
copies were changed by this update. The Node `LOBBY_DATA` directory must be
owned by one server process at a time: startup discards recognized abandoned
game-write temporary files rather than promoting them.
