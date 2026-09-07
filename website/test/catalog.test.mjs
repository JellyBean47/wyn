import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { loadCatalog, filterGames, profileApiPayload } from '../lib/catalog.mjs';
import { gamesPage, submitPage, gamePage, homePage, supportPage } from '../lib/html.mjs';
const data = loadCatalog(fileURLToPath(new URL('../../', import.meta.url)));
test('catalog profile references resolve', () => assert.deepEqual(data.missingProfiles, []));
test('search supports variant ids and layers', () => {
  const variant = data.games.find(game => game.profiles.some(p => p.id === 'satisfactory-dxmt'));
  assert.ok(variant);
  assert.ok(filterGames(data.games, { q: 'satisfactory-dxmt', layer: 'dxmt' }).includes(variant));
});
test('profile download is an actual profile without API metadata', () => {
  const profile = [...data.profilesById.values()][0];
  const result = profileApiPayload(profile);
  assert.equal(result.filename, undefined); assert.equal(result.href, undefined); assert.equal(result.id, profile.id);
});
test('game pages offer downloads and contributions, escape data', () => {
  const html = gamePage({ ...data.games[0], name: '<script>alert(1)</script>' });
  assert.ok(html.includes('&lt;script&gt;')); assert.ok(!html.includes('<script>alert'));
  assert.ok(html.includes('download=')); assert.ok(html.includes('/submit?profile='));
});
test('all rows exist even with initial filters; submission starts empty', () => {
  const html = gamesPage(data.games, { q: 'satisfactory' });
  assert.equal((html.match(/data-slug=/g) || []).length, data.games.length);
  assert.ok(submitPage().includes('required aria-describedby="profile-hint"></textarea>'));
});
test('support page explains free app, guessed vs verified, and has no paywall tiers', () => {
  const html = supportPage(data);
  assert.ok(html.includes('href="/support"'));
  assert.ok(html.includes('github.com/sponsors/JellyBean47'));
  assert.ok(html.includes('verified'));
  assert.ok(!html.includes('$7/month'));
  assert.ok(homePage(data).includes('href="/support"'));
});
