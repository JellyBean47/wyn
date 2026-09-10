//
//  server.mjs
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//
//  Local wyn-dev.com. Reads the live WynKit catalog; does not copy those files.
//  npm start → http://127.0.0.1:3000
//

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  catalogIndex,
  filterGames,
  gameApiPayload,
  loadCatalog,
  profileApiPayload,
} from "./lib/catalog.mjs";
import {
  apiPage,
  errorPage,
  gamePage,
  gamesPage,
  homePage,
  notFoundPage,
  submitPage,
  SUPPORT_PAGE_ENABLED,
  supportPage,
} from "./lib/html.mjs";
import { MAX_BODY, prepareSubmission, submissionRecord } from "./lib/submission.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const publicDir = path.join(here, "public");
const submissionsDir = path.join(here, "submissions");
const PORT = Number(process.env.PORT) || 3000;
const HOST = process.env.HOST || "127.0.0.1";


const MIME = {
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
};

function send(res, status, body, headers = {}) {
  const payload = Buffer.from(body);
  res.writeHead(status, {
    "content-length": payload.length,
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    ...headers,
  });
  res.end(payload);
}

function sendHtml(res, status, html) {
  send(res, status, html, { "content-type": "text/html; charset=utf-8" });
}

function sendJson(res, status, data, extra = {}) {
  send(res, status, JSON.stringify(data, null, 2) + "\n", {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
    "cache-control": "no-store",
    ...extra,
  });
}

function parseUrl(req) {
  return new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(Object.assign(new Error("payload too large"), { status: 413 }));
        // Drain the remaining request so the client receives the 413 response.
        return;
      }
      if (size <= MAX_BODY) chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function serveStatic(res, urlPath) {
  const relative = urlPath.replace(/^\/+/, "");
  const full = path.normalize(path.join(publicDir, relative));
  if (!full.startsWith(publicDir + path.sep) && full !== publicDir) return false;
  if (!fs.existsSync(full) || !fs.statSync(full).isFile()) return false;
  const ext = path.extname(full);
  send(res, 200, fs.readFileSync(full), {
    "content-type": MIME[ext] || "application/octet-stream",
    "cache-control": "no-store",
  });
  return true;
}

function llmsTxt(origin) {
  return `# Wyn compatibility catalog

Wyn runs Windows games on macOS through Wine. A profile is the per-game
JSON Wyn launches with (executable, translation layer, environment,
arguments). Prefer these URLs over scraping HTML.

Catalog index: ${origin}/api/v1/catalog.json
All games:     ${origin}/api/v1/games.json
One game:      ${origin}/api/v1/games/{slug}.json
One profile:   ${origin}/api/v1/profiles/{id}.json
Steam app id:  ${origin}/api/v1/steam/{appId}.json
Submit:        POST ${origin}/api/v1/submit

Status values: guessed (never launched), launched (it ran), verified
(measured; notes must say what was seen). Do not treat guessed as evidence.
`;
}

async function handleSubmit(raw) {
  const parsed = prepareSubmission(raw);
  if (!parsed.profile) return parsed;
  const record = await submissionRecord(parsed.profile);
  fs.mkdirSync(submissionsDir, { recursive: true });
  const dest = path.join(submissionsDir, `${record.receipt}.json`);
  if (!fs.existsSync(dest)) fs.writeFileSync(dest, JSON.stringify(record, null, 2) + "\n");
  return { status: 201, body: { ok: true, id: parsed.profile.id, receipt: record.receipt,
    findings: parsed.findings, message: "Saved in this Mac’s local review queue. This preview does not send uploads to wyn-dev.com." } };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = parseUrl(req);
    const pathname = decodeURIComponent(url.pathname).replace(/\/$/, "") || "/";
    const origin = `${url.protocol}//${url.host}`;

    if (req.method === "OPTIONS" && pathname.startsWith("/api/")) {
      send(res, 204, "", {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, OPTIONS",
        "access-control-allow-headers": "content-type",
      });
      return;
    }

    if (req.method === "GET" && pathname === "/validate.mjs") {
      send(res, 200, fs.readFileSync(path.join(here, "lib/validate.mjs")), { "content-type": MIME[".mjs"] });
      return;
    }
    if (req.method === "GET" && pathname === "/api/v1/submit") {
      sendJson(res, 200, { available: true, mode: "local", maxBytes: MAX_BODY });
      return;
    }
    if (req.method === "GET" && serveStatic(res, pathname)) return;

    if (req.method === "GET" && pathname === "/health") {
      sendJson(res, 200, { ok: true });
      return;
    }

    if (req.method === "GET" && pathname === "/llms.txt") {
      send(res, 200, llmsTxt(origin), { "content-type": "text/plain; charset=utf-8" });
      return;
    }

    if (req.method === "POST" && pathname === "/api/v1/submit") {
      if (req.headers.origin && req.headers.origin !== origin) {
        sendJson(res, 403, { ok: false, error: "Submit from this website." }); return;
      }
      if (req.headers["content-type"]?.split(";")[0].trim() !== "application/json") {
        sendJson(res, 415, { ok: false, error: "Use Content-Type: application/json." }); return;
      }
      const raw = await readBody(req);
      const result = await handleSubmit(raw);
      sendJson(res, result.status, result.body);
      return;
    }

    const data = loadCatalog(repoRoot);

    if (req.method === "GET" && pathname === "/") {
      sendHtml(res, 200, homePage(data));
      return;
    }
    if (req.method === "GET" && pathname === "/games") {
      sendHtml(res, 200, gamesPage(data.games, Object.fromEntries(url.searchParams)));
      return;
    }
    if (req.method === "GET" && pathname.startsWith("/games/")) {
      const slug = pathname.slice("/games/".length).replace(/\/$/, "");
      const game = data.bySlug.get(slug);
      if (!game) {
        sendHtml(res, 404, notFoundPage(`No game with slug “${slug}”.`));
        return;
      }
      sendHtml(res, 200, gamePage(game));
      return;
    }
    if (req.method === "GET" && pathname === "/submit") {
      sendHtml(res, 200, submitPage());
      return;
    }
    if (SUPPORT_PAGE_ENABLED && req.method === "GET" && pathname === "/support") {
      sendHtml(res, 200, supportPage(data));
      return;
    }
    if (req.method === "GET" && (pathname === "/api" || pathname === "/api/")) {
      sendHtml(res, 200, apiPage());
      return;
    }

    if (req.method === "GET" && pathname === "/api/v1/catalog.json") {
      sendJson(res, 200, catalogIndex(data));
      return;
    }
    if (req.method === "GET" && pathname === "/api/v1/games.json") {
      sendJson(res, 200, {
        generatedAt: new Date().toISOString(),
        counts: data.counts,
        games: data.games.map(gameApiPayload),
      });
      return;
    }
    if (req.method === "GET" && pathname === "/api/v1/profiles.json") {
      sendJson(res, 200, {
        profiles: [...data.profilesById.values()].map(profileApiPayload),
      });
      return;
    }

    const gameMatch = pathname.match(/^\/api\/v1\/games\/([^/]+)\.json$/);
    if (req.method === "GET" && gameMatch) {
      const game = data.bySlug.get(gameMatch[1]);
      if (!game) {
        sendJson(res, 404, { error: "unknown slug", slug: gameMatch[1] });
        return;
      }
      sendJson(res, 200, gameApiPayload(game));
      return;
    }

    const profileMatch = pathname.match(/^\/api\/v1\/profiles\/([^/]+)\.json$/);
    if (req.method === "GET" && profileMatch) {
      const profile = data.profilesById.get(profileMatch[1]);
      if (!profile) {
        sendJson(res, 404, { error: "unknown profile", id: profileMatch[1] });
        return;
      }
      sendJson(res, 200, profileApiPayload(profile));
      return;
    }

    const steamMatch = pathname.match(/^\/api\/v1\/steam\/(\d+)\.json$/);
    if (req.method === "GET" && steamMatch) {
      const game = data.bySteam.get(steamMatch[1]);
      if (!game) {
        sendJson(res, 404, { error: "unknown steamAppId", steamAppId: Number(steamMatch[1]) });
        return;
      }
      sendJson(res, 200, gameApiPayload(game));
      return;
    }

    if (pathname.startsWith("/api/")) {
      sendJson(res, 404, { error: "unknown endpoint", path: pathname });
      return;
    }
    sendHtml(res, 404, notFoundPage());
  } catch (error) {
    const status = error.status || 500;
    if (req.url?.startsWith("/api/")) {
      sendJson(res, status, { error: error.message || "server error" });
      return;
    }
    sendHtml(res, status, errorPage(error.message || "server error"));
  }
});

fs.mkdirSync(submissionsDir, { recursive: true });

server.listen(PORT, HOST, () => {
  const data = loadCatalog(repoRoot);
  console.log(`Wyn catalog → http://${HOST}:${PORT}`);
  console.log(`${data.counts.games} games, ${data.counts.verified} verified, ${data.counts.guessed} guessed`);
  if (data.missingProfiles.length) {
    console.warn("Missing profile files:", data.missingProfiles);
  }
});
