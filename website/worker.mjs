// SPDX-License-Identifier: GPL-3.0-or-later
import { MAX_BODY, prepareSubmission, submissionRecord } from './lib/submission.mjs';
import { SUPPORT_PAGE_ENABLED } from './lib/html.mjs';

function json(data, status = 200, headers = {}) {
  return Response.json(data, { status, headers: {
    'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers,
  } });
}

async function readLimited(request) {
  if (Number(request.headers.get('content-length')) > MAX_BODY) throw Object.assign(new Error('Profiles must be 256 KB or smaller.'), { status: 413 });
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      throw Object.assign(new Error('Profiles must be 256 KB or smaller.'), { status: 413 });
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(bytes);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/$/, '') || '/';
    if (!SUPPORT_PAGE_ENABLED && path === '/support') {
      const notFound = await env.ASSETS.fetch(new Request(new URL('/404.html', url), request));
      return new Response(notFound.body, { status: 404, headers: notFound.headers });
    }
    if (path !== '/api/v1/submit') {
      const response = await env.ASSETS.fetch(request);
      if (url.pathname.startsWith('/api/') && response.status === 404) return json({ ok: false, error: 'Unknown endpoint.' }, 404);
      return response;
    }
    if (request.method === 'GET') return json({
      available: Boolean(env.SUBMISSIONS && env.SUBMISSION_LIMITER),
      mode: 'review', maxBytes: MAX_BODY,
    }, env.SUBMISSIONS && env.SUBMISSION_LIMITER ? 200 : 503);
    if (request.method !== 'POST') return json({ ok: false, error: 'Use POST with a JSON profile.' }, 405, { allow: 'GET, POST' });
    const origin = request.headers.get('origin');
    if (origin && origin !== url.origin) return json({ ok: false, error: 'Submit from this website.' }, 403);
    if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
      return json({ ok: false, error: 'Use Content-Type: application/json.' }, 415);
    }
    if (!env.SUBMISSIONS || !env.SUBMISSION_LIMITER) return json({ ok: false, error: 'Uploads are temporarily unavailable. Keep your JSON and try again later.' }, 503);
    try {
      const limit = await env.SUBMISSION_LIMITER.limit({ key: request.headers.get('cf-connecting-ip') || 'unknown' });
      if (!limit.success) return json({ ok: false, error: 'Too many attempts. Wait one minute and try again.' }, 429, { 'retry-after': '60' });
      const parsed = prepareSubmission(await readLimited(request));
      if (!parsed.profile) return json(parsed.body, parsed.status);
      const record = await submissionRecord(parsed.profile);
      // Content-addressed keys make retries safe; pending profiles are never served publicly.
      const key = `pending:${record.receipt}`;
      if (!(await env.SUBMISSIONS.get(key))) {
        await env.SUBMISSIONS.put(key, JSON.stringify(record), {
          metadata: { id: record.profile.id, submittedAt: record.submittedAt },
        });
      }
      return json({ ok: true, id: parsed.profile.id, receipt: record.receipt,
        findings: parsed.findings, message: 'Received for review. Your profile is not public yet.' }, 201);
    } catch (error) {
      return json({ ok: false, error: error.status === 413 ? error.message : 'We could not save your profile. Keep your JSON and try again.' }, error.status === 413 ? 413 : 503);
    }
  },
};
