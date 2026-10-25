# Indexed identity and private enforcement checks

Durable Object identity state uses the SQLite-backed `SqliteIdentityStore`,
independently of relay-log storage. Existing `enforcement:` and `sighting:`
KV rows are copied in bounded 100-row pages. Startup processes at most three
pages and later alarms process at most ten pages per wake; requests fail closed
with `503 identity_migrating` until both prefixes are complete. Provision
SQLite-backed Durable Objects before moving an old KV-only namespace. Legacy
KV is retained as a rollback source but stops receiving writes after migration;
rollback therefore requires exporting and backfilling current indexed state.
Never roll back to stale KV bans.

`POST /v1/internal/enforcement/check` is a read-only private platform seam.
The operator supplies the same independent 32-byte key, encoded as exactly 64
hex characters, in lobby `ENFORCEMENT_CHECK_KEY` and platform
`ENFORCEMENT_CHECK_SECRET_ARN`. It must differ from `ADMIN_KEY` and `MOD_KEY`.
For offline setup, generate a placeholder with
`python3 -c 'import secrets; print(secrets.token_hex(32))'`; transfer the
chosen value through the approved secret channel rather than source control.

The request is signed with `X-OpenBFME-Admin` using the existing formula:

```text
HMAC-SHA256(key, "POST /v1/internal/enforcement/check?\n<unix-seconds>\n" + exact_body_bytes)
```

The literal `?` is required even when the query is empty. The request contains
a random 32-hex nonce and 1–128 unique canonical install IDs. The response
contains direct and opted-in sighting-derived device enforcement, but no raw
device hashes or reasons, and is `Cache-Control: no-store`. Device blocks are
derived from sightings and are opt-in only. Install IDs are not strong user
authentication, and this mechanism does not establish a human identity.

Moderator player details include at most 100 linked players. Results are
ordered deterministically by shared-device count descending, `last_seen`
descending, then install ID ascending.

Example request body:

```json
{"v":1,"nonce":"0123456789abcdef0123456789abcdef","installs":["0123456789abcdef0123456789abcdef"]}
```

Example response body:

```json
{"v":1,"nonce":"0123456789abcdef0123456789abcdef","checked_at":1700000000,"decisions":[{"install":"0123456789abcdef0123456789abcdef","allowed":true,"code":null,"routing":"ranked"}]}
```

Legacy Quick Match tickets without routing remain in their old partition and
are never moved into a routed pool. They cannot be heartbeated across the
routing boundary; searching tickets expire under their existing TTL and remain
cancellable, while matched tickets without participant/routing metadata fail
closed when polled. Legacy tournaments without a stored routing tag cannot be
safely admitted or disclose room codes through the live check. Operators must
explicitly migrate or close those tournaments; the service fails closed rather
than assuming an empty routing.
