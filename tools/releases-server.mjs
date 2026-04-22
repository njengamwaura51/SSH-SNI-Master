#!/usr/bin/env node
// tools/releases-server.mjs — zero-dependency Node HTTP server that exposes
// the SNI Hunter releases manifest. Files themselves are served by nginx
// straight off disk (the /sni-hunter/dl/ alias), so this process only ever
// reads directory listings and small .sha256 sidecars.
//
// Env vars (all optional):
//   PORT                       default 8090
//   HOST                       default 127.0.0.1
//   RELEASES_DIR               default /var/www/sni-hunter/releases
//   RELEASES_PUBLIC_BASE_URL   default https://shopthelook.page/sni-hunter
//
// Routes:
//   GET /healthz               → 200 "ok"
//   GET /api/releases          → { releases: [ {file, sizeBytes, sha256, mtime, url} ] }
//   GET /api/releases/latest   → single newest release object (or 404)

import http from "node:http";
import fs   from "node:fs/promises";
import path from "node:path";

const PORT             = Number(process.env.PORT || 8090);
const HOST             = process.env.HOST || "127.0.0.1";
const RELEASES_DIR     = process.env.RELEASES_DIR || "/var/www/sni-hunter/releases";
const PUBLIC_BASE_URL  = (process.env.RELEASES_PUBLIC_BASE_URL
                          || "https://shopthelook.page/sni-hunter").replace(/\/+$/, "");

const ARTIFACT_RE = /\.(AppImage|deb|apk|dmg|exe|msi|tar\.gz|zip)$/i;

function looksLikeArtifact(name) {
  // Reject sidecar files (.sha256), dotfiles, and anything not on the allow-list.
  if (name.startsWith(".")) return false;
  if (name.endsWith(".sha256")) return false;
  return ARTIFACT_RE.test(name);
}

async function readSidecarSha256(absPath) {
  try {
    const txt = await fs.readFile(absPath + ".sha256", "utf8");
    const m = txt.trim().match(/^[a-f0-9]{64}/i);
    return m ? m[0].toLowerCase() : null;
  } catch {
    return null;
  }
}

async function listReleases() {
  let entries;
  try {
    entries = await fs.readdir(RELEASES_DIR);
  } catch (err) {
    if (err.code === "ENOENT") return [];
    throw err;
  }

  const out = [];
  for (const name of entries) {
    if (!looksLikeArtifact(name)) continue;
    const abs = path.join(RELEASES_DIR, name);
    let stat;
    try { stat = await fs.stat(abs); } catch { continue; }
    if (!stat.isFile()) continue;
    out.push({
      file:      name,
      sizeBytes: stat.size,
      mtime:     stat.mtime.toISOString(),
      sha256:    await readSidecarSha256(abs),
      url:       `${PUBLIC_BASE_URL}/dl/${encodeURIComponent(name)}`,
    });
  }
  // Newest first.
  out.sort((a, b) => b.mtime.localeCompare(a.mtime));
  return out;
}

function sendJson(res, status, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "content-type":          "application/json; charset=utf-8",
    "content-length":        buf.length,
    "cache-control":         "public, max-age=60",
    "x-content-type-options": "nosniff",
  });
  res.end(buf);
}

const server = http.createServer(async (req, res) => {
  // Ignore everything that isn't a plain GET.
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { allow: "GET, HEAD" });
    return res.end();
  }

  // Strip query string + normalise.
  const url = new URL(req.url, "http://x");
  const p   = url.pathname.replace(/\/+$/, "") || "/";

  try {
    if (p === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("ok\n");
    }
    if (p === "/api/releases") {
      return sendJson(res, 200, { releases: await listReleases() });
    }
    if (p === "/api/releases/latest") {
      const list = await listReleases();
      if (list.length === 0) return sendJson(res, 404, { error: "no releases" });
      return sendJson(res, 200, list[0]);
    }
    return sendJson(res, 404, { error: "not found", path: p });
  } catch (err) {
    console.error("[releases-server] error handling", p, err);
    return sendJson(res, 500, { error: "internal", message: String(err?.message ?? err) });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[releases-server] listening on http://${HOST}:${PORT}`);
  console.log(`[releases-server] RELEASES_DIR        = ${RELEASES_DIR}`);
  console.log(`[releases-server] PUBLIC_BASE_URL     = ${PUBLIC_BASE_URL}`);
});

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    console.log(`[releases-server] ${sig} received, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  });
}
