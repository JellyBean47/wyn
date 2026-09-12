import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { loadCatalog, filterGames, profileApiPayload } from '../lib/catalog.mjs';
import { gamesPage, submitPage, gamePage, homePage, SUPPORT_PAGE_ENABLED, supportPage } from '../lib/html.mjs';
const data = loadCatalog(fileURLToPath(new URL('../../', import.meta.url)));
test('catalog profile references resolve', () => assert.deepEqual(data.missingProfiles, []));
test('launched titles are the ones with Mac evidence, not theoretical ports', () => {
  const launched = data.games.filter((game) => game.status === 'launched').map((game) => game.slug).sort();
  const verified = data.games.filter((game) => game.status === 'verified').map((game) => game.slug).sort();
  // ac-odyssey graduated to `verified` on 10 Sep 2026 — see its profile notes
  // for what backs that claim, and what does not.
  // rv-there-yet graduated on 11 Sep 2026: Ride.log LoadMap(RideMap), 1514
  // frames, LogExit: Exiting., adapter Apple M4 through DXMT.
  // witcher-3 graduated the same night on the Ready or Not bar (in-world play,
  // D3DMetal lsof, no REDengine log).
  assert.deepEqual(launched, ['assetto-corsa', 'cities-skylines', 'skyrim-se']);
  assert.deepEqual(verified, ['ac-odyssey', 'army-men-rts', 'doom-2016', 'fallout-4', 'fallout-new-vegas', 'ready-or-not', 'rv-there-yet', 'satisfactory', 'solarpunk', 'witcher-3', 'wolfenstein-youngblood']);
  assert.equal(data.counts.verified, 11);
});
test('home lists verified and launched titles', () => {
  const html = homePage(data);
  assert.ok(html.includes('Solarpunk'));
  assert.ok(html.includes('Ready or Not'));
  assert.ok(html.includes('Assetto Corsa'));
  assert.ok(html.includes('/games/rv-there-yet'));
  assert.ok(html.includes('RV There Yet?'));
  assert.ok(html.includes('/games/ac-odyssey'));
  assert.ok(html.includes('/games/witcher-3'));
  assert.ok(html.includes('The Witcher 3'));
  assert.ok(html.includes('/games/wolfenstein-youngblood'));
  assert.ok(html.includes('Wolfenstein: Youngblood'));
  assert.ok(html.includes('/games/doom-2016'));
  assert.ok(html.includes('DOOM (2016)'));
  assert.ok(html.includes('/games/fallout-4'));
  assert.ok(html.includes('Fallout 4'));
  assert.ok(html.includes('/games/fallout-new-vegas'));
  assert.ok(html.includes('Fallout: New Vegas'));
  assert.ok(html.includes('/games/army-men-rts'));
  assert.ok(html.includes('Army Men RTS'));
  assert.ok(html.includes('badge launched'));
  assert.ok(html.includes('badge verified'));
});
test('army men verified notes require the 1024x768 window', () => {
  const game = data.bySlug.get('army-men-rts');
  assert.equal(game.status, 'verified');
  assert.equal(game.profiles[0].launchArgs, '-vidmode:1024x768 -h');
  const html = gamePage(game);
  assert.ok(html.includes('badge verified'));
  assert.ok(html.includes('1024x768'));
  assert.ok(html.includes('small 1024x768 window'));
});
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
  assert.ok(html.includes('github.com/sponsors/JellyBean47'));
  assert.ok(html.includes('verified'));
  assert.ok(!html.includes('$7/month'));
});
test('support is unpublished until SUPPORT_PAGE_ENABLED is true', () => {
  assert.equal(SUPPORT_PAGE_ENABLED, false);
  const home = homePage(data);
  assert.ok(!home.includes('href="/support"'));
  assert.ok(!home.includes('>Support</a>'));
});
