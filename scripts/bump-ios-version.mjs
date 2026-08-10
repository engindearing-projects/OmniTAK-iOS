#!/usr/bin/env node
// bump-ios-version.mjs — auto-pick the next OPEN TestFlight/App Store train.
//
// Why: App Store Connect rejects a build whose CFBundleShortVersionString
// belongs to a train that's already been released/approved ("Invalid
// Pre-Release Train ... closed for new build submissions"). This script
// asks ASC what versions exist and what state they're in, then:
//   - if the highest train is still OPEN (accepting builds) → reuse that
//     marketing version and just bump the build number, so multiple builds
//     can stack on one TestFlight train;
//   - if it's CLOSED (released/in-review/etc.) → roll to the next minor
//     (x.(y+1).0), a fresh open train.
// Build number follows J's YYMMDDNN convention (date + 2-digit counter),
// always strictly greater than the highest existing build that day.
//
// Auth (for authoritative ASC mode) — provide via env or
// ~/.appstoreconnect/config.json { "keyId", "issuerId", "bundleId"? }:
//   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (defaults to
//   ~/.appstoreconnect/private_keys/AuthKey_<keyId>.p8), ASC_BUNDLE_ID.
// Without creds it falls back to scanning local Xcode archives (less
// authoritative — only sees builds made on this Mac).
//
// Usage:
//   node scripts/bump-ios-version.mjs            # writes the pbxproj
//   node scripts/bump-ios-version.mjs --dry-run  # print only
//   node scripts/bump-ios-version.mjs --minor    # force a minor bump
//
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const ROOT = path.resolve(new URL("..", import.meta.url).pathname);
const PBXPROJ = path.join(ROOT, "OmniTAK.xcodeproj", "project.pbxproj");
const DEFAULT_BUNDLE_ID = "com.engindearing.omnitak.mobile";
const DRY = process.argv.includes("--dry-run");
const FORCE_MINOR = process.argv.includes("--minor");

// States in which a marketing-version train no longer accepts new builds.
const CLOSED_STATES = new Set([
  "READY_FOR_SALE", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
  "PROCESSING_FOR_APP_STORE", "IN_REVIEW", "WAITING_FOR_REVIEW",
  "PENDING_CONTRACT", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE",
  "NOT_APPLICABLE",
]);

function loadConfig() {
  const cfgPath = path.join(os.homedir(), ".appstoreconnect", "config.json");
  let file = {};
  if (fs.existsSync(cfgPath)) {
    try { file = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
  }
  const keyId = process.env.ASC_KEY_ID || file.keyId;
  const issuerId = process.env.ASC_ISSUER_ID || file.issuerId;
  const bundleId = process.env.ASC_BUNDLE_ID || file.bundleId || DEFAULT_BUNDLE_ID;
  const keyPath = process.env.ASC_KEY_PATH || file.keyPath ||
    (keyId ? path.join(os.homedir(), ".appstoreconnect", "private_keys", `AuthKey_${keyId}.p8`) : null);
  return { keyId, issuerId, bundleId, keyPath };
}

function b64url(buf) {
  return Buffer.from(buf).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function ascJwt({ keyId, issuerId, keyPath }) {
  const privateKey = fs.readFileSync(keyPath, "utf8");
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: issuerId, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signer = crypto.createSign("SHA256");
  signer.update(signingInput); signer.end();
  const sig = signer.sign({ key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${b64url(sig)}`;
}

async function ascGet(url, token) {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`ASC ${res.status} ${res.statusText} for ${url}: ${await res.text()}`);
  return res.json();
}

// Returns { versions: [{v, state}], builds: ["YYMMDDNN", ...], source }
async function fetchFromAsc(cfg) {
  const token = ascJwt(cfg);
  const base = "https://api.appstoreconnect.apple.com/v1";
  const appResp = await ascGet(`${base}/apps?filter[bundleId]=${encodeURIComponent(cfg.bundleId)}&limit=1`, token);
  const app = appResp.data?.[0];
  if (!app) throw new Error(`No app for bundleId ${cfg.bundleId} on this ASC account`);
  const appId = app.id;
  const versions = [];
  // App Store versions (released + in-prep) with their state.
  const asv = await ascGet(`${base}/apps/${appId}/appStoreVersions?limit=200&fields[appStoreVersions]=versionString,appStoreState`, token);
  for (const v of asv.data || []) versions.push({ v: v.attributes.versionString, state: v.attributes.appStoreState });
  // TestFlight pre-release trains (always build-open unless the matching app-store version is closed).
  const pre = await ascGet(`${base}/apps/${appId}/preReleaseVersions?limit=200&fields[preReleaseVersions]=version,platform`, token);
  for (const p of pre.data || []) {
    if (p.attributes.platform && p.attributes.platform !== "IOS") continue;
    if (!versions.some((x) => x.v === p.attributes.version)) versions.push({ v: p.attributes.version, state: "PRERELEASE_ONLY" });
  }
  const builds = [];
  const b = await ascGet(`${base}/apps/${appId}/builds?limit=200&fields[builds]=version`, token);
  for (const bd of b.data || []) builds.push(String(bd.attributes.version));
  return { versions, builds, source: `App Store Connect (app ${appId})` };
}

function fetchFromArchives() {
  const dir = path.join(os.homedir(), "Library/Developer/Xcode/Archives");
  const versions = [], builds = [];
  const plist = (p, key) => {
    try {
      return execFileSync(
        "/usr/libexec/PlistBuddy", ["-c", `Print ApplicationProperties:${key}`, p], { encoding: "utf8" }
      ).trim();
    } catch { return null; }
  };
  if (fs.existsSync(dir)) {
    for (const day of fs.readdirSync(dir)) {
      const dayDir = path.join(dir, day);
      if (!fs.statSync(dayDir).isDirectory()) continue;
      for (const a of fs.readdirSync(dayDir)) {
        if (!a.endsWith(".xcarchive")) continue;
        const info = path.join(dayDir, a, "Info.plist");
        const v = plist(info, "CFBundleShortVersionString");
        const bn = plist(info, "CFBundleVersion");
        if (v) versions.push({ v, state: "LOCAL_ARCHIVE" });
        if (bn) builds.push(String(bn));
      }
    }
  }
  return { versions, builds, source: "local Xcode archives (no ASC creds — less authoritative)" };
}

const parse = (v) => v.split(".").map((n) => parseInt(n, 10) || 0);
const cmp = (a, b) => { const A = parse(a), B = parse(b); for (let i = 0; i < 3; i++) { if ((A[i]||0) !== (B[i]||0)) return (A[i]||0) - (B[i]||0); } return 0; };
const bumpMinor = (v) => { const [maj, min] = parse(v); return `${maj}.${min + 1}.0`; };

function todayStamp() {
  const d = new Date();
  const yy = String(d.getFullYear()).slice(2);
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${yy}${mm}${dd}`;
}

function nextBuildNumber(builds) {
  const stamp = todayStamp();
  let maxNN = 0;
  for (const b of builds) {
    if (/^\d{8}$/.test(b) && b.startsWith(stamp)) maxNN = Math.max(maxNN, parseInt(b.slice(6), 10));
  }
  const nn = String(maxNN + 1).padStart(2, "0");
  return `${stamp}${nn}`;
}

function readCurrentMarketing() {
  const txt = fs.readFileSync(PBXPROJ, "utf8");
  const m = txt.match(/MARKETING_VERSION = ([0-9.]+);/);
  const b = txt.match(/CURRENT_PROJECT_VERSION = ([0-9]+);/);
  return { marketing: m?.[1], build: b?.[1] };
}

function writePbxproj(oldMarketing, newMarketing, oldBuild, newBuild) {
  let txt = fs.readFileSync(PBXPROJ, "utf8");
  txt = txt.replaceAll(`MARKETING_VERSION = ${oldMarketing};`, `MARKETING_VERSION = ${newMarketing};`);
  txt = txt.replaceAll(`CURRENT_PROJECT_VERSION = ${oldBuild};`, `CURRENT_PROJECT_VERSION = ${newBuild};`);
  fs.writeFileSync(PBXPROJ, txt);
}

(async () => {
  const cfg = loadConfig();
  let data;
  if (cfg.keyId && cfg.issuerId && cfg.keyPath && fs.existsSync(cfg.keyPath)) {
    try { data = await fetchFromAsc(cfg); }
    catch (e) { console.error(`! ASC query failed (${e.message}); falling back to local archives.`); data = fetchFromArchives(); }
  } else {
    console.error("! No ASC creds (set ASC_ISSUER_ID + ASC_KEY_ID or ~/.appstoreconnect/config.json) — using local archives.");
    data = fetchFromArchives();
  }

  if (data.versions.length === 0) { console.error("No existing versions found; aborting (set a version manually)."); process.exit(1); }

  // Highest known marketing version, and whether its train is closed.
  const maxV = data.versions.map((x) => x.v).sort(cmp).at(-1);
  const trainClosed = data.versions.some((x) => x.v === maxV && CLOSED_STATES.has(x.state));
  const target = (FORCE_MINOR || trainClosed) ? bumpMinor(maxV) : maxV;
  const build = nextBuildNumber(data.builds);

  const cur = readCurrentMarketing();
  console.log(`source        : ${data.source}`);
  console.log(`highest train : ${maxV} (${trainClosed ? "CLOSED → roll to next minor" : "OPEN → reuse, bump build"}${FORCE_MINOR ? ", --minor forced" : ""})`);
  console.log(`current pbxproj: ${cur.marketing} (${cur.build})`);
  console.log(`→ next version : ${target} (${build})`);

  if (DRY) { console.log("(dry-run — pbxproj unchanged)"); return; }
  if (cur.marketing == null || cur.build == null) { console.error("Could not read current pbxproj version; aborting."); process.exit(1); }
  writePbxproj(cur.marketing, target, cur.build, build);
  console.log(`✓ wrote MARKETING_VERSION=${target}, CURRENT_PROJECT_VERSION=${build} to project.pbxproj`);
})();
