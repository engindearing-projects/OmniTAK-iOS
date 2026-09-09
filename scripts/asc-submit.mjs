#!/usr/bin/env node
// asc-submit.mjs — App Store Connect helper that picks up where
// release-ios.sh stops (TestFlight upload) and takes a build to review.
//
//   node scripts/asc-submit.mjs status
//   node scripts/asc-submit.mjs wait-build <YYMMDDNN>
//   node scripts/asc-submit.mjs submit <marketingVersion> <YYMMDDNN> <whatsNew.txt>
//
// submit: creates the App Store version if it does not exist, attaches the
// build, sets the en-US "What's New" text, and files a review submission.
// Auth: ~/.appstoreconnect/config.json { keyId, issuerId, bundleId } plus
// ~/.appstoreconnect/private_keys/AuthKey_<keyId>.p8 (same as release-ios.sh).
import crypto from "node:crypto"; import fs from "node:fs"; import os from "node:os"; import path from "node:path";
const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".appstoreconnect/config.json"), "utf8"));
const keyPath = path.join(os.homedir(), ".appstoreconnect/private_keys", `AuthKey_${cfg.keyId}.p8`);
const b64 = (b) => Buffer.from(b).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const si = `${b64(JSON.stringify({ alg: "ES256", kid: cfg.keyId, typ: "JWT" }))}.${b64(JSON.stringify({ iss: cfg.issuerId, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" }))}`;
  const s = crypto.createSign("SHA256"); s.update(si); s.end();
  return `${si}.${b64(s.sign({ key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" }))}`;
}
const BASE = "https://api.appstoreconnect.apple.com/v1";
async function api(method, url, body) {
  const r = await fetch(url.startsWith("http") ? url : BASE + url, { method, headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text(); if (!r.ok) throw new Error(`${method} ${url} -> ${r.status}: ${t.slice(0, 600)}`);
  return t ? JSON.parse(t) : {};
}
const bundleId = cfg.bundleId || "com.engindearing.omnitak.mobile";
async function app() { const a = (await api("GET", `/apps?filter[bundleId]=${bundleId}&limit=1`)).data[0]; if (!a) throw new Error("no app"); return a.id; }
const [cmd, ...args] = process.argv.slice(2);
if (cmd === "status") {
  const id = await app();
  const v = await api("GET", `/apps/${id}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState,createdDate`);
  for (const x of v.data) console.log(`version ${x.attributes.versionString}: ${x.attributes.appStoreState} (${x.id})`);
  const b = await api("GET", `/builds?filter[app]=${id}&sort=-uploadedDate&limit=5&fields[builds]=version,processingState,uploadedDate`);
  for (const x of b.data) console.log(`build ${x.attributes.version}: ${x.attributes.processingState} uploaded ${x.attributes.uploadedDate}`);
} else if (cmd === "wait-build") {
  const id = await app(); const want = args[0];
  for (let i = 0; i < 90; i++) {
    const b = await api("GET", `/builds?filter[app]=${id}&filter[version]=${want}&limit=1&fields[builds]=version,processingState`);
    const x = b.data[0];
    if (x && x.attributes.processingState === "VALID") { console.log(`build ${want} VALID (${x.id})`); process.exit(0); }
    if (x && x.attributes.processingState === "FAILED") { console.log(`build ${want} FAILED processing`); process.exit(2); }
    console.log(`build ${want}: ${x ? x.attributes.processingState : "not visible yet"}; waiting 60s`); await new Promise((r) => setTimeout(r, 60000));
  }
  process.exit(3);
} else if (cmd === "submit") {
  const [version, buildNo, notesFile] = args; const id = await app();
  const whatsNew = fs.readFileSync(notesFile, "utf8").trim();
  // 1. app store version (reuse if it exists in an editable state)
  let ver = (await api("GET", `/apps/${id}/appStoreVersions?filter[versionString]=${version}&limit=1`)).data[0];
  if (!ver) { ver = (await api("POST", `/appStoreVersions`, { data: { type: "appStoreVersions", attributes: { platform: "IOS", versionString: version }, relationships: { app: { data: { type: "apps", id } } } } })).data; console.log(`created version ${version} (${ver.id})`); }
  else console.log(`version ${version} exists: ${ver.attributes.appStoreState} (${ver.id})`);
  // 2. attach the build
  const build = (await api("GET", `/builds?filter[app]=${id}&filter[version]=${buildNo}&limit=1`)).data[0];
  if (!build) throw new Error(`build ${buildNo} not found`);
  await api("PATCH", `/appStoreVersions/${ver.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  console.log(`attached build ${buildNo} (${build.id})`);
  // 3. what's new (en-US)
  const locs = (await api("GET", `/appStoreVersions/${ver.id}/appStoreVersionLocalizations`)).data;
  const en = locs.find((l) => l.attributes.locale === "en-US") || locs[0];
  if (!en) throw new Error("no localization on the version");
  await api("PATCH", `/appStoreVersionLocalizations/${en.id}`, { data: { type: "appStoreVersionLocalizations", id: en.id, attributes: { whatsNew } } });
  console.log(`what's new set on ${en.attributes.locale}`);
  // 4. review submission
  const sub = (await api("POST", `/reviewSubmissions`, { data: { type: "reviewSubmissions", attributes: { platform: "IOS" }, relationships: { app: { data: { type: "apps", id } } } } })).data;
  await api("POST", `/reviewSubmissionItems`, { data: { type: "reviewSubmissionItems", relationships: { reviewSubmission: { data: { type: "reviewSubmissions", id: sub.id } }, appStoreVersion: { data: { type: "appStoreVersions", id: ver.id } } } } });
  await api("PATCH", `/reviewSubmissions/${sub.id}`, { data: { type: "reviewSubmissions", id: sub.id, attributes: { submitted: true } } });
  console.log(`submitted ${version} (${buildNo}) for App Store review: submission ${sub.id}`);
} else { console.log("usage: status | wait-build <n> | submit <ver> <build> <file>"); process.exit(1); }
