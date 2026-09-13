//
//  html.mjs
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function statusLabel(status) {
  if (status === "verified") return "Verified";
  if (status === "launched") return "Launched";
  return "Guessed";
}

export function layerLabel(layer) {
  if (layer === "d3dmetal") return "D3DMetal";
  if (layer === "dxvk") return "DXVK";
  if (layer === "dxmt") return "DXMT";
  return layer ?? "—";
}

// Flip to true to publish /support (nav, footer, home link, static build, local server).
export const SUPPORT_PAGE_ENABLED = false;

// Where the signed, notarized Wyn.dmg is published, or null while there is no
// download. Set this to the release asset URL when the DMG goes up.
export const DOWNLOAD_URL = null;

// GPL-3 §6(d): offering the source from the same place as the binary is what
// makes distributing the binary lawful. These two are rendered together, and
// `downloadOffersSource` in the tests holds that: no page may print
// DOWNLOAD_URL without SOURCE_URL beside it.
export const SOURCE_URL = "https://github.com/JellyBean47/wyn";

function layout({ title, description, path, body }) {
  const pageTitle = title ? `${title} · Wyn` : "Wyn — Windows games on Mac";
  const supportNav = SUPPORT_PAGE_ENABLED
    ? `
      <a href="/support"${path === "/support" ? ' aria-current="page"' : ""}>Support</a>`
    : "";
  const supportFooter = SUPPORT_PAGE_ENABLED
    ? ` · <a href="/support">Support Wyn</a>`
    : "";
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(pageTitle)}</title>
  <meta name="description" content="${escapeHtml(description ?? "Wyn compatibility catalog. Profiles a person or an agent can actually apply.")}">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <a class="skip" href="#main">Skip to content</a>
  <header class="top">
    <a class="mark" href="/"><img class="mark-icon" src="/favicon.svg" width="32" height="32" alt="">Wyn</a>
    <nav>
      <a href="/games"${path.startsWith("/games") ? ' aria-current="page"' : ""}>Games</a>
      <a href="/submit"${path === "/submit" ? ' aria-current="page"' : ""}>Submit</a>${supportNav}
      <a href="/api"${path === "/api" ? ' aria-current="page"' : ""}>API</a>
    </nav>
  </header>
  <main id="main">${body}</main>
  <footer>
    <p>Wyn runs Windows games on macOS through Wine. Profiles here are the launch settings that actually get used — layer, DLLs, arguments — not a star rating.</p>
    <p>Built for the Wyn community. <a href="https://github.com/JellyBean47/wyn">Source</a>${supportFooter} · GPL-3.0-or-later.</p>
  </footer>
  <script src="/client.js" type="module"></script>
</body>
</html>`;
}

function gameCards(games) {
  if (!games.length) return "";
  return `
      <ul class="cards">
        ${games.map((game) => `
          <li>
            <a href="/games/${escapeHtml(game.slug)}">
              <span class="badge ${escapeHtml(game.status)}">${statusLabel(game.status)}</span>
              <strong>${escapeHtml(game.name)}</strong>
              <span>${escapeHtml(game.publisher ?? "")}</span>
            </a>
          </li>`).join("")}
      </ul>`;
}

export function homePage(data) {
  const verified = data.games.filter((g) => g.status === "verified");
  const launched = data.games.filter((g) => g.status === "launched");
  const body = `
    <section class="hero">
      <p class="kicker">Compatibility catalog</p>
      <h1>Windows games. Mac settings. Shared progress.</h1>
      <p class="lede">Find launch settings for Windows games on your Mac. See what has actually been tested, download a profile, and share the settings that worked for you. Wyn is free software under GPL-3.0. ${
        DOWNLOAD_URL
          ? `<a href="${escapeHtml(DOWNLOAD_URL)}">Download Wyn.dmg</a> — signed and notarized, with the <a href="${escapeHtml(SOURCE_URL)}">source</a>.`
          : `A signed Mac download is coming; until then the <a href="${escapeHtml(SOURCE_URL)}">source install</a> is the supported path.`
      }${SUPPORT_PAGE_ENABLED ? ' <a href="/support">Support testing</a>.' : ""}</p>
      <form class="search" action="/games" method="get">
        <label class="sr-only" for="q">Search games</label>
        <input id="q" name="q" type="search" placeholder="Satisfactory, Solarpunk, Steam app id…" autocomplete="off">
        <button type="submit">Search</button>
      </form>
      <dl class="stats">
        <div><dt>Games</dt><dd>${data.counts.games}</dd></div>
        <div><dt>Verified</dt><dd>${data.counts.verified}</dd></div>
        <div><dt>Launched</dt><dd>${data.counts.launched}</dd></div>
        <div><dt>Guessed</dt><dd>${data.counts.guessed}</dd></div>
      </dl>
    </section>
    <section class="contribute-banner">
      <div><p class="kicker">Make the next launch easier</p><h2>Got a game running?</h2><p>Share your profile and what you tested. Every contribution is reviewed before it joins the catalog.</p></div>
      <a class="btn" href="/submit">Contribute a profile</a>
    </section>
    <section>
      <h2>Know what has been tested</h2>
      <p><strong>Launched</strong> means the game ran on a Mac and notes say what was seen. It is not a promise of a complete playthrough, and older launches were on the previous Wine tree.</p>
      <p>Most shipped profiles are <strong>guessed</strong>: written from the install layout, never launched. A guessed profile is still useful as a starting point. It is not evidence the game runs. Only <strong>verified</strong> means someone measured a loaded map on the current Wyn stack and wrote it down.</p>
      ${verified.length ? gameCards(verified) : "<p>No verified titles yet.</p>"}
      ${launched.length ? `<h3>Launched</h3>${gameCards(launched)}` : ""}
    </section>
    <section class="split">
      <div>
        <h2>For people</h2>
        <p>Open a game. Read the bottle settings, environment, and notes. If you get a title to a loaded map, upload the JSON so the next person does not start from a guess.</p>
        <p><a class="btn" href="/games">Browse ${data.counts.games} games</a></p>
      </div>
      <div>
        <h2>For agents</h2>
        <p>Stable JSON. No HTML scraping. <code>GET /api/v1/games/{slug}.json</code> returns every profile for that title. <code>GET /llms.txt</code> is the map.</p>
        <p><a class="btn ghost" href="/api">API</a></p>
      </div>
    </section>
  `;
  return layout({
    title: "",
    path: "/",
    description: "Wyn compatibility catalog: Windows games on Mac, with downloadable JSON profiles.",
    body,
  });
}

export function gamesPage(games, query) {
  const q = query.q ?? "";
  const status = query.status ?? "";
  const layer = query.layer ?? "";
  const rows = games.map((game) => `
    <tr data-profiles="${escapeHtml(game.profiles.map(p => p.id).join(" "))}" data-layers="${escapeHtml(game.profiles.map(p => p.bottle?.translationLayer).filter(Boolean).join(" "))}" data-name="${escapeHtml(game.name.toLowerCase())}" data-slug="${escapeHtml(game.slug)}" data-status="${escapeHtml(game.status)}" data-layer="${escapeHtml(game.translationLayer ?? "")}" data-publisher="${escapeHtml((game.publisher ?? "").toLowerCase())}" data-steam="${escapeHtml(game.steamAppId ?? "")}">
      <td><a href="/games/${escapeHtml(game.slug)}">${escapeHtml(game.name)}</a></td>
      <td>${escapeHtml(game.publisher ?? "—")}</td>
      <td><span class="badge ${escapeHtml(game.status)}">${statusLabel(game.status)}</span></td>
      <td>${escapeHtml([...new Set(game.profiles.map(p => layerLabel(p.bottle?.translationLayer)))].join(", ") || "—")}</td>
      <td class="mono">${game.steamAppId ? escapeHtml(String(game.steamAppId)) : "—"}</td>
    </tr>`).join("");

  const body = `
    <header class="page">
      <h1>Games</h1>
      <p>Find a starting point for your game. Status reflects the best-tested profile; open a game to check each variant and its notes.</p>
    </header>
    <form class="filters" action="/games" method="get" id="filters">
      <label class="sr-only" for="games-q">Filter</label>
      <input id="games-q" name="q" type="search" value="${escapeHtml(q)}" placeholder="Name, slug, publisher, Steam id" autocomplete="off">
      <select name="status" aria-label="Status">
        <option value="">Any status</option>
        <option value="verified"${status === "verified" ? " selected" : ""}>Verified</option>
        <option value="launched"${status === "launched" ? " selected" : ""}>Launched</option>
        <option value="guessed"${status === "guessed" ? " selected" : ""}>Guessed</option>
      </select>
      <select name="layer" aria-label="Translation layer">
        <option value="">Any layer</option>
        <option value="d3dmetal"${layer === "d3dmetal" ? " selected" : ""}>D3DMetal</option>
        <option value="dxvk"${layer === "dxvk" ? " selected" : ""}>DXVK</option>
        <option value="dxmt"${layer === "dxmt" ? " selected" : ""}>DXMT</option>
      </select>
      <button type="submit">Filter</button>
    </form>
    <p id="result-count" class="hint" role="status">${games.length} games</p>
    <p id="no-results" class="notice" hidden>No games match these filters. <a href="/games">Clear filters</a> or <a href="/submit">contribute a missing game</a>.</p>
    <noscript><p class="notice">Enable JavaScript to search and filter this catalog. All games are listed below.</p></noscript>
    <div class="table-wrap">
      <table class="games">
        <thead>
          <tr>
            <th>Game</th>
            <th>Publisher</th>
            <th>Status</th>
            <th>Layer</th>
            <th>Steam</th>
          </tr>
        </thead>
        <tbody id="game-rows">
          ${rows}
        </tbody>
      </table>
    </div>
  `;
  return layout({
    title: "Games",
    path: "/games",
    description: "Search Wyn game compatibility profiles.",
    body,
  });
}

function dlRow(term, value) {
  if (value == null || value === "" || (Array.isArray(value) && value.length === 0)) return "";
  const display = Array.isArray(value) ? value.map(escapeHtml).join(", ") : escapeHtml(String(value));
  return `<div><dt>${escapeHtml(term)}</dt><dd>${display}</dd></div>`;
}

function profileSection(profile, slug) {
  const bottle = profile.bottle ?? {};
  const env = profile.environment ?? {};
  const envRows = Object.entries(env)
    .map(([k, v]) => `<tr><th><code>${escapeHtml(k)}</code></th><td><code>${escapeHtml(v)}</code></td></tr>`)
    .join("");
  return `
    <article class="profile" id="${escapeHtml(profile.id)}">
      <header>
        <h2><code>${escapeHtml(profile.id)}</code></h2>
        <span class="badge ${escapeHtml(profile.status)}">${statusLabel(profile.status)}</span>
        <a class="btn ghost small" href="/api/v1/profiles/${escapeHtml(profile.id)}.json" download="${escapeHtml(profile.id)}.json">Download JSON</a>
        <a class="btn ghost small" href="/submit?profile=${encodeURIComponent(profile.id)}">Improve this profile</a>
      </header>
      <dl class="facts">
        ${dlRow("Layer", layerLabel(bottle.translationLayer))}
        ${dlRow("Windows", bottle.windowsVersion)}
        ${dlRow("Sync", bottle.enhancedSync)}
        ${dlRow("DXVK", bottle.dxvk == null ? null : String(bottle.dxvk))}
        ${dlRow("AVX", bottle.avxEnabled == null ? null : String(bottle.avxEnabled))}
        ${dlRow("Executables", profile.exePatterns)}
        ${dlRow("Winetricks", profile.winetricks)}
        ${dlRow("Launch args", profile.launchArgs)}
        ${dlRow("Unreal project", profile.unrealProject)}
      </dl>
      ${profile.notes ? `<div class="notes"><h3>Notes</h3><p>${escapeHtml(profile.notes)}</p></div>` : ""}
      ${envRows ? `<h3>Environment</h3><div class="table-wrap"><table class="kv"><tbody>${envRows}</tbody></table></div>` : ""}
      <p class="agent-hint">Agents: <code>GET /api/v1/profiles/${escapeHtml(profile.id)}.json</code> or <code>GET /api/v1/games/${escapeHtml(slug)}.json</code>.</p>
    </article>
  `;
}

export function gamePage(game) {
  const steam = game.steamAppId
    ? `<a href="https://store.steampowered.com/app/${escapeHtml(String(game.steamAppId))}">${escapeHtml(String(game.steamAppId))}</a>`
    : "—";
  const body = `
    <header class="page">
      <p class="kicker"><a href="/games">Games</a></p>
      <h1>${escapeHtml(game.name)}</h1>
      <p>${escapeHtml(game.publisher ?? "")}${game.publisher ? " · " : ""}Steam ${steam} · <span class="badge ${escapeHtml(game.status)}">${statusLabel(game.status)}</span></p>
    </header>
    <p class="notice">${game.status === "guessed" ? "This game has no tested profile yet. These settings are a starting point, not evidence that it runs." : game.status === "launched" ? "This title launched on a Mac. Notes say what was seen. That is not verified: verified needs a loaded-map measurement on the current Wyn stack." : "Results depend on your Mac, macOS, Wyn version, and game version. Read each profile’s notes before using it."}</p>
    <details class="guide"><summary>How to use or share a profile</summary><p>Download the JSON to keep a copy of the launch settings. Your Wyn agent can inspect it and apply the profile. Test it on your Mac before treating it as compatible.</p><p>To contribute an improvement, choose “Improve this profile”, update the settings and notes, then submit for review. Uploading here does not change your installed Wyn profiles.</p></details>
    ${game.profiles.map((p) => profileSection(p, game.slug)).join("")}
  `;
  return layout({
    title: game.name,
    path: `/games/${game.slug}`,
    description: `${game.name} on Wyn: ${statusLabel(game.status)} profile${game.profiles.length === 1 ? "" : "s"}.`,
    body,
  });
}

export function submitPage() {
  const sample = `{
  "id": "example-game",
  "name": "Example Game",
  "publisher": "Example Studio",
  "exePatterns": ["game-win64-shipping.exe", "game.exe"],
  "bottle": {
    "windowsVersion": "win10",
    "translationLayer": "d3dmetal",
    "dxvk": false,
    "dxvkAsync": false,
    "enhancedSync": "msync",
    "avxEnabled": false,
    "metalHud": false
  },
  "environment": {
    "WINEDLLOVERRIDES": "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b",
    "MTL_HUD_ENABLED": "0",
    "D3DM_ENABLE_METALFX": "0",
    "D3DM_ENABLE_ASYNC_COMMIT": "0",
    "D3DM_SHOW_HUD_STATS": "0"
  },
  "winetricks": ["vcrun2019", "vcrun2022"],
  "launchArgs": "-windowed -ResX=1280 -ResY=720",
  "notes": "What you measured. Status stays guessed unless you actually launched it.",
  "status": "guessed"
}`;
  const body = `
    <header class="page">
      <h1>Submit a profile</h1>
      <p>Help someone else get their game running. Upload your Wyn profile, include what you tested, and send it for review.</p>
      <ol class="steps"><li><strong>Choose your profile</strong><span>Upload a JSON file, improve an existing profile, or start with the example.</span></li><li><strong>Describe your test</strong><span>In notes, include your Mac chip, memory, macOS and Wyn versions, game version, settings, and results.</span></li><li><strong>Send for review</strong><span>You get a receipt. A maintainer checks the profile before adding it to the public catalog.</span></li></ol>
      <details class="guide"><summary>Where do I find my profile?</summary><p>In Finder, choose Go → Go to Folder and enter <code>~/Library/Application Support/com.fly.gaming/Profiles</code> to find profiles you added with Wyn. If your profile is not there, ask your Wyn agent to export it as JSON. You can also <a href="/games">find your game</a> and choose “Improve this profile”. Submit settings and notes only; game files and diagnostic archives are not accepted.</p></details>
    </header>
    <p id="upload-status" class="notice" role="status">Checking upload availability…</p>
    <noscript><p class="notice">Enable JavaScript to validate and upload profiles.</p></noscript>
    <form id="submit-form" class="submit" action="/api/v1/submit" method="post">
      <label class="drop" for="file">
        <input id="file" name="file" type="file" accept="application/json,.json">
        <span>Drop a <code>.json</code> profile here, or click to choose.</span>
      </label>
      <p id="file-name" class="hint">One .json file, up to 256 KB. You can also paste below.</p>
      <div class="actions"><button type="button" id="use-example" class="ghost">Use example</button><button type="button" id="download-draft" class="ghost">Download draft</button></div>
      <template id="sample-profile">${escapeHtml(sample)}</template>
      <label for="payload">Profile JSON</label>
      <textarea id="payload" name="payload" rows="16" spellcheck="false" placeholder="Paste your profile JSON here…" required aria-describedby="profile-hint"></textarea>
      <p class="hint" id="profile-hint">Do not mark <code>verified</code> unless <code>notes</code> say what was measured. Leave MetalFX and the Metal HUD off unless you measured them on.</p>
      <label class="consent"><input type="checkbox" id="consent" required> <span>I’m sharing this profile for review and possible public inclusion in Wyn under GPL-3.0-or-later. I have removed private paths, account details, and secrets.</span></label>
      <div id="submit-result" role="status" aria-live="polite" tabindex="-1"></div>
      <div class="actions"><button type="button" id="validate-profile" class="ghost">Check profile</button><button type="submit" id="send-profile" disabled>Submit for review</button></div>
    </form>
  `;
  return layout({
    title: "Submit",
    path: "/submit",
    description: "Upload a Wyn game profile JSON.",
    body,
  });
}

export function supportPage(data) {
  const verified = data?.counts?.verified ?? 0;
  const guessed = data?.counts?.guessed ?? 0;
  const games = data?.counts?.games ?? 0;
  const body = `
    <header class="page">
      <h1>Support Wyn</h1>
      <p>Wyn is free and open source. If it saved you from buying another Wine wrapper or spending hours on a prefix, help keep game testing going. There is no paywall and no crippled free app.</p>
    </header>
    <section>
      <h2>Sponsor</h2>
      <p>GitHub Sponsors is the funding link. Money pays for machines, game copies, and time on the catalog — not a licence to run Wyn.</p>
      <p><a class="btn" href="https://github.com/sponsors/JellyBean47">Sponsor on GitHub</a></p>
      <p class="hint">If GitHub still asks the maintainer to finish Sponsors setup, that page is the prompt. The same link lives on the <a href="https://github.com/JellyBean47/wyn">repository</a>.</p>
    </section>
    <section>
      <h2>Verified is not guessed</h2>
      <p>The catalog currently lists <strong>${games} games</strong>, <strong>${verified} verified</strong>, <strong>${data?.counts?.launched ?? 0} launched</strong>, <strong>${guessed} guessed</strong>. A guessed profile is a starting point written from the install layout. It is not evidence the game runs. Launched means it ran and notes say what was seen. Verified means someone measured a loaded map on the current Wyn stack and wrote it down.</p>
      <p>Do not treat a guessed Elden Ring page as a review. Prefer <a href="/games?status=verified">verified titles</a>. If you get a guessed game to a loaded map, <a href="/submit">submit the JSON</a>.</p>
    </section>
    <section>
      <h2>Install</h2>
      ${
        DOWNLOAD_URL
          ? `<p><a class="btn" href="${escapeHtml(DOWNLOAD_URL)}">Download Wyn.dmg</a> — signed and notarized. Drag it to Applications and open it; the app downloads a hash-pinned Wine runtime on first launch.</p>
      <p>You need an Apple Silicon Mac and <strong>Rosetta 2</strong> — Wine's unix half is x86_64. If you do not have it: <code>softwareupdate --install-rosetta --agree-to-license</code>.</p>
      <p>Wyn is free software under <a href="${escapeHtml(SOURCE_URL)}/blob/main/LICENSE">GPL-3.0-or-later</a>, and you are entitled to the source for the build you just downloaded: <a href="${escapeHtml(SOURCE_URL)}">${escapeHtml(SOURCE_URL)}</a>. Or build it yourself:</p>`
          : `<p>A signed, notarized <code>Wyn.dmg</code> (drag to Applications, then set up Wine in the app) is the download we want. It is not published yet. Until then, build from source — Wyn is free software under <a href="${escapeHtml(SOURCE_URL)}/blob/main/LICENSE">GPL-3.0-or-later</a>:</p>`
      }
      <pre><code>git clone ${escapeHtml(SOURCE_URL)}.git
cd wyn
./install.sh
open /Applications/Wyn.app</code></pre>
      <p>That needs an Apple Silicon Mac, Xcode 16+, and Rosetta. Wyn downloads a hash-pinned Wine runtime; it does not ship Apple GPTK.</p>
      <h3>Which renderer you get</h3>
      <p>The download gives you <strong>DXMT</strong> — Direct3D 11 to Metal. That is the default renderer, it needs no compiler, and it is what every verified title here was measured on unless its page says otherwise.</p>
      <p><strong>D3DMetal is not in the download, and cannot be.</strong> It comes from Apple's Game Porting Toolkit, whose licence forbids redistribution, so Wyn never ships it and never downloads it. It is an opt-in upgrade for Direct3D 12-only titles, it needs the source install, and you supply Apple's GPTK yourself:</p>
      <pre><code>./install.sh --with-d3dmetal --accept-gptk-licence</code></pre>
      <p>That path compiles Wine from source, so it also wants <code>brew install ccache mingw-w64</code>. If a game's page lists its layer as <code>d3dmetal</code>, the download alone will not run it.</p>
    </section>
    <section>
      <h2>If you post about a game</h2>
      <p>Link a <strong>verified</strong> page, not a launch announcement. Examples: <a href="/games/solarpunk">Solarpunk</a>, <a href="/games/satisfactory">Satisfactory</a>. Say when a profile is still guessed.</p>
    </section>
  `;
  return layout({
    title: "Support",
    path: "/support",
    description: "Wyn is free. Sponsor testing, read verified vs guessed, and install from source until the signed DMG exists.",
    body,
  });
}

export function apiPage() {
  const body = `
    <header class="page">
      <h1>API</h1>
      <p>The same game settings used by the website, available as JSON for Wyn, apps, and agents. Public catalog reads support CORS.</p>
    </header>
    <div class="table-wrap">
      <table class="kv">
        <tbody>
          <tr><th><code>GET /api/v1/catalog.json</code></th><td>Index of every game, with hrefs</td></tr>
          <tr><th><code>GET /api/v1/games.json</code></th><td>Full catalog with nested profiles</td></tr>
          <tr><th><code>GET /api/v1/games/{slug}.json</code></th><td>One game and all its profile variants</td></tr>
          <tr><th><code>GET /api/v1/profiles/{id}.json</code></th><td>Raw Wyn profile (same schema as the repo)</td></tr>
          <tr><th><code>GET /api/v1/steam/{appId}.json</code></th><td>Lookup by Steam app id</td></tr>
          <tr><th><code>POST /api/v1/submit</code></th><td>Body: a profile object (application/json, max 256 KB). Valid profiles return 201 with a receipt and wait for review. Errors: 400 malformed JSON, 413 too large, 415 content type, 422 validation, 429 rate limit, 503 unavailable.</td></tr>
          <tr><th><code>GET /api/v1/submit</code></th><td>Upload availability, mode (local or review), and size limit</td></tr>
          <tr><th><code>GET /llms.txt</code></th><td>Short map for agents</td></tr>
        </tbody>
      </table>
    </div>
    <h2>Example</h2>
    <pre><code>curl -s https://wyn-dev.com/api/v1/games/solarpunk.json
curl -s https://wyn-dev.com/api/v1/steam/1805110.json</code></pre>
  `;
  return layout({
    title: "API",
    path: "/api",
    description: "Wyn compatibility JSON API for apps and agents.",
    body,
  });
}

export function notFoundPage(message) {
  return layout({
    title: "Not found",
    path: "/404",
    description: "Page not found.",
    body: `<header class="page"><h1>Not found</h1><p>${escapeHtml(message ?? "No such page.")}</p><p><a href="/games">Back to games</a></p></header>`,
  });
}

export function errorPage(message) {
  return layout({
    title: "Error",
    path: "/500",
    description: "Server error.",
    body: `<header class="page"><h1>Something broke</h1><p>${escapeHtml(message)}</p></header>`,
  });
}
