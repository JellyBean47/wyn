//
//  validate.mjs
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the
//  terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//
//  A JS subset of ProfileValidator. Errors reject a submission; warnings
//  still save. Keep this conservative: a guessed profile must not turn on
//  settings that were measured to break a real game.
//

const STATUSES = new Set(["guessed", "launched", "verified"]);
const LAYERS = new Set(["d3dmetal", "dxvk", "dxmt"]);
const DEBUG_OVERLAY = ["MTL_HUD_ENABLED", "D3DM_SHOW_HUD_STATS"];
const MEASURED_RISK = ["D3DM_ENABLE_METALFX", "D3DM_ENABLE_ASYNC_COMMIT"];
const BANNED = [
  "-execcmds",
  "xinput1_3=d",
  "xinput9_1_0=d",
  "fg.inputmode",
  "forcemouse",
  "wineserver -k",
  "wineboot -u",
];
const D3D_NAMES = new Set(["d3d11", "d3d10core", "d3d12", "dxgi"]);

function isTruthy(value) {
  if (value == null) return false;
  return ["1", "true", "yes", "on"].includes(String(value).trim().toLowerCase());
}

function isVulkanNative(profile) {
  const env = profile.environment ?? {};
  if (Object.keys(env).some((key) => key.startsWith("MVK_"))) return true;
  return String(env.WINEDLLOVERRIDES ?? "").toLowerCase().includes("vulkan-1");
}

export function slugFromId(id) {
  return String(id ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function validateProfile(profile) {
  const findings = [];
  const fail = (rule, severity, message) => {
    findings.push({ rule, severity, message });
  };

  if (!profile || typeof profile !== "object" || Array.isArray(profile)) {
    return [{ rule: "shape", severity: "error", message: "body must be a JSON object" }];
  }

  const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  for (const field of ["id", "name", "status", "publisher", "launchArgs", "unrealProject", "notes"]) {
    if (profile[field] != null && typeof profile[field] !== "string") fail("shape", "error", `${field} must be text`);
  }
  for (const field of ["exePatterns", "winetricks"]) {
    if (profile[field] != null && (!Array.isArray(profile[field]) || profile[field].some(v => typeof v !== "string" || !v.trim()))) {
      fail("shape", "error", `${field} must be an array of nonempty strings`);
    }
  }
  if (profile.environment != null && (!object(profile.environment) || Object.values(profile.environment).some(v => typeof v !== "string"))) {
    fail("shape", "error", "environment must be an object with string values, such as \"MTL_HUD_ENABLED\": \"0\"");
  }
  if (profile.bottle != null && !object(profile.bottle)) fail("shape", "error", "bottle must be an object");
  if (object(profile.bottle)) {
    for (const field of ["dxvk", "dxvkAsync", "dxrEnabled", "avxEnabled", "metalHud"]) {
      if (profile.bottle[field] != null && typeof profile.bottle[field] !== "boolean") fail("shape", "error", `bottle.${field} must be true or false`);
    }
    for (const [field, values] of Object.entries({ windowsVersion: ["winxp64", "win7", "win8", "win81", "win10", "win11"], enhancedSync: ["none", "esync", "msync"] })) {
      if (profile.bottle[field] != null && !values.includes(profile.bottle[field])) fail("shape", "error", `bottle.${field} must be one of: ${values.join(", ")}`);
    }
  }
  if (profile.requiresUbisoftConnect != null && typeof profile.requiresUbisoftConnect !== "boolean") fail("shape", "error", "requiresUbisoftConnect must be true or false");
  if (profile.assettoCorsa != null) {
    const session = profile.assettoCorsa;
    if (!object(session)) fail("shape", "error", "assettoCorsa must be an object");
    else {
      for (const field of ["track", "car"]) if (typeof session[field] !== "string" || !session[field].trim()) fail("shape", "error", `assettoCorsa.${field} must be nonempty text`);
      if (session.layout != null && typeof session.layout !== "string") fail("shape", "error", "assettoCorsa.layout must be text");
      if (!Number.isSafeInteger(session.aiCount) || session.aiCount < 0) fail("shape", "error", "assettoCorsa.aiCount must be a nonnegative integer");
      if (session.aiAggression != null && (!Number.isInteger(session.aiAggression) || session.aiAggression < 0 || session.aiAggression > 100)) fail("shape", "error", "assettoCorsa.aiAggression must be an integer from 0 to 100");
    }
  }
  // Reject malformed shapes before inspecting their values.
  if (errorsIn(findings).length) return findings;

  const id = typeof profile.id === "string" ? profile.id.trim() : "";
  const name = typeof profile.name === "string" ? profile.name.trim() : "";
  const status = profile.status ?? "guessed";
  const exePatterns = Array.isArray(profile.exePatterns) ? profile.exePatterns : [];
  const env = profile.environment && typeof profile.environment === "object"
    ? profile.environment
    : {};
  const bottle = profile.bottle && typeof profile.bottle === "object" ? profile.bottle : {};

  if (id.length > 100) fail("idShape", "error", "id must be 100 characters or fewer");
  if (!id) fail("requiredFields", "error", "id is empty");
  else if (slugFromId(id) !== id) {
    fail("idShape", "error", "id must be lowercase letters, numbers, and hyphens");
  }
  if (!name) fail("requiredFields", "error", "name is empty");
  if (!STATUSES.has(status)) {
    fail("status", "error", `status must be guessed, launched, or verified (got ${status})`);
  }
  if (exePatterns.length === 0) {
    fail("requiredFields", "error", "no exePatterns — nothing can ever match this profile");
  }
  for (const pattern of exePatterns) {
    if (typeof pattern !== "string" || !pattern.toLowerCase().endsWith(".exe")) {
      fail("exePatternShape", "warning", `exe pattern "${pattern}" does not end in .exe`);
    }
  }
  if (profile.steamAppId != null) {
    const appId = profile.steamAppId;
    if (!Number.isSafeInteger(appId) || appId <= 0) {
      fail("requiredFields", "error", `steamAppId ${profile.steamAppId} is not a Steam app id`);
    }
  }
  if (bottle.translationLayer != null && !LAYERS.has(bottle.translationLayer)) {
    fail(
      "layer",
      "error",
      `translationLayer must be d3dmetal, dxvk, or dxmt (got ${bottle.translationLayer})`,
    );
  }

  for (const key of DEBUG_OVERLAY) {
    if (isTruthy(env[key])) {
      fail(
        "debugOverlayOff",
        status === "verified" ? "warning" : "error",
        `${key}=${env[key]} draws a developer overlay over the game`,
      );
    }
  }
  if (bottle.metalHud === true) {
    fail(
      "debugOverlayOff",
      status === "verified" ? "warning" : "error",
      "metalHud draws Metal's stat overlay over the game",
    );
  }

  for (const key of MEASURED_RISK) {
    if (isTruthy(env[key]) && status !== "verified") {
      fail(
        "unmeasuredRiskSetting",
        "error",
        `${key}=1 on a profile that has not been verified. Leave it "0" until a real launch says otherwise.`,
      );
    }
  }

  const haystack = `${profile.launchArgs ?? ""} ${Object.values(env).join(" ")}`.toLowerCase();
  for (const banned of BANNED) {
    if (haystack.includes(banned)) {
      fail("bannedSetting", "error", `contains "${banned}", which Wyn forbids`);
    }
  }

  const layer = bottle.translationLayer;
  if (layer === "dxvk" && bottle.dxvk === false && !isVulkanNative({ environment: env })) {
    fail(
      "layerCoherence",
      "error",
      "translationLayer is dxvk but dxvk is false, and nothing says this game speaks Vulkan natively",
    );
  }
  if (layer === "d3dmetal" && bottle.dxvk === true) {
    fail("layerCoherence", "error", "translationLayer is d3dmetal but dxvk is true");
  }

  if (layer === "d3dmetal" && typeof env.WINEDLLOVERRIDES === "string") {
    for (const clause of env.WINEDLLOVERRIDES.split(";")) {
      const eq = clause.indexOf("=");
      if (eq < 0) continue;
      const names = clause.slice(0, eq);
      const mode = clause.slice(eq + 1);
      if (!mode.toLowerCase().startsWith("n")) continue;
      const clashing = (names ?? "")
        .toLowerCase()
        .split(",")
        .map((n) => n.trim())
        .filter((n) => D3D_NAMES.has(n));
      if (clashing.length) {
        fail(
          "nativeFirstD3DOverride",
          "error",
          `WINEDLLOVERRIDES sets ${clashing.join(", ")} to "${mode}" (native first) on a D3DMetal profile. These must be builtin ("b").`,
        );
      }
    }
  }

  if (status === "verified" && !String(profile.notes ?? "").trim()) {
    fail("verifiedNeedsEvidence", "error", "claims to be verified but has no notes saying what was measured");
  }

  return findings;
}

export function errorsIn(findings) {
  return findings.filter((f) => f.severity === "error");
}
