# Durable identity capacity: 100,000 installs

The offline capacity test is `test/identity-store.test.mjs`, test name
`100k identity capacity: file-backed storage, bounded isolate results and retained heap`.
Run from the repository root with Node supporting `node:sqlite`:

```sh
node --expose-gc --test --test-name-pattern='100k identity capacity' \
  services/online/lobby/test/identity-store.test.mjs
```

## Captured local result

PASS on the Linux x86-64 CI host. The fixture uses a temporary, **file-backed**
SQLite database, not a JavaScript Map simulating remote storage. It streams
100-row transactions, never constructs a 100k-record input array, and deletes
the synthetic database at the end. No game files, network, or cloud API is used.

| Measurement | Observed |
|---|---:|
| Enforcement records | 100,000 |
| Sighting records | 100,000 |
| Device-block index rows | 500,000 |
| Sighting-device index rows | 500,000 |
| Nickname index rows | 1,000,000 |
| Largest SQL result materialized in JavaScript | 100 rows |
| Retained JS heap increase after explicit GC | 124,976 bytes |
| Process RSS at completion | 90,554,368 bytes |
| Database size | 809,824,256 bytes |
| Fixture creation time | 24,531 ms |
| 1,000 install + 1,000 device lookups combined | 45.8 ms |
| Entire capacity case | 25,259 ms |

Each install has ten historical nicknames and five devices, the maximum
cardinalities. Strings are synthetic and **not** maximum-length payloads.
One device is deliberately shared by **all 100k installs**. Assertions cover
that device's block lookup, absent installs, end-of-table enforcement paging,
nickname-prefix search, bounded linked-player results, and a fresh store
instance over the persisted database. Other focused tests cover atomic rollback,
replacing/removing indexes, expiration, and resumable legacy migration.

The heap assertion permits less than 16 MiB of retained identity heap; row
materialization is asserted at no more than 101 rows. GC-based measurement is
enabled only with `--expose-gc`; the printed `gcEnabled` flag makes this explicit.
The ordinary test invocation still checks row bounds and functionality.

## What this proves, and what it does not

Identity records and indexes stay on disk rather than being loaded into the
Durable Object's identity Maps. The measured retained JS heap does not scale
with the fixture count. Exact install and device queries use database indexes;
the application receives bounded results even for a heavily shared device.
Search and linked-player aggregation can still examine many rows **inside
SQLite**; bounded result size is not a claim of constant query cost.

These are local Node/SQLite measurements, **not a deployed Workers memory,
CPU, billing, or latency benchmark**. RSS includes the local SQLite runtime and
is not a measurement of Cloudflare isolate memory. Active games, relay logs,
request bodies, and other pre-existing lobby state have separate budgets.

At 100k installs this fixture alone contains 2.2 million table rows, before
secondary indexes. It does not fit a 100,000-row-write/day free allowance in
one day. Every sign-in replaces that install's bounded sighting/index rows;
moderation updates replace its device-block index rows. Operators must budget
for index maintenance, migration, sign-in traffic, search reads and storage,
and validate current provider limits before deployment. No quota or plan change
is made by this work. Capacity is not a claim that the free plan can sustain
100k daily active installs.
