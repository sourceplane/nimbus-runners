// Webhook redelivery sweeper for the nimbus-runners GitHub App.
//
// GitHub never retries a failed webhook delivery. When the webhook lambda is
// throttled (a burst of workflow_job events against the account's Lambda
// concurrency) or briefly unavailable, the job it announced stays queued with
// no runner, forever. Every minute this function signs in as the App, finds
// failed `workflow_job: queued` deliveries for allow-listed repositories, and
// asks GitHub to redeliver them, spaced out so the redeliveries do not throttle
// in turn. A job is redelivered only while it is still queued, at most once per
// BACKOFF_MINUTES and MAX_ATTEMPTS times in total; those counts live in an SSM
// parameter (STATE_PARAM) keyed by job id. Without them one stranded job could
// be redelivered every minute while its runner boots, launching a runner each
// time.
//
// Environment: APP_ID_PARAM, APP_KEY_PARAM (SSM names), ALLOWED_REPOSITORIES
// (comma-separated owner/repo), STATE_PARAM, WINDOW_MINUTES, MAX_ATTEMPTS,
// BACKOFF_MINUTES, SPACING_MS.

import { createSign } from "node:crypto";
import { GetParameterCommand, PutParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

const ssm = new SSMClient({});
const API = "https://api.github.com";
const WINDOW_MS = Number(process.env.WINDOW_MINUTES ?? 60) * 60_000;
const MAX_ATTEMPTS = Number(process.env.MAX_ATTEMPTS ?? 5);
const SPACING_MS = Number(process.env.SPACING_MS ?? 300);
const BACKOFF_MS = Number(process.env.BACKOFF_MINUTES ?? 4) * 60_000;
const STATE_ENTRIES = 120; // keeps the state parameter under the 4 KB standard tier
const SETTLE_MS = 20_000; // leave a delivery that is seconds old to its first attempt
const ALLOWED = new Set(
  (process.env.ALLOWED_REPOSITORIES ?? "").split(",").map((r) => r.trim().toLowerCase()).filter(Boolean),
);

let cached; // { appId, key } for the life of the container

async function param(name) {
  const out = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  return out.Parameter.Value;
}

async function credentials() {
  if (!cached) {
    const [appId, keyBase64] = await Promise.all([param(process.env.APP_ID_PARAM), param(process.env.APP_KEY_PARAM)]);
    cached = { appId, key: Buffer.from(keyBase64, "base64").toString("utf8") };
  }
  return cached;
}

function b64url(value) {
  return Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
}

function appJwt({ appId, key }) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64url({ alg: "RS256", typ: "JWT" })}.${b64url({ iat: now - 60, exp: now + 540, iss: appId })}`;
  const signature = createSign("RSA-SHA256").update(unsigned).sign(key).toString("base64url");
  return `${unsigned}.${signature}`;
}

// Delivery ids exceed Number.MAX_SAFE_INTEGER: JSON.parse would round them and
// every follow-up call would 404. Read every "id" as a string.
async function json(res) {
  return JSON.parse((await res.text()).replace(/"id":\s*(\d{16,})/g, '"id":"$1"'));
}

async function gh(auth, path, init = {}) {
  const res = await fetch(path.startsWith("http") ? path : `${API}${path}`, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: auth.startsWith("ghs_") ? `token ${auth}` : `Bearer ${auth}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "nimbus-runners-webhook-redelivery",
    },
  });
  if (!res.ok && res.status !== 202) {
    throw new Error(`${init.method ?? "GET"} ${path}: ${res.status} ${await res.text()}`);
  }
  return res;
}

const ok = (d) => d.status_code >= 200 && d.status_code < 300;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Deliveries newest first, back to the start of the window.
async function recentDeliveries(jwt) {
  const cutoff = Date.now() - WINDOW_MS;
  const all = [];
  let url = "/app/hook/deliveries?per_page=100";
  for (let page = 0; url && page < 10; page++) {
    const res = await gh(jwt, url);
    const batch = await json(res);
    all.push(...batch);
    if (!batch.length || Date.parse(batch[batch.length - 1].delivered_at) < cutoff) break;
    url = /<([^>]+)>;\s*rel="next"/.exec(res.headers.get("link") ?? "")?.[1];
  }
  return all.filter((d) => Date.parse(d.delivered_at) >= cutoff);
}

// { [jobId]: { at: epoch ms of the last redelivery, n: redeliveries so far } }
async function loadState() {
  try {
    return JSON.parse(await param(process.env.STATE_PARAM));
  } catch {
    return {};
  }
}

async function saveState(state) {
  const keep = Object.entries(state)
    .filter(([, v]) => Date.now() - v.at < WINDOW_MS)
    .sort((a, b) => b[1].at - a[1].at)
    .slice(0, STATE_ENTRIES);
  await ssm.send(new PutParameterCommand({
    Name: process.env.STATE_PARAM, Type: "String", Overwrite: true, Value: JSON.stringify(Object.fromEntries(keep)) || "{}",
  }));
}

async function installationToken(jwt, installationId, cache) {
  if (!cache.has(installationId)) {
    const res = await gh(jwt, `/app/installations/${installationId}/access_tokens`, { method: "POST" });
    cache.set(installationId, (await json(res)).token);
  }
  return cache.get(installationId);
}

export async function handler() {
  const jwt = appJwt(await credentials());
  const deliveries = await recentDeliveries(jwt);
  const state = await loadState();
  const tokens = new Map();

  const byGuid = new Map();
  for (const d of deliveries) {
    if (d.event !== "workflow_job" || d.action !== "queued") continue;
    byGuid.set(d.guid, [...(byGuid.get(d.guid) ?? []), d]);
  }

  const counts = { redelivered: 0, backoff: 0, notQueued: 0, notAllowed: 0, exhausted: 0, failed: 0 };
  let changed = false;
  for (const attempts of byGuid.values()) {
    if (attempts.some(ok)) continue;
    const latest = attempts.reduce((a, b) => (Date.parse(a.delivered_at) > Date.parse(b.delivered_at) ? a : b));
    if (Date.now() - Date.parse(latest.delivered_at) < SETTLE_MS) continue;
    try {
      const payload = (await json(await gh(jwt, `/app/hook/deliveries/${latest.id}`))).request?.payload ?? {};
      const repo = payload.repository?.full_name?.toLowerCase();
      const jobId = String(payload.workflow_job?.id ?? "");
      if (!repo || !ALLOWED.has(repo) || !jobId) {
        counts.notAllowed++;
        continue;
      }
      const seen = state[jobId];
      if (seen && seen.n >= MAX_ATTEMPTS) {
        counts.exhausted++;
        continue;
      }
      if (seen && Date.now() - seen.at < BACKOFF_MS) {
        counts.backoff++;
        continue;
      }
      const token = await installationToken(jwt, payload.installation.id, tokens);
      const job = await json(await gh(token, `/repos/${repo}/actions/jobs/${jobId}`));
      if (job.status !== "queued") {
        counts.notQueued++;
        continue;
      }
      await gh(jwt, `/app/hook/deliveries/${latest.id}/attempts`, { method: "POST" });
      state[jobId] = { at: Date.now(), n: (seen?.n ?? 0) + 1 };
      changed = true;
      counts.redelivered++;
      console.log(JSON.stringify({ msg: "redelivered", repo, jobId, guid: latest.guid, status: latest.status_code, n: state[jobId].n }));
      await sleep(SPACING_MS);
    } catch (err) {
      counts.failed++;
      console.log(JSON.stringify({ msg: "redelivery failed", guid: latest.guid, error: String(err).slice(0, 300) }));
    }
  }
  if (changed) await saveState(state);

  const summary = { scanned: deliveries.length, queuedGuids: byGuid.size, ...counts };
  console.log(JSON.stringify({ msg: "summary", ...summary }));
  return summary;
}
