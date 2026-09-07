// SPDX-License-Identifier: GPL-3.0-or-later
import { errorsIn, validateProfile } from './validate.mjs';

export const MAX_BODY = 256 * 1024;
export function prepareSubmission(raw) {
  if (new TextEncoder().encode(raw).length > MAX_BODY) {
    return { status: 413, body: { ok: false, error: 'Profiles must be 256 KB or smaller.' } };
  }
  let profile;
  try { profile = JSON.parse(raw); }
  catch { return { status: 400, body: { ok: false, error: 'That is not valid JSON.' } }; }
  if (profile && Object.hasOwn(profile, 'profile')) profile = profile.profile;
  const findings = validateProfile(profile);
  if (errorsIn(findings).length) return { status: 422, body: { ok: false, findings } };
  // API presentation fields are not part of a Wyn profile.
  const { href, filename, ...fields } = profile;
  return { profile: { ...fields, status: fields.status ?? 'guessed' }, findings };
}

export async function submissionRecord(profile) {
  const canonical = (value) => Array.isArray(value) ? value.map(canonical)
    : value && typeof value === 'object'
      ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(canonical(profile))));
  const receipt = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  return { receipt, submittedAt: new Date().toISOString(), reviewStatus: 'pending', profile };
}
