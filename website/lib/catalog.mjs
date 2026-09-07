//
//  catalog.mjs
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//

import fs from "node:fs";
import path from "node:path";

const STATUS_RANK = { verified: 3, launched: 2, guessed: 1 };

export function resourceRoots(repoRoot) {
  const resources = path.join(
    repoRoot,
    "WynKit",
    "Sources",
    "WynKit",
    "Resources",
  );
  return {
    catalogPath: path.join(resources, "Catalog", "game-catalog.json"),
    profilesDir: path.join(resources, "Profiles"),
  };
}

export function loadCatalog(repoRoot) {
  const { catalogPath, profilesDir } = resourceRoots(repoRoot);
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const profilesById = new Map();
  const missingProfiles = [];

  for (const file of fs.readdirSync(profilesDir)) {
    if (!file.endsWith(".json")) continue;
    const full = path.join(profilesDir, file);
    const profile = JSON.parse(fs.readFileSync(full, "utf8"));
    const id = typeof profile.id === "string" ? profile.id : file.replace(/\.json$/, "");
    profilesById.set(id, {
      ...profile,
      id,
      status: profile.status ?? "guessed",
      filename: file,
    });
  }

  const games = catalog.games.map((entry) => {
    const profiles = [];
    for (const filename of entry.profiles ?? []) {
      const id = filename.replace(/\.json$/, "");
      const profile = profilesById.get(id);
      if (!profile) {
        missingProfiles.push({ slug: entry.slug, filename });
        continue;
      }
      profiles.push(profile);
    }
    const status = bestStatus(profiles);
    const primary = profiles[0] ?? null;
    return {
      slug: entry.slug,
      name: entry.name,
      publisher: entry.publisher ?? null,
      steamAppId: entry.steamAppId ?? null,
      epicId: entry.epicId ?? null,
      gogId: entry.gogId ?? null,
      batch: entry.batch,
      profileFilenames: entry.profiles ?? [],
      profiles,
      status,
      translationLayer: primary?.bottle?.translationLayer ?? null,
      winetricks: primary?.winetricks ?? [],
    };
  });

  games.sort((a, b) => a.name.localeCompare(b.name));

  const bySlug = new Map(games.map((game) => [game.slug, game]));
  const bySteam = new Map();
  for (const game of games) {
    if (game.steamAppId) bySteam.set(String(game.steamAppId), game);
  }

  const counts = { games: games.length, profiles: profilesById.size, verified: 0, launched: 0, guessed: 0 };
  for (const game of games) {
    counts[game.status] = (counts[game.status] ?? 0) + 1;
  }

  return {
    schemaVersion: catalog.schemaVersion,
    games,
    bySlug,
    bySteam,
    profilesById,
    missingProfiles,
    counts,
  };
}

export function bestStatus(profiles) {
  let best = "guessed";
  for (const profile of profiles) {
    const status = profile.status ?? "guessed";
    if ((STATUS_RANK[status] ?? 0) > (STATUS_RANK[best] ?? 0)) best = status;
  }
  return best;
}

export function filterGames(games, { q, status, layer } = {}) {
  const needle = (q ?? "").trim().toLowerCase();
  return games.filter((game) => {
    if (status && game.status !== status) return false;
    if (layer && !game.profiles.some(p => p.bottle?.translationLayer === layer)) return false;
    if (!needle) return true;
    const hay = [
      game.name,
      game.slug,
      game.publisher,
      game.steamAppId,
      ...game.profiles.map((p) => p.id),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    return hay.includes(needle);
  });
}

export function gameApiPayload(game) {
  return {
    slug: game.slug,
    name: game.name,
    publisher: game.publisher,
    steamAppId: game.steamAppId,
    epicId: game.epicId,
    gogId: game.gogId,
    status: game.status,
    translationLayer: game.translationLayer,
    profiles: game.profiles.map(profileApiPayload),
    json: game.profiles.map((p) => `/api/v1/profiles/${p.id}.json`),
  };
}

export function profileApiPayload(profile) {
  const { filename, href, ...rest } = profile;
  return rest;
}

export function catalogIndex(data) {
  return {
    schemaVersion: data.schemaVersion,
    generatedAt: new Date().toISOString(),
    counts: data.counts,
    endpoints: {
      games: "/api/v1/games.json",
      game: "/api/v1/games/{slug}.json",
      profile: "/api/v1/profiles/{id}.json",
      steam: "/api/v1/steam/{appId}.json",
      submit: "POST /api/v1/submit",
    },
    games: data.games.map((game) => ({
      slug: game.slug,
      name: game.name,
      publisher: game.publisher,
      steamAppId: game.steamAppId,
      status: game.status,
      translationLayer: game.translationLayer,
      profiles: game.profiles.map((p) => p.id),
      href: `/api/v1/games/${game.slug}.json`,
    })),
  };
}
