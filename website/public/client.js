// SPDX-License-Identifier: GPL-3.0-or-later
import { errorsIn, validateProfile } from '/validate.mjs';

const filters = document.querySelector('#filters');
const rows = document.querySelector('#game-rows');
if (filters && rows) {
  const fields = ['q', 'status', 'layer'];
  const readUrl = () => {
    const params = new URLSearchParams(location.search);
    for (const name of fields) filters.elements[name].value = params.get(name) ?? '';
  };
  const apply = (updateUrl = true) => {
    const values = Object.fromEntries(fields.map(name => [name, filters.elements[name].value]));
    const needle = values.q.trim().toLowerCase();
    let shown = 0;
    for (const row of rows.querySelectorAll('tr[data-slug]')) {
      const hay = [row.dataset.name, row.dataset.slug, row.dataset.publisher, row.dataset.steam, row.dataset.profiles].join(' ').toLowerCase();
      const match = (!needle || hay.includes(needle)) &&
        (!values.status || row.dataset.status === values.status) &&
        (!values.layer || row.dataset.layers.split(' ').includes(values.layer));
      row.hidden = !match;
      if (match) shown++;
    }
    document.querySelector('#result-count').textContent = `${shown} of ${rows.querySelectorAll('tr[data-slug]').length} games`;
    document.querySelector('#no-results').hidden = shown > 0;
    if (updateUrl) {
      const params = new URLSearchParams();
      for (const name of fields) if (values[name]) params.set(name, values[name]);
      history.replaceState(null, '', `${location.pathname}${params.size ? '?' + params : ''}`);
    }
  };
  readUrl(); apply(false);
  filters.addEventListener('input', () => apply());
  filters.addEventListener('change', () => apply());
  filters.addEventListener('submit', event => { event.preventDefault(); apply(); });
  window.addEventListener('popstate', () => { readUrl(); apply(false); });
}

const form = document.querySelector('#submit-form');
if (form) {
  const file = form.querySelector('#file');
  const payload = form.querySelector('#payload');
  const result = form.querySelector('#submit-result');
  const drop = form.querySelector('.drop');
  const send = form.querySelector('#send-profile');
  const availability = document.querySelector('#upload-status');
  const maxBytes = 256 * 1024;
  let busy = false;
  let available = false;
  let acceptedText = null;
  const show = (message, ok = false) => {
    result.className = ok ? 'ok' : 'err';
    result.textContent = message;
  };
  const checkAvailability = async () => {
    try {
      const response = await fetch('/api/v1/submit', { signal: AbortSignal.timeout(10000) });
      const data = await response.json();
      available = response.ok && data.available === true;
      availability.textContent = available
        ? data.mode === 'local' ? 'Local preview: uploads are saved on this Mac, not sent to wyn-dev.com.' : 'Uploads are open. Profiles stay private until reviewed. No account needed.'
        : 'Uploads are temporarily unavailable. You can check and download your draft, then try again later.';
      send.textContent = data.mode === 'local' ? 'Save to local review queue' : 'Submit for review';
    } catch {
      available = false;
      availability.textContent = 'Cannot reach the upload service. You can check and download your draft while offline.';
    }
    send.disabled = !available || busy || payload.value === acceptedText;
  };
  const edited = () => {
    result.textContent = '';
    form.querySelector('#consent').checked = false;
    send.disabled = !available || busy || payload.value === acceptedText;
  };
  payload.addEventListener('input', edited);
  const loadFile = async chosen => {
    if (!chosen) return;
    if (!chosen.name.toLowerCase().endsWith('.json')) { show('Choose a .json profile file.'); return; }
    if (chosen.size > maxBytes) { show('Profiles must be 256 KB or smaller.'); return; }
    try {
      payload.value = (await chosen.text()).trim();
      edited();
      form.querySelector('#file-name').textContent = `Loaded ${chosen.name} · ${Math.ceil(chosen.size / 1024)} KB`;
    } catch { show('Could not read that file. Try choosing it again.'); }
  };
  file.addEventListener('change', () => loadFile(file.files?.[0]));
  for (const event of ['dragover', 'dragenter']) drop.addEventListener(event, e => { e.preventDefault(); drop.classList.add('dragging'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('dragging'));
  drop.addEventListener('drop', e => {
    e.preventDefault(); drop.classList.remove('dragging');
    if (e.dataTransfer.files.length !== 1) { show('Choose one JSON profile at a time.'); return; }
    loadFile(e.dataTransfer.files[0]);
  });
  form.querySelector('#use-example').addEventListener('click', () => {
    if (payload.value.trim()) { show('Download or clear your current draft before loading the example.'); return; }
    payload.value = document.querySelector('#sample-profile').content.textContent.trim();
    edited(); payload.focus();
  });
  const parse = () => {
    if (new TextEncoder().encode(payload.value).length > maxBytes) throw new Error('Profiles must be 256 KB or smaller.');
    let profile;
    try { profile = JSON.parse(payload.value); }
    catch { throw new Error('That is not valid JSON. Check quotes, commas, and brackets.'); }
    if (profile && Object.hasOwn(profile, 'profile')) profile = profile.profile;
    const findings = validateProfile(profile);
    if (errorsIn(findings).length) throw new Error(errorsIn(findings).map(f => f.message).join('\n'));
    return { profile, findings };
  };
  form.querySelector('#validate-profile').addEventListener('click', () => {
    try {
      const { findings } = parse();
      show('Profile checks passed. This checks the file, not whether the game runs.' +
        (findings.length ? '\nWarnings: ' + findings.map(f => f.message).join('\n') : ''), true);
    } catch (error) { show(error.message); }
  });
  form.querySelector('#download-draft').addEventListener('click', () => {
    if (!payload.value.trim()) { show('Add a profile before downloading a draft.'); return; }
    const blob = new Blob([payload.value], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a'); link.href = url; link.download = 'wyn-profile-draft.json';
    link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !available) return;
    try {
      const { profile } = parse();
      if (profile.id === 'example-game') throw new Error('Replace the example with your game’s real ID, name, settings, and notes before submitting.');
      busy = true; send.disabled = true; form.setAttribute('aria-busy', 'true');
      const submittedText = payload.value;
      show('Uploading…', true);
      const response = await fetch('/api/v1/submit', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(profile), signal: AbortSignal.timeout(20000),
      });
      let data;
      try { data = await response.json(); }
      catch { throw new Error('The upload service did not return a receipt. Keep your draft and try again later.'); }
      if (!response.ok || !data.ok) throw new Error((data.findings ?? []).filter(f => f.severity === 'error').map(f => f.message).join('\n') || data.error || 'Upload failed. Please try again.');
      acceptedText = submittedText;
      const warnings = (data.findings ?? []).filter(f => f.severity === 'warning');
      show(`${data.message}\nReceipt: ${data.receipt}\nKeep this receipt and a copy of your JSON.` +
        (warnings.length ? '\nWarnings: ' + warnings.map(f => f.message).join('\n') : ''), true);
      result.focus();
    } catch (error) {
      show(error.name === 'TimeoutError' || error instanceof TypeError ? 'The connection failed or timed out. Your JSON is still here. Retry when connected; identical uploads share one receipt.' : error.message);
    } finally {
      busy = false; form.removeAttribute('aria-busy'); send.disabled = !available || payload.value === acceptedText;
    }
  });
  window.addEventListener('online', checkAvailability);
  checkAvailability();
  const profileId = new URLSearchParams(location.search).get('profile');
  if (profileId && /^[a-z0-9-]{1,100}$/.test(profileId)) {
    fetch(`/api/v1/profiles/${encodeURIComponent(profileId)}.json`, { signal: AbortSignal.timeout(10000) })
      .then(async response => { if (!response.ok) throw new Error(); return response.json(); })
      .then(profile => {
        if (payload.value.trim()) return;
        // A new contribution must establish its own evidence.
        profile.status = 'guessed';
        payload.value = JSON.stringify(profile, null, 2); edited();
        form.querySelector('#file-name').textContent = `Starting from ${profileId}. Update the notes with your own results and choose the status your testing supports.`;
      }).catch(() => show('Could not load that profile. You can upload a file or paste your JSON instead.'));
  }
}
