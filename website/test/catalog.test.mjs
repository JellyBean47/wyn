import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { loadCatalog, filterGames, profileApiPayload, profileRunsFromDownload, downloadSupport } from '../lib/catalog.mjs';
import { gamesPage, submitPage, gamePage, homePage, SUPPORT_PAGE_ENABLED, supportPage, DOWNLOAD_URL, SOURCE_URL, downloadBadge } from '../lib/html.mjs';
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
  // rdr2 joined `launched` on 12 Sep 2026: the Epic copy, ~16 min of in-world
  // play, clean exit — but on a hand-built Libraries.rgl tree with vkd3d, not
  // on the Wyn stack, so it cannot reach `verified` as this site defines it.
  assert.deepEqual(launched, ['assetto-corsa', 'cities-skylines', 'rdr2', 'skyrim-se']);
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
test('the download claim is enumerated, not inferred from the layer alone', () => {
  // The promise on the front page is "install this and these games run", so it
  // is held by name like the status ladders are. An unset translationLayer is
  // not enough on its own to decide: army-men and New Vegas measured as
  // ddraw/d3d9 → wined3d → OpenGL, which the tarball carries, while rdr2 is
  // unset because it runs on vkd3d on a hand-built tree that no download has.
  const verified = data.games.filter((g) => g.status === 'verified');
  const by = (state) => verified.filter((g) => g.downloadSupport === state).map((g) => g.slug).sort();

  assert.deepEqual(by('runs'), [
    'army-men-rts', 'doom-2016', 'fallout-new-vegas', 'rv-there-yet', 'solarpunk', 'wolfenstein-youngblood',
  ]);
  assert.deepEqual(by('source-install'), ['ac-odyssey', 'fallout-4', 'ready-or-not', 'witcher-3']);
  assert.equal(data.counts.verifiedFromDownload, by('runs').length);

  // Solarpunk ships both a d3dmetal and a dxmt profile, and solarpunk-dxmt is
  // itself verified — so the download claim is carried by evidence, not by the
  // layer name.
  const solarpunk = data.bySlug.get('solarpunk');
  assert.equal(downloadSupport(solarpunk), 'runs');
  assert.ok(solarpunk.profiles.some((p) => !profileRunsFromDownload(p)));

  // Satisfactory is the reason there are three states rather than two: verified
  // on d3dmetal, with a satisfactory-dxmt variant that is still guessed. The
  // download might run it; nobody has shown that it does.
  const satisfactory = data.bySlug.get('satisfactory');
  assert.equal(satisfactory.status, 'verified');
  assert.equal(satisfactory.downloadSupport, 'untested');
  assert.equal(data.profilesById.get('satisfactory-dxmt').status, 'guessed');
  assert.equal(downloadBadge(satisfactory), '');

  // rdr2 is the case a layer check alone gets wrong: no d3dmetal anywhere in
  // it, and still not runnable from the download.
  const rdr2 = data.profilesById.get('rdr2');
  assert.equal(rdr2.bottle?.translationLayer ?? null, null);
  assert.equal(profileRunsFromDownload(rdr2), false);
});
test('a title needing the source install says so on its own page', () => {
  const witcher = data.bySlug.get('witcher-3');
  assert.equal(witcher.downloadSupport, 'source-install');
  const html = gamePage(witcher);
  assert.ok(html.includes('badge needs-source'));
  assert.ok(html.includes('--accept-gptk-licence'));

  const doom = data.bySlug.get('doom-2016');
  assert.equal(doom.downloadSupport, 'runs');
  const doomHtml = gamePage(doom);
  assert.ok(doomHtml.includes('badge from-download'));
  assert.ok(!doomHtml.includes('--accept-gptk-licence'));
});
test('the binary is never offered without its source', () => {
  // GPL-3 §6(d): equivalent access to the source from the same place as the
  // binary is what makes shipping the binary lawful. Whoever sets DOWNLOAD_URL
  // must not be able to publish a download that stands alone, so assert the
  // pairing on every page that can print it rather than trusting the copy.
  const pages = [homePage(data), supportPage(data)];
  for (const html of pages) {
    if (!DOWNLOAD_URL || !html.includes(DOWNLOAD_URL)) continue;
    assert.ok(html.includes(SOURCE_URL), 'a page offering the DMG must link the source');
    assert.ok(/GPL-3\.0/.test(html), 'a page offering the DMG must name the license');
  }
  // Until the DMG exists, the source install is still the offer, and the home
  // page has to say where it is.
  assert.ok(homePage(data).includes(SOURCE_URL));
});
test('support is unpublished until SUPPORT_PAGE_ENABLED is true', () => {
  assert.equal(SUPPORT_PAGE_ENABLED, false);
  const home = homePage(data);
  assert.ok(!home.includes('href="/support"'));
  assert.ok(!home.includes('>Support</a>'));
});
