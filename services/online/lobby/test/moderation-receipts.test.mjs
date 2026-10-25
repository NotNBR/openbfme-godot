import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Lobby, configFromEnv, route } from '../src/lobby.mjs';
import { fileStore, nodeEnv } from '../src/server.mjs';
import { LobbyObject } from '../src/worker.mjs';
import { identityStorage } from './identity-storage.mjs';

const MOD_KEY = 'b2'.repeat(32);
const ENV = {
  TICKET_KEYS: `1:${'01'.repeat(32)}\n`,
  SESSION_KEY: 'c3'.repeat(32),
  ADMIN_KEY: 'a1'.repeat(32),
  MOD_KEY,
  RELAYS: 'lab=192.0.2.10:7350',
};
const PROFILE = '9'.repeat(32);
const SETUP = {
  map: 'synthetic.map',
  startingCash: 1500,
  slots: [
    { state: 'player', faction: 0, color: 0, startPos: 0, team: 0 },
    { state: 'open' },
  ],
};
const encoder = new TextEncoder();
let commandNumber = 0;

function makeFileLobby(dir, store = fileStore(dir)) {
  const env = nodeEnv(store);
  env.now = () => 1_700_000_000_000;
  const lobby = new Lobby(env, configFromEnv(ENV));
  lobby.load(store.loadGames(), store.loadMeta(), store.loadEnforcement(), store.loadSightings());
  return { store, lobby };
}

async function call(lobby, method, path, { body, token, raw, time = Math.floor(lobby.env.now() / 1000) } = {}) {
  const url = new URL(path, 'http://lobby');
  const bytes = raw ?? (body === undefined ? new Uint8Array() : encoder.encode(JSON.stringify(body)));
  const headers = token ? { authorization: `Bearer ${token}` } : {};
  if (path.startsWith('/v1/admin/mod/')) {
    const message = encoder.encode(`${method} ${url.pathname}?${url.searchParams.toString()}\n${time}\n`);
    const signed = Buffer.concat([Buffer.from(message), Buffer.from(bytes)]);
    headers['x-openbfme-admin'] = `${time}.${createHmac('sha256', Buffer.from(MOD_KEY, 'hex')).update(signed).digest('hex')}`;
  }
  let out = await route(lobby, {
    method,
    path: url.pathname,
    query: url.searchParams,
    headers,
    ip: '198.51.100.7',
    bytes: async () => bytes,
  });
  if (out.deferred) out = await out.deferred;
  return { status: out.status, headers: out.headers, body: JSON.parse(out.body) };
}

async function guest(lobby, name, install) {
  const out = await call(lobby, 'POST', '/v1/auth/guest', {
    body: { v: 1, name, install, client: { platform: 'linux', version: 'test' } },
  });
  assert.equal(out.status, 200, JSON.stringify(out.body));
  return out.body;
}

async function pair(lobby, hostInstall, targetInstall) {
  const host = await guest(lobby, 'Host', hostInstall);
  const target = await guest(lobby, 'Target', targetInstall);
  const created = await call(lobby, 'POST', '/v1/games', {
    token: host.token,
    body: { name: 'Room', profile: PROFILE, setup: SETUP },
  });
  assert.equal(created.status, 200, JSON.stringify(created.body));
  const id = created.body.id;
  assert.equal((await call(lobby, 'POST', `/v1/games/${id}/join`, {
    token: target.token, body: { profile: PROFILE },
  })).status, 200);
  return { host, target, id };
}

async function kickCommand(lobby, id, commandId = `receipt-command-${++commandNumber}`) {
  const snapshot = await call(lobby, 'GET', '/v1/admin/mod/games');
  assert.equal(snapshot.status, 200);
  const game = snapshot.body.games.find((entry) => entry.id === id);
  return {
    v: 1,
    command_id: commandId,
    expected_seq: game.seq,
    slot: 1,
    expected_account: game.slots[1].account,
    expected_install: game.slots[1].install,
    reason: 'remove target',
  };
}

async function closeCommand(lobby, id, commandId = `receipt-command-${++commandNumber}`) {
  const snapshot = await call(lobby, 'GET', '/v1/admin/mod/games');
  const game = snapshot.body.games.find((entry) => entry.id === id);
  return { v: 1, command_id: commandId, expected_seq: game.seq, reason: 'close room' };
}

async function makeWorker(storage) {
  const state = { storage, blockConcurrencyWhile(fn) { this.initialization = fn(); return this.initialization; } };
  const object = new LobbyObject(state, { ...ENV, LOG_STORE: '' });
  await object.readyPromise;
  assert.equal(object.ready, true);
  return object;
}

test('Node file receipts replay the original kick after restart without kicking a new slot occupant', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lobby-mod-receipt-'));
  try {
    let { store, lobby } = makeFileLobby(dir);
    const { id } = await pair(lobby, '1'.repeat(32), '2'.repeat(32));
    const command = await kickCommand(lobby, id);
    const time = Math.floor(lobby.env.now() / 1000);
    const first = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command, time });
    assert.equal(first.status, 200);
    assert.deepEqual(first.body, { v: 1, id, slot: 1, kicked: true, effect: 'removed_from_room' });
    const replacement = await guest(lobby, 'Replacement', '3'.repeat(32));
    assert.equal((await call(lobby, 'POST', `/v1/games/${id}/join`, {
      token: replacement.token, body: { profile: PROFILE },
    })).status, 200);
    ({ store, lobby } = makeFileLobby(dir));
    const replay = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command, time });
    assert.deepEqual(replay.body, first.body);
    assert.equal(replay.status, 200);
    assert.equal(lobby.games.get(id).slots[1].account, (await lobby.account(`Bearer ${replacement.token}`)).id);
    assert.equal(lobby.games.get(id).adminKicks.length, 1);

    const close = await closeCommand(lobby, id);
    const closed = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/close`, { body: close, time });
    assert.equal(closed.status, 200);
    assert.deepEqual(closed.body, { v: 1, id, closed: true });
    assert.equal(lobby.games.has(id), false);
    ({ lobby } = makeFileLobby(dir));
    const closeReplay = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/close`, { body: close, time });
    assert.equal(closeReplay.status, 200);
    assert.deepEqual(closeReplay.body, closed.body);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('Durable Object SQLite receipts survive restart and concurrent duplicate kicks apply once', async () => {
  const storage = identityStorage();
  try {
    let object = await makeWorker(storage);
    let { lobby } = object;
    const { id } = await pair(lobby, '4'.repeat(32), '5'.repeat(32));
    const command = await kickCommand(lobby, id);
    const time = Math.floor(lobby.env.now() / 1000);
    const path = `/v1/admin/mod/games/${id}/kick`;
    const [one, two] = await Promise.all([
      call(lobby, 'POST', path, { body: command, time }),
      call(lobby, 'POST', path, { body: command, time }),
    ]);
    const successful = [one, two].filter((result) => result.status === 200);
    const pending = [one, two].filter((result) => result.status === 409 && result.body.error === 'command_pending');
    assert.ok(successful.length >= 1);
    assert.equal(successful.length + pending.length, 2);
    const original = successful[0];
    const replacement = await guest(lobby, 'Second', '6'.repeat(32));
    assert.equal((await call(lobby, 'POST', `/v1/games/${id}/join`, {
      token: replacement.token, body: { profile: PROFILE },
    })).status, 200);
    object = await makeWorker(storage);
    lobby = object.lobby;
    const replay = await call(lobby, 'POST', path, { body: command, time });
    assert.equal(replay.status, 200);
    assert.deepEqual(replay.body, original.body);
    assert.equal(lobby.games.get(id).slots[1].account, (await lobby.account(`Bearer ${replacement.token}`)).id);
    assert.equal(lobby.games.get(id).adminKicks.length, 1);
  } finally { storage.db.close(); }
});

test('stale bindings, legacy bodies, and command reuse fail without game mutation', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lobby-mod-stale-'));
  try {
    const { lobby } = makeFileLobby(dir);
    const { id } = await pair(lobby, '7'.repeat(32), '8'.repeat(32));
    const before = lobby.games.get(id).seq;
    const base = await kickCommand(lobby, id);
    for (const [field, value, error] of [
      ['expected_account', 'different-account', 'stale_target'],
      ['expected_install', null, 'stale_target'],
      ['expected_seq', base.expected_seq - 1, 'stale_game'],
    ]) {
      const body = { ...base, command_id: `stale-command-${++commandNumber}`, [field]: value };
      const response = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body });
      assert.equal(response.status, 409);
      assert.equal(response.body.error, error);
      assert.equal(lobby.games.get(id).seq, before);
    }
    const stale = { ...base, command_id: `bound-command-${++commandNumber}`, expected_account: 'different-account' };
    const staleResult = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: stale });
    assert.equal(staleResult.body.error, 'stale_target');
    const rebound = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, {
      body: { ...stale, expected_account: lobby.games.get(id).slots[1].account },
    });
    assert.equal(rebound.status, 409);
    assert.equal(rebound.body.error, 'command_conflict');
    const close = await closeCommand(lobby, id, stale.command_id);
    const wrongPath = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/close`, { body: close });
    assert.equal(wrongPath.status, 409);
    assert.equal(wrongPath.body.error, 'command_conflict');
    const legacy = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, {
      body: { v: 1, slot: 1, reason: 'legacy request' },
    });
    assert.equal(legacy.status, 400);
    assert.equal(lobby.games.get(id).seq, before);

    const unsafe = { ...base, command_id: `unsafe-command-${++commandNumber}`, expected_seq: 0 };
    lobby.games.get(id).seq = Number.MAX_SAFE_INTEGER + 1;
    const unavailableRevision = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: unsafe });
    assert.equal(unavailableRevision.status, 503);
    assert.equal(unavailableRevision.body.error, 'game_unavailable');
    lobby.games.get(id).seq = before;

    const byteCommand = { ...base, command_id: `byte-command-${++commandNumber}`, expected_account: 'different-account' };
    const exactRaw = encoder.encode(JSON.stringify(byteCommand));
    const rawFirst = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { raw: exactRaw });
    assert.equal(rawFirst.body.error, 'stale_target');
    const whitespaceReplay = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, {
      raw: encoder.encode(JSON.stringify(byteCommand, null, 2)),
    });
    assert.equal(whitespaceReplay.status, 409);
    assert.equal(whitespaceReplay.body.error, 'command_conflict');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing, corrupt, or interrupted receipts fail closed across Node restart', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lobby-mod-failclosed-'));
  try {
    let { store, lobby } = makeFileLobby(dir);
    const { id } = await pair(lobby, 'a'.repeat(32), 'b'.repeat(32));
    const command = await kickCommand(lobby, id);
    const initialSeq = lobby.games.get(id).seq;
    const claim = store.claimModerationReceipt;
    store.claimModerationReceipt = undefined;
    const missing = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command });
    assert.equal(missing.status, 503);
    assert.equal(missing.body.error, 'command_store_unavailable');
    assert.equal(lobby.games.get(id).seq, initialSeq);
    store.claimModerationReceipt = claim;

    const complete = store.completeModerationReceipt;
    store.completeModerationReceipt = () => { throw new Error('injected receipt completion failure'); };
    const failed = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command });
    assert.equal(failed.status, 503);
    const afterEffect = lobby.games.get(id).seq;
    assert.ok(afterEffect > initialSeq);
    store.completeModerationReceipt = complete;
    ({ store, lobby } = makeFileLobby(dir));
    const pending = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command });
    assert.equal(pending.status, 409);
    assert.equal(pending.body.error, 'command_pending');
    assert.equal(lobby.games.get(id).seq, afterEffect);

    const files = readdirSync(join(dir, 'moderation-receipts'));
    writeFileSync(join(dir, 'moderation-receipts', files[0]), '{');
    ({ lobby } = makeFileLobby(dir));
    const corrupt = await call(lobby, 'POST', `/v1/admin/mod/games/${id}/kick`, { body: command });
    assert.equal(corrupt.status, 503);
    assert.equal(corrupt.body.error, 'command_store_unavailable');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
