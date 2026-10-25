// ONLINECOUNT-1: GET /v1/stats, the player count the menus and the launcher show. node --test services/online/lobby/test
// Counting window, expiring sessions, games, no personal data, the caching interval, malformed requests, and the Worker's cache in front of the object.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { Lobby, route, configFromEnv, PRESENCE_S, STATS_CACHE_S, MAX_PRESENT, GAME_DAYS } from '../src/lobby.mjs';
import { StatsAdmission, STATS_ADMIT_BURST } from '../src/worker.mjs';
import { nodeEnv } from '../src/server.mjs';
import worker, { statsFromCache } from '../src/worker.mjs';

const KEY_HEX = Array.from({ length: 32 }, (_, i) => i.toString(16).padStart(2, '0')).join('');
const PROFILE = '9ecbb999bef4925c679a5570eacd6b99';
const ENV = { TICKET_KEYS: `# test\n1:${KEY_HEX}\n`, SESSION_KEY: 'aa'.repeat(32), UPLOAD_KEY: 'bb'.repeat(32), RELAYS: 'lab=192.0.2.10:7350', PUBLIC_URL: 'http://lobby.test' };
const setup = {
  map: 'maps/map mp evendim/map mp evendim.map',
  startingCash: 1500,
  slots: [{ state: 'player', faction: 0, color: 0, startPos: 0, team: 0 }, { state: 'open' }, { state: 'hard', name: 'Computer', faction: 2, color: 2, startPos: 2, team: 1 }],
};

function fakeEnv() {
  let t = 1_700_000_000_000;
  let r = 0;
  const blobs = new Map();
  const storedAt = new Map();
  const games = new Map();
  const reads = { gameTimes: 0 };
  // LOBBYSTATS-1: the store's write times of the START records and relay logs, as the SQLite store's gameTimes answers them
  const gameTimes = (since) => {
    reads.gameTimes += 1;
    const out = { started: [], finished: [] };
    for (const [k, at] of storedAt) if (at >= since) (k.startsWith('starts/') ? out.started : k.startsWith('logs/') ? out.finished : []).push(at);
    return out;
  };
  const env = nodeEnv({ putBlob: (k, b) => { blobs.set(k, b); storedAt.set(k, t); }, getBlob: (k) => blobs.get(k) ?? null, gameTimes,
    saveGame: (g) => games.set(g.id, JSON.parse(JSON.stringify(g))) });
  env.savedGames = games;
  env.blobs = blobs;
  env.storedAt = storedAt;
  env.reads = reads;
  env.now = () => t;
  env.advance = (s) => { t += s * 1000; };
  env.randomBytes = (n) => Uint8Array.from({ length: n }, () => (r = (r * 1103515245 + 12345) & 0xff));
  return env;
}
async function call(lobby, method, path, { token, body, ip = '198.51.100.1', headers = {} } = {}) {
  const url = new URL(path, 'http://lobby');
  const out = await route(lobby, {
    method, path: url.pathname, query: url.searchParams, ip,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    bytes: async () => (body instanceof Uint8Array ? body : new TextEncoder().encode(body === undefined ? '' : JSON.stringify(body))),
  });
  return { status: out.status, headers: out.headers, body: out.headers['content-type']?.startsWith('application/json') ? JSON.parse(out.body) : out.body };
}
const stats = async (lobby, opts) => call(lobby, 'GET', '/v1/stats', opts);
const guest = async (lobby, name, ip) => (await call(lobby, 'POST', '/v1/auth/guest', { body: { name }, ip })).body;
async function startedGame(lobby, host, guestB) {
  const id = (await call(lobby, 'POST', '/v1/games', { token: host.token, body: { name: 'g', profile: PROFILE, setup } })).body.id;
  await call(lobby, 'POST', `/v1/games/${id}/join`, { token: guestB.token, body: { profile: PROFILE } });
  await call(lobby, 'POST', `/v1/games/${id}/ready`, { token: guestB.token, body: { ready: true } });
  assert.equal((await call(lobby, 'POST', `/v1/games/${id}/start`, { token: host.token })).status, 200);
  return id;
}

test('an empty lobby counts nothing; the answer has exactly the counts and the time, no names, ids or addresses', async () => {
  const lobby = new Lobby(fakeEnv(), configFromEnv(ENV));
  const r = await stats(lobby);
  assert.equal(r.status, 200);
  // 1_700_000_000 s is 2023-11-14 22:13:20 UTC
  const days = ['2023-11-08', '2023-11-09', '2023-11-10', '2023-11-11', '2023-11-12', '2023-11-13', '2023-11-14'].map((day) => ({ day, games: 0 }));
  assert.deepEqual(r.body, { v: 1, players: 0, games_open: 0, games_running: 0, games_started_24h: 0, games_finished_24h: 0, games_started_by_day: days, as_of: 1_700_000_000 });
  const a = await guest(lobby, 'Ann', '203.0.113.7');
  const id = (await call(lobby, 'POST', '/v1/games', { token: a.token, body: { name: 'Secret game name', profile: PROFILE, setup } })).body.id;
  const text = JSON.stringify((await stats(lobby, { token: a.token, ip: '203.0.113.7' })).body);
  assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ['as_of', 'games_finished_24h', 'games_open', 'games_running', 'games_started_24h', 'games_started_by_day', 'players', 'v']);
  for (const leak of ['Ann', 'Secret', a.account.id, a.token, id, '203.0.113.7', 'guest:']) assert.ok(!text.includes(leak), `the answer leaks ${leak}`);
});

test('a player counts for PRESENCE_S seconds after the lobby last saw their token, once however many requests; no token, no count', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const a = await guest(lobby, 'Ann');
  const b = await guest(lobby, 'Bea');
  assert.equal((await stats(lobby)).body.players, 2, 'the sign-ins count');
  env.advance(STATS_CACHE_S);
  // Ann keeps polling (many requests, one player); Bea goes silent
  await stats(lobby, { token: a.token });
  await stats(lobby, { token: a.token });
  env.advance(PRESENCE_S - STATS_CACHE_S - 1);
  assert.equal((await stats(lobby, { token: a.token })).body.players, 2, 'Bea was last seen PRESENCE_S - STATS_CACHE_S + ... ago: still inside');
  env.advance(STATS_CACHE_S);
  const later = await stats(lobby); // an unsigned request does not keep anyone present
  assert.equal(later.body.players, 1, 'Bea is past the window, Ann was seen just now');
  env.advance(PRESENCE_S + 1);
  assert.equal((await stats(lobby)).body.players, 0, 'nobody was seen for longer than the window');
  assert.equal(lobby.present.size, 0, 'expired sessions are forgotten');
  // the boundary: exactly PRESENCE_S still counts, one second later it does not
  await call(lobby, 'GET', '/v1/mine', { token: b.token });
  env.advance(PRESENCE_S);
  assert.equal((await stats(lobby)).body.players, 1);
  env.advance(STATS_CACHE_S);
  assert.equal((await stats(lobby)).body.players, 0);
});

// ---- LOBBYSTATS-1: games per day ----
function relayLogOf(id) {
  const log = new Uint8Array(25);
  log.set(Buffer.from('OBFMERLG'));
  new DataView(log.buffer).setUint32(8, 1, true);
  new DataView(log.buffer).setBigUint64(12, BigInt(`0x${id}`), true);
  return { log, sig: createHmac('sha256', Buffer.from(ENV.UPLOAD_KEY, 'hex')).update(log).digest('hex') };
}
const uploadLogOf = async (lobby, id) => {
  const { log, sig } = relayLogOf(id);
  return (await call(lobby, 'POST', `/v1/relay/logs/${id}`, { body: log, headers: { 'x-openbfme-signature': sig } })).status;
};
const today = (r) => r.games_started_by_day.at(-1).games;

test('LOBBYSTATS-1: a started game counts in the last 24 h and on its UTC day; it counts as finished when its relay log arrives; open games do not count', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const [a, b, c, d] = [await guest(lobby, 'Ann'), await guest(lobby, 'Bea'), await guest(lobby, 'Cy'), await guest(lobby, 'Di')];
  const one = await startedGame(lobby, a, b);
  await startedGame(lobby, c, d);
  await call(lobby, 'POST', '/v1/games', { token: a.token, body: { name: 'open', profile: PROFILE, setup } });
  env.advance(STATS_CACHE_S);
  let r = (await stats(lobby)).body;
  assert.deepEqual([r.games_started_24h, r.games_finished_24h, today(r)], [2, 0, 2]);
  assert.equal(r.games_started_by_day.length, GAME_DAYS);
  assert.equal(r.games_started_by_day.reduce((n, x) => n + x.games, 0), 2);
  assert.equal(await uploadLogOf(lobby, one), 200);
  assert.equal(await uploadLogOf(lobby, one), 200, 'the uploader\'s retry of the same log');
  r = (await stats(lobby)).body;
  assert.deepEqual([r.games_started_24h, r.games_finished_24h], [2, 1], 'one finish, however many uploads of its log');
  for (const leak of [one, 'Ann', a.account.id, '198.51.100.1']) assert.ok(!JSON.stringify(r).includes(leak), `the answer leaks ${leak}`);
});

test('LOBBYSTATS-1: the 24 hours roll, the days are UTC days (oldest first, today last) and a game leaves the list after GAME_DAYS days', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const [a, b] = [await guest(lobby, 'Ann'), await guest(lobby, 'Bea')];
  await startedGame(lobby, a, b); // 2023-11-14 22:13 UTC
  env.advance(2 * 3600); // 00:13 the next day
  let r = (await stats(lobby)).body;
  assert.equal(r.games_started_by_day.at(-1).day, '2023-11-15');
  assert.deepEqual(r.games_started_by_day.slice(-2).map((x) => x.games), [1, 0], 'the game is on the 14th');
  assert.equal(r.games_started_24h, 1);
  env.advance(22 * 3600 + 1); // just past 24 h after the start
  r = (await stats(lobby)).body;
  assert.equal(r.games_started_24h, 0);
  assert.deepEqual(r.games_started_by_day.at(-2), { day: '2023-11-14', games: 1 }, 'still listed on its day');
  env.advance((GAME_DAYS - 1) * 24 * 3600); // the 21st: the 14th is GAME_DAYS days back, out of the list
  r = (await stats(lobby)).body;
  assert.equal(r.games_started_by_day[0].day, '2023-11-15');
  assert.equal(r.games_started_by_day.reduce((n, x) => n + x.games, 0), 0);
});

test('LOBBYSTATS-1: the times are read from the store once (a restarted lobby counts the games it stored before), then kept in memory; the counts write nothing', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const [a, b, c, d] = [await guest(lobby, 'Ann'), await guest(lobby, 'Bea'), await guest(lobby, 'Cy'), await guest(lobby, 'Di')];
  const one = await startedGame(lobby, a, b);
  assert.equal(await uploadLogOf(lobby, one), 200);
  const again = new Lobby(env, configFromEnv(ENV));
  again.load([...env.savedGames.values()]);
  const reads = env.reads.gameTimes;
  let r = (await stats(again)).body;
  assert.deepEqual([r.games_started_24h, r.games_finished_24h, today(r)], [1, 1, 1], 'the restarted lobby read them from the store');
  assert.equal(env.reads.gameTimes, reads + 1);
  const blobs = env.blobs.size;
  const saves = env.savedGames.size;
  for (let i = 0; i < 5; i++) {
    env.advance(STATS_CACHE_S);
    await stats(again);
  }
  await startedGame(again, c, d); // stored by this lobby: counted from memory, not read again
  env.advance(STATS_CACHE_S);
  r = (await stats(again)).body;
  assert.deepEqual([r.games_started_24h, r.games_finished_24h, today(r)], [2, 1, 2]);
  assert.equal(env.reads.gameTimes, reads + 1, 'one read of the store in the lobby\'s lifetime');
  assert.equal(env.blobs.size, blobs + 2, 'only the new game\'s own START record and player list');
  assert.equal(env.savedGames.size, saves + 1, 'only the new game\'s own record');
});

test('LOBBYSTATS-1: a store that cannot list its write times (R2, no log store) answers null, not zero', async () => {
  const env = nodeEnv({ saveGame: () => {} });
  const lobby = new Lobby(env, configFromEnv(ENV));
  const r = (await stats(lobby)).body;
  assert.deepEqual([r.games_started_24h, r.games_finished_24h, r.games_started_by_day], [null, null, null]);
  assert.equal(r.players, 0);
});

test('S-4830: the health check says what "players online" means', async () => {
  const lobby = new Lobby(fakeEnv(), configFromEnv(ENV));
  const h = (await call(lobby, 'GET', '/v1/health')).body;
  assert.match(h.stats, /^\[S-4830\] players online = accounts whose token was seen in the last 150 s plus the humans of started games/);
  assert.equal(h.stats.includes(`${PRESENCE_S} s`), true, 'the stop names the window the code uses');
});

test('a bad or foreign token is rejected instead of falling through to the anonymous answer', async () => {
  const lobby = new Lobby(fakeEnv(), configFromEnv(ENV));
  const other = new Lobby(fakeEnv(), configFromEnv({ ...ENV, SESSION_KEY: 'cc'.repeat(32) }));
  const foreign = await guest(other, 'Mallory');
  for (const authorization of ['Bearer nonsense', 'Bearer a.b', 'Basic abc', '', `Bearer ${foreign.token}`]) {
    const r = await stats(lobby, { headers: { authorization } });
    if (!authorization) continue;
    assert.equal(r.status, 401, authorization);
    assert.equal(r.body.error, 'signed_out', authorization);
  }
});

test('players of a started game count by their slots (humans only, once each) until its relay log arrives; open and running games are counted apart', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const a = await guest(lobby, 'Ann');
  const b = await guest(lobby, 'Bea');
  const c = await guest(lobby, 'Cy');
  const id = await startedGame(lobby, a, b);
  await call(lobby, 'POST', '/v1/games', { token: c.token, body: { name: 'open', profile: PROFILE, setup } });
  env.advance(PRESENCE_S + 60); // nobody is seen any more: only the running game's two humans and Cy's open game
  let r = (await stats(lobby)).body;
  assert.equal(r.games_running, 1);
  assert.equal(r.games_open, 1);
  assert.equal(r.players, 2, 'the AI slot is not a player, Cy has been silent too long, Ann and Bea are in a running game');
  // the same people seen in the lobby again are not counted twice
  await call(lobby, 'GET', '/v1/mine', { token: a.token });
  env.advance(STATS_CACHE_S);
  assert.equal((await stats(lobby)).body.players, 2);
  // the relay's log arrives: the game is over
  const log = new Uint8Array(25);
  log.set(Buffer.from('OBFMERLG'));
  new DataView(log.buffer).setUint32(8, 1, true);
  new DataView(log.buffer).setBigUint64(12, BigInt(`0x${id}`), true);
  const sig = createHmac('sha256', Buffer.from(ENV.UPLOAD_KEY, 'hex')).update(log).digest('hex');
  assert.equal((await call(lobby, 'POST', `/v1/relay/logs/${id}`, { body: log, headers: { 'x-openbfme-signature': sig } })).status, 200);
  env.advance(PRESENCE_S + STATS_CACHE_S);
  r = (await stats(lobby)).body;
  assert.equal(r.games_running, 0);
  assert.equal(r.players, 0);
});

test('a started game whose log never comes stops counting when the lobby forgets it (startedGameKeepMs)', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const a = await guest(lobby, 'Ann');
  const b = await guest(lobby, 'Bea');
  await startedGame(lobby, a, b);
  env.advance(PRESENCE_S + 1);
  assert.equal((await stats(lobby)).body.players, 2);
  env.advance(3 * 3600 + 1);
  const r = (await stats(lobby)).body;
  assert.equal(r.games_running, 0);
  assert.equal(r.players, 0);
});

test('the answer is computed at most every STATS_CACHE_S seconds and says so in Cache-Control', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const first = await stats(lobby);
  assert.equal(first.headers['cache-control'], `public, max-age=${STATS_CACHE_S}`);
  await guest(lobby, 'Ann');
  env.advance(STATS_CACHE_S - 1);
  assert.deepEqual((await stats(lobby)).body, first.body, 'inside the interval the cached answer is served, as_of included');
  env.advance(1);
  const fresh = (await stats(lobby)).body;
  assert.equal(fresh.players, 1);
  assert.equal(fresh.as_of, first.body.as_of + STATS_CACHE_S);
});

test('malformed requests: other methods and paths are not the stats endpoint; a flood from one address is rate limited', async () => {
  const lobby = new Lobby(fakeEnv(), configFromEnv(ENV));
  assert.equal((await call(lobby, 'POST', '/v1/stats', { body: {} })).status, 404);
  assert.equal((await call(lobby, 'GET', '/v1/stats/x')).status, 404);
  assert.equal((await call(lobby, 'GET', '/v1/stats?players=99&x=%00')).body.players, 0, 'query strings change nothing');
  let limited = 0;
  for (let i = 0; i < 40; i++) if ((await stats(lobby, { ip: '203.0.113.9' })).status === 429) limited += 1;
  assert.ok(limited > 0, 'a flood is refused with 429');
  assert.equal((await stats(lobby, { ip: '203.0.113.10' })).status, 200, 'another address is not affected');
});

test('the presence table is bounded: past MAX_PRESENT a new session is not remembered, and expired ones make room', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  for (let i = 0; i < MAX_PRESENT + 10; i++) lobby.seen(`guest:${i}`);
  assert.equal(lobby.present.size, MAX_PRESENT);
  assert.equal(lobby.stats().players, MAX_PRESENT);
  env.advance(PRESENCE_S + STATS_CACHE_S);
  lobby.seen('guest:new');
  assert.equal(lobby.present.size, 1);
});

test('the Worker answers an unsigned stats request from the data centre cache and sends a signed one (the online menu\'s) to the object', async () => {
  const store = new Map();
  const cache = { match: async (k) => store.get(k.url)?.clone(), put: async (k, r) => { store.set(k.url, r); } };
  let asked = 0;
  const ask = async () => { asked += 1; return new Response(JSON.stringify({ v: 1, players: 3 }), { status: 200, headers: { 'cache-control': 'public, max-age=30' } }); };
  const waits = [];
  const ctx = { waitUntil: (p) => waits.push(p) };
  const req = new Request('https://lobby.example/v1/stats');
  assert.equal((await (await statsFromCache(req, ctx, cache, ask)).json()).players, 3);
  await Promise.all(waits);
  assert.equal((await (await statsFromCache(req, ctx, cache, ask)).json()).players, 3);
  assert.equal(asked, 1, 'the second request never reached the object');
  // a failure is not cached
  const failing = async () => new Response('{}', { status: 429 });
  const cache2 = { match: async () => undefined, put: async () => { throw new Error('a refusal must not be cached'); } };
  assert.equal((await statsFromCache(req, ctx, cache2, failing)).status, 429);
  // the default export: a signed request goes to the object whatever the cache holds
  const sent = [];
  const env = { LOBBY: { idFromName: () => 'x', get: () => ({ fetch: async (r) => { sent.push(r.headers.get('authorization')); return new Response('{}'); } }) } };
  globalThis.caches = { default: { match: async () => new Response('{"cached":true}'), put: async () => {} } };
  try {
    assert.equal(await (await worker.fetch(new Request('https://lobby.example/v1/stats'), env, ctx)).text(), '{"cached":true}');
    await worker.fetch(new Request('https://lobby.example/v1/stats', { headers: { authorization: 'Bearer t' } }), env, ctx);
    assert.deepEqual(sent, ['Bearer t']);
    await worker.fetch(new Request('https://lobby.example/v1/games'), env, ctx);
    assert.equal(sent.length, 2, 'other paths are not cached');
  } finally {
    delete globalThis.caches;
  }
});

test('r2 (Sol): a finished game stays finished after the lobby restarts (the record keeps it); a game still running stays running', async () => {
  const env = fakeEnv();
  const lobby = new Lobby(env, configFromEnv(ENV));
  const [a, b, c, d] = [await guest(lobby, 'Ann'), await guest(lobby, 'Bea'), await guest(lobby, 'Cy'), await guest(lobby, 'Di')];
  const over = await startedGame(lobby, a, b);
  await startedGame(lobby, c, d);
  const log = new Uint8Array(25);
  log.set(Buffer.from('OBFMERLG'));
  new DataView(log.buffer).setUint32(8, 1, true);
  new DataView(log.buffer).setBigUint64(12, BigInt(`0x${over}`), true);
  const sig = createHmac('sha256', Buffer.from(ENV.UPLOAD_KEY, 'hex')).update(log).digest('hex');
  assert.equal((await call(lobby, 'POST', `/v1/relay/logs/${over}`, { body: log, headers: { 'x-openbfme-signature': sig } })).status, 200);
  env.advance(PRESENCE_S + STATS_CACHE_S);
  const before = (await stats(lobby)).body;
  assert.deepEqual([before.players, before.games_running], [2, 1]);
  // a restart: a new lobby object loads the saved records; nobody has been seen yet
  const again = new Lobby(env, configFromEnv(ENV));
  again.load([...env.savedGames.values()]);
  const after = (await stats(again)).body;
  assert.deepEqual([after.players, after.games_running], [2, 1], 'the finished game did not come back');
  // the same log uploaded again after the restart changes nothing and writes nothing new
  const saves = env.savedGames.size;
  assert.equal((await call(again, 'POST', `/v1/relay/logs/${over}`, { body: log, headers: { 'x-openbfme-signature': sig } })).status, 200);
  assert.equal(env.savedGames.size, saves);
});

test('r2 (Sol): admission before the cache: one address cannot get 100 answers in a burst, cached or not; other addresses are not affected', async () => {
  let t = 1_700_000_000_000;
  const adm = new StatsAdmission(() => t);
  let ok = 0;
  for (let i = 0; i < 100; i++) if (adm.admit('203.0.113.9')) ok += 1;
  assert.equal(ok, STATS_ADMIT_BURST);
  assert.equal(adm.admit('203.0.113.10'), true);
  t += 60_000;
  assert.equal(adm.admit('203.0.113.9'), true, 'refilled after a minute');
  for (let i = 0; i < 6000; i++) adm.admit(`a${i}`);
  assert.ok(adm.buckets.size <= 5000, 'bounded');
});

test('r2 (Sol): the whole Worker path: fetch handler -> admission -> cache -> object; a burst of 100 gets 429s and the object sees no extra request', async () => {
  const { default: worker, statsAdmission } = await import('../src/worker.mjs');
  statsAdmission.buckets.clear();
  const cacheStore = new Map();
  globalThis.caches = { default: { match: async (k) => cacheStore.get(k.url)?.clone(), put: async (k, r) => { cacheStore.set(k.url, r); } } };
  let object = 0;
  const env = { LOBBY: { idFromName: () => 'x', get: () => ({ fetch: async () => { object += 1; return new Response('{"v":1,"players":1}', { status: 200 }); } }) } };
  const waits = [];
  const ctx = { waitUntil: (p) => waits.push(p) };
  try {
    const codes = [];
    for (let i = 0; i < 100; i++) {
      const r = await worker.fetch(new Request('https://lobby.example/v1/stats', { headers: { 'cf-connecting-ip': '203.0.113.50' } }), env, ctx);
      codes.push(r.status);
      await Promise.all(waits);
    }
    assert.equal(codes.filter((c) => c === 200).length, STATS_ADMIT_BURST);
    assert.equal(codes.filter((c) => c === 429).length, 100 - STATS_ADMIT_BURST);
    assert.equal(object, 1, 'one miss reached the object; the hits and the refusals did not');
    const refused = await worker.fetch(new Request('https://lobby.example/v1/stats', { headers: { 'cf-connecting-ip': '203.0.113.50' } }), env, ctx);
    assert.equal(refused.headers.get('retry-after'), '10');
    assert.equal(refused.headers.get('cache-control'), 'no-store');
    // a signed request from the same address is refused too (it would cost an object request), another address passes
    assert.equal((await worker.fetch(new Request('https://lobby.example/v1/stats', { headers: { 'cf-connecting-ip': '203.0.113.50', authorization: 'Bearer x' } }), env, ctx)).status, 429);
    assert.equal((await worker.fetch(new Request('https://lobby.example/v1/stats', { headers: { 'cf-connecting-ip': '203.0.113.51' } }), env, ctx)).status, 200);
    // other paths are not limited here
    assert.equal((await worker.fetch(new Request('https://lobby.example/v1/games', { headers: { 'cf-connecting-ip': '203.0.113.50' } }), env, ctx)).status, 200);
  } finally {
    delete globalThis.caches;
    statsAdmission.buckets.clear();
  }
});

test('LOBBYSTATS-1: the self-hosted server\'s file store lists its START records\' and relay logs\' write times (file mtimes), not player lists', async () => {
  const { mkdtempSync, rmSync, utimesSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const { fileStore } = await import('../src/server.mjs');
  const dir = mkdtempSync(join(tmpdir(), 'openbfme-gametimes-'));
  try {
    const store = fileStore(dir);
    const bytes = new TextEncoder().encode('{}');
    store.putBlob('starts/0000000000000001.json', bytes);
    store.putBlob('starts/0000000000000002.json', bytes);
    store.putBlob('players/0000000000000001.json', bytes);
    store.putBlob('logs/0000000000000001.obfmerlog', bytes);
    utimesSync(join(dir, 'starts/0000000000000002.json'), 1000, 1000); // 1000 s
    const since = Date.now() - 60_000;
    const t = store.gameTimes(since);
    assert.deepEqual([t.started.length, t.finished.length], [1, 1]);
    assert.ok([...t.started, ...t.finished].every((at) => at >= since));
    assert.deepEqual(store.gameTimes(0).started.sort((x, y) => x - y)[0], 1_000_000);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
