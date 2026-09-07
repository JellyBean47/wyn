//
//  build.mjs
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//
//  Static assets for the existing Cloudflare Worker. node build.mjs → website/dist/
//

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  catalogIndex,
  gameApiPayload,
  loadCatalog,
  profileApiPayload,
} from "./lib/catalog.mjs";
import {
  apiPage,
  gamePage,
  gamesPage,
  homePage,
  notFoundPage,
  submitPage,
  supportPage,
} from "./lib/html.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const dist = path.join(here, "dist");
const publicDir = path.join(here, "public");

function write(rel, contents) {
  const full = path.join(dist, rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, contents);
}

function json(rel, data) {
  write(rel, JSON.stringify(data, null, 2) + "\n");
}

function html(rel, markup) {
  write(rel, markup);
}

const data = loadCatalog(repoRoot);
if (fs.existsSync(dist)) fs.rmSync(dist, { recursive: true });
fs.mkdirSync(dist, { recursive: true });

for (const file of fs.readdirSync(publicDir)) {
  fs.copyFileSync(path.join(publicDir, file), path.join(dist, file));
}

write("validate.mjs", fs.readFileSync(path.join(here, "lib/validate.mjs")));

html("index.html", homePage(data));
html("games/index.html", gamesPage(data.games, {}));
html("submit/index.html", submitPage());
html("support/index.html", supportPage(data));
html("api/index.html", apiPage());
html("404.html", notFoundPage());

for (const game of data.games) {
  html(`games/${game.slug}/index.html`, gamePage(game));
  json(`api/v1/games/${game.slug}.json`, gameApiPayload(game));
  if (game.steamAppId) {
    json(`api/v1/steam/${game.steamAppId}.json`, gameApiPayload(game));
  }
}

json("api/v1/catalog.json", catalogIndex(data));
json("api/v1/games.json", {
  generatedAt: new Date().toISOString(),
  counts: data.counts,
  games: data.games.map(gameApiPayload),
});
json("api/v1/profiles.json", {
  profiles: [...data.profilesById.values()].map(profileApiPayload),
});

for (const profile of data.profilesById.values()) {
  json(`api/v1/profiles/${profile.id}.json`, profileApiPayload(profile));
}

write(
  "llms.txt",
  `# Wyn compatibility catalog

Wyn runs Windows games on macOS through Wine. A profile is the per-game
JSON Wyn launches with (executable, translation layer, environment,
arguments). Prefer these URLs over scraping HTML.

Catalog index: /api/v1/catalog.json
All games:     /api/v1/games.json
One game:      /api/v1/games/{slug}.json
One profile:   /api/v1/profiles/{id}.json
Steam app id:  /api/v1/steam/{appId}.json
Submit: POST /api/v1/submit (JSON; pending review, never published automatically)
Availability: GET /api/v1/submit

Status values: guessed (never launched), launched (it ran), verified
(measured; notes must say what was seen). Do not treat guessed as evidence.
Support / sponsor: /support
Install: source until a notarized Wyn.dmg exists.
`,
);

write(
  "_headers",
  `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Content-Security-Policy: default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'
/api/*
  Access-Control-Allow-Origin: *
  Cache-Control: public, max-age=300
`,
);

console.log(
  `Wrote ${dist} — ${data.counts.games} games, ${data.counts.verified} verified`,
);
