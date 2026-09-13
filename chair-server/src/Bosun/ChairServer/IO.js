import { readFileSync, writeFileSync, renameSync, copyFileSync, existsSync, mkdirSync, openSync, fsyncSync, closeSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { execSync } from "node:child_process";
import yaml from "js-yaml";

// ${BOSUN_ROOT} expansion — portable-fixture seam. A compose/registry may write
// `${BOSUN_ROOT}/fixtures/...`; the token expands to an absolute anchor at read
// time (default process.cwd() = the repo root chair-server runs from; override
// BOSUN_ROOT), keeping Bosun's absolute-cwd invariant while decoupling fixtures
// from any one checkout path. No-op with no token. (Twin of cli/…/IO.js.)
const expandBosunRoot = (text) =>
  text.replaceAll("${BOSUN_ROOT}", process.env.BOSUN_ROOT || process.cwd());

// EffectFn1: f(path) reads + parses, returning a value that IS an argonaut Json.
export const readYamlImpl = (path) => yaml.load(expandBosunRoot(readFileSync(path, "utf8")));
export const readJsonImpl = (path) => JSON.parse(expandBosunRoot(readFileSync(path, "utf8")));

// Fetch + parse a JSON URL synchronously (the no-Aff seam — straight-line curl).
// Lets the Chair point at the live Marginalia registry (/api/ports).
// `-f`: a 4xx/5xx whose body happens to be JSON parses perfectly well, so
// without it an outage is ingested as a registry — an empty one, reported as a
// registry with nothing in it. Fail loudly instead. (Twin of cli/…/IO.js.)
export const readJsonUrlImpl = (url) =>
  JSON.parse(execSync(`curl -sS -f --max-time 10 ${url}`, { maxBuffer: 64 * 1024 * 1024 }).toString());

// Effect Int: BOSUN_CHAIR_SERVER_PORT or the default 3022.
export const resolvePort = () => {
  const raw = process.env.BOSUN_CHAIR_SERVER_PORT;
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) ? n : 3022;
};

// --- Registry-edit edge (2026-06-23: Marginalia → Bosun ownership) ---
// fleet.json is the source of truth for the dev-server registry. Default
// resolves to registry/fleet.json under chair-server's cwd — the bosun repo
// root on both MBP and the mini, so the same compose works either side of the
// federation. Override with BOSUN_FLEET_PATH for tests.

const DEFAULT_FLEET_PATH = resolve(process.cwd(), "registry/fleet.json");
const MARGINALIA_BASE = process.env.MARGINALIA_API || "http://andrews-mac-mini:3100";
const BOSUN_SERVE_URL = process.env.BOSUN_SERVE_URL || "http://localhost:3997";

export const fleetPath = () => process.env.BOSUN_FLEET_PATH || DEFAULT_FLEET_PATH;

export const readFleetImpl = () => JSON.parse(readFileSync(fleetPath(), "utf8"));

// Atomic write: serialise to a tmp file, fsync it, then rename. Mirror the
// existing backup-on-edit convention by writing a rolling .bak alongside the
// live file (single slot — the git history is the long-tail audit). The temp +
// rename pattern guarantees readers never see a half-written fleet.json.
//
// The fsync is real now. The comment used to say "fsync via writeFileSync
// semantics", which writeFileSync does not do: the rename made the write atomic
// for READERS while the durability the sentence claimed was never performed —
// a belief with nothing to contradict it, in a file whose whole job is being
// the source of truth.
export const writeFleetImpl = (json) => {
  const path = fleetPath();
  const tmp = path + ".tmp";
  const bak = path + ".bak";
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(path)) copyFileSync(path, bak);
  writeFileSync(tmp, JSON.stringify(json, null, 2) + "\n");
  const fd = openSync(tmp, "r+");
  try { fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(tmp, path);
};

// POST :3997/control/reload — bosun-serve re-reads fleet.json and re-plans.
//
// This used to be best-effort AND SILENT: `stdio: "ignore"` threw the router's
// answer away and the catch swallowed the failure, so a write that persisted
// without ever reaching the router was indistinguishable from a complete
// success. That is exactly how itajara @3028 sat registered-but-unrouted for
// three days (2026-08-14 → 17). It is still non-fatal — persisting is the
// durable half and is never rolled back — but the outcome now comes BACK, so
// the handler can put the split result in its own response.
export const reloadBosunServeImpl = () => {
  try {
    // capture stderr rather than letting execSync forward it to ours — the
    // whole point is that the failure comes back in the RESPONSE.
    const out = execSync(`curl -sS -X POST --max-time 8 ${BOSUN_SERVE_URL}/control/reload`, {
      maxBuffer: 8 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    }).toString();
    return { ok: true, body: out.trim() === "" ? null : JSON.parse(out), error: "" };
  } catch (e) {
    const stderr = e && e.stderr ? e.stderr.toString().trim() : "";
    return { ok: false, body: null, error: stderr || String((e && e.message) || e) };
  }
};

// EffectFn1(Int → Json): fetch a Marginalia project record. Called at POST
// /api/projects/:id/servers time only, to denormalise projectName
// into the fleet.json row. Reads stay independent.
// `-f` so a 404 (no such project) THROWS. Without it, Marginalia's error body
// parsed cleanly, the row was denormalised with a null projectName,
// and the registration answered success — a permanently mis-linked row created
// by a lookup that had in fact failed.
export const fetchMarginaliaProjectImpl = (id) =>
  JSON.parse(
    execSync(`curl -sS -f --max-time 8 ${MARGINALIA_BASE}/api/projects/${id}`, {
      maxBuffer: 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    }).toString()
  );
