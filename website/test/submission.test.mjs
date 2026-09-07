import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker.mjs';
import { MAX_BODY, prepareSubmission, submissionRecord } from '../lib/submission.mjs';

const good = { id: 'test-game', name: 'Test Game', exePatterns: ['game.exe'], environment: {}, bottle: { translationLayer: 'd3dmetal', dxvk: false }, status: 'guessed' };
function setup() {
  const values = new Map();
  const env = {
    SUBMISSIONS: { get: async key => values.get(key), put: async (key, value) => values.set(key, value) },
    SUBMISSION_LIMITER: { limit: async () => ({ success: true }) },
    ASSETS: { fetch: async () => new Response('Not found', { status: 404 }) },
  };
  const post = (body = good, options = {}) => worker.fetch(new Request('https://wyn-dev.com/api/v1/submit', {
    method: 'POST', headers: { 'content-type': 'application/json', ...options.headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  }), env);
  return { env, values, post };
}
test('accepted profiles are private, queued and return a stable receipt', async () => {
  const { post, values } = setup();
  const first = await post(); assert.equal(first.status, 201);
  const response = await first.json(); assert.match(response.receipt, /^[a-f0-9]{64}$/);
  assert.equal((await (await post({ profile: good })).json()).receipt, response.receipt);
  assert.equal(values.size, 1);
  const record = JSON.parse([...values.values()][0]);
  assert.equal(record.reviewStatus, 'pending'); assert.deepEqual(record.profile, good);
  assert.equal(response.path, undefined);
});
test('hash ignores object key order but preserves array order', async () => {
  assert.equal((await submissionRecord(good)).receipt, (await submissionRecord(Object.fromEntries(Object.entries(good).reverse()))).receipt);
  assert.notEqual((await submissionRecord(good)).receipt, (await submissionRecord({ ...good, name: 'Changed' })).receipt);
});
test('invalid JSON and malformed types never reach storage', async () => {
  const { post, values } = setup();
  assert.equal((await post('{')).status, 400);
  for (const profile of [null, [], 1, { ...good, id: '../escape' }, { ...good, id: 'a'.repeat(101) },
    { ...good, exePatterns: [4] }, { ...good, environment: [] }, { ...good, environment: { DEBUG: true } },
    { ...good, steamAppId: '123' }, { ...good, bottle: [] }, { ...good, bottle: { metalHud: 'false' } },
    { ...good, bottle: { enhancedSync: 'invalid' } }, { ...good, notes: {} }, { ...good, status: { toString: 4 } },
    { ...good, status: 'verified' }, { ...good, assettoCorsa: {} }]) {
    assert.equal((await post(JSON.stringify(profile))).status, 422, JSON.stringify(profile));
  }
  assert.equal(values.size, 0);
});
test('risky untested settings rejected; verified profile requires evidence', async () => {
  const { post } = setup();
  assert.equal((await post({ ...good, environment: { D3DM_ENABLE_METALFX: '1' } })).status, 422);
  assert.equal((await post({ ...good, environment: { WINEDLLOVERRIDES: 'd3d11=n' } })).status, 422);
  assert.equal((await post({ ...good, status: 'verified', notes: 'M2, macOS 15, reached a loaded map at 30 FPS.', environment: { MTL_HUD_ENABLED: '1' } })).status, 201);
});
test('oversized declared and streaming bodies are rejected', async () => {
  const { post, env, values } = setup();
  assert.equal((await post('x'.repeat(MAX_BODY + 1))).status, 413);
  assert.equal((await post(good, { headers: { 'content-length': String(MAX_BODY + 1) } })).status, 413);
  const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(MAX_BODY)); controller.enqueue(new Uint8Array(1)); controller.close(); } });
  const response = await worker.fetch(new Request('https://wyn-dev.com/api/v1/submit', { method: 'POST', headers: { 'content-type': 'application/json' }, body: stream, duplex: 'half' }), env);
  assert.equal(response.status, 413); assert.equal(values.size, 0);
});
test('cross-origin forms, unsupported methods and content types rejected', async () => {
  const { env, post } = setup();
  assert.equal((await post(good, { headers: { origin: 'https://other.example' } })).status, 403);
  assert.equal((await post(good, { headers: { origin: 'https://wyn-dev.com' } })).status, 201);
  assert.equal((await post(good, { headers: { 'content-type': 'text/plain' } })).status, 415);
  assert.equal((await worker.fetch(new Request('https://wyn-dev.com/api/v1/submit', { method: 'DELETE' }), env)).status, 405);
});
test('missing bindings, exhausted rate limit and storage failure never claim success', async () => {
  const { env, post } = setup();
  env.SUBMISSION_LIMITER.limit = async () => ({ success: false });
  const limited = await post(); assert.equal(limited.status, 429); assert.equal(limited.headers.get('retry-after'), '60');
  env.SUBMISSION_LIMITER.limit = async () => ({ success: true });
  env.SUBMISSIONS.put = async () => { throw new Error('private internal detail'); };
  const failed = await post(); assert.equal(failed.status, 503); assert.ok(!(await failed.text()).includes('private internal detail'));
  delete env.SUBMISSIONS; assert.equal((await post()).status, 503);
  const availability = await worker.fetch(new Request('https://wyn-dev.com/api/v1/submit'), env);
  assert.equal(availability.status, 503); assert.equal((await availability.json()).available, false);
});
test('API errors are JSON and pending submissions have no public read route', async () => {
  const { env } = setup();
  const response = await worker.fetch(new Request('https://wyn-dev.com/api/v1/submissions/test'), env);
  assert.equal(response.status, 404); assert.equal((await response.json()).ok, false);
});
test('presentation metadata is stripped and missing status defaults to guessed', () => {
  const { status, ...profile } = good;
  const parsed = prepareSubmission(JSON.stringify({ ...profile, href: '/test', filename: 'test.json' }));
  assert.deepEqual(parsed.profile, good);
});
