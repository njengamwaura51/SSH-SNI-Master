// Release manifest for the SNI Hunter desktop app + companion APK.
//
// Endpoints
//   GET /api/releases               → JSON list of available downloads
//   GET /api/releases/latest        → JSON pointer to the newest version
// Static binaries themselves are served from <api-server>/releases/* by
// the parent index.ts at /dl/<file> (helmet+rate-limit applied there).
//
// The manifest is generated at request time from RELEASES_DIR so we don't
// need to redeploy the API server for a new build — drop the file in the
// directory and bump the version in releases.json next to it.
import { Router, type IRouter } from "express";
import { promises as fs } from "node:fs";
import path from "node:path";

const router: IRouter = Router();

const RELEASES_DIR =
  process.env.RELEASES_DIR ||
  path.resolve(process.cwd(), "releases");

interface ReleaseAsset {
  filename: string;
  size: number;
  mtime: string;
  download_url: string;
  sha256?: string;
}

async function listAssets(baseUrl: string): Promise<ReleaseAsset[]> {
  let entries: string[];
  try {
    entries = await fs.readdir(RELEASES_DIR);
  } catch {
    return [];
  }
  const out: ReleaseAsset[] = [];
  for (const name of entries) {
    if (name.startsWith(".") || name.endsWith(".sha256")) continue;
    const full = path.join(RELEASES_DIR, name);
    let st;
    try {
      st = await fs.stat(full);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    let sha: string | undefined;
    try {
      sha = (await fs.readFile(`${full}.sha256`, "utf8")).trim().split(/\s+/)[0];
    } catch {
      // sidecar missing — fine, optional integrity hint
    }
    out.push({
      filename: name,
      size: st.size,
      mtime: st.mtime.toISOString(),
      download_url: `${baseUrl}/dl/${encodeURIComponent(name)}`,
      sha256: sha,
    });
  }
  out.sort((a, b) => (a.mtime < b.mtime ? 1 : -1));
  return out;
}

// URL-base resolution must be tamper-proof: download URLs in the manifest
// drive auto-updaters and external download buttons, so a spoofed Host /
// X-Forwarded-Proto header from an attacker on the same proxy fabric must
// never end up in the response. We require RELEASES_PUBLIC_BASE_URL to be
// explicitly configured in production; if it isn't set we fall back to a
// scheme-less relative path ("/dl/<file>") which is always safe — the
// browser resolves it against its own page origin.
const RELEASES_PUBLIC_BASE_URL = (
  process.env.RELEASES_PUBLIC_BASE_URL || ""
).replace(/\/+$/, "");

function originOf(_req: import("express").Request): string {
  return RELEASES_PUBLIC_BASE_URL;
}

router.get("/releases", async (req, res) => {
  const assets = await listAssets(originOf(req));
  res.json({
    project: "sni-hunter",
    schema_version: 1,
    asset_count: assets.length,
    assets,
  });
});

router.get("/releases/latest", async (req, res) => {
  const assets = await listAssets(originOf(req));
  if (!assets.length) {
    res.status(404).json({ error: "no releases" });
    return;
  }
  res.json(assets[0]);
});

export default router;
