// Webhook redelivery sweeper for the nimbus-runners GitHub App.
//
// GitHub never retries a failed webhook delivery. When the webhook lambda is
// throttled (a burst of workflow_job events against the account's Lambda
// concurrency) or briefly unavailable, the job it announced stays queued with
// no runner, forever. Every minute this function signs in as the App, finds
// failed `workflow_job: queued` deliveries for allow-listed repositories, and
// asks GitHub to redeliver them, spaced out so the redeliveries do not throttle
// in turn. A delivery (by guid) is retried at most MAX_ATTEMPTS times in total.
//
// Environment: APP_ID_PARAM, APP_KEY_PARAM (SSM names), ALLOWED_REPOSITORIES
// (comma-separated owner/repo), WINDOW_MINUTES, MAX_ATTEMPTS, SPACING_MS.

import { createSign } from "node:crypto";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

const ssm = new SSMClient({});
const API = "https://api.github.com";
const WINDOW_MS = Number(process.env.WINDOW_MINUTES ?? 20) * 60_000;
const MAX_ATTEMPTS = Number(process.env.MAX_ATTEMPTS ?? 5);
const SPACING_MS = Number(process.env.SPACING_MS ?? 300);
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

async function gh(jwt, path, init = {}) {
  const res = await fetch(path.startsWith("http") ? path : `${API}${path}`, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${jwt}`,
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
    const batch = await res.json();
    all.push(...batch);
    if (!batch.length || Date.parse(batch[batch.length - 1].delivered_at) < cutoff) break;
    url = /<([^>]+)>;\s*rel="next"/.exec(res.headers.get("link") ?? "")?.[1];
  }
  return all.filter((d) => Date.parse(d.delivered_at) >= cutoff);
}

export async function handler() {
  const jwt = appJwt(await credentials());
  const deliveries = await recentDeliveries(jwt);

  const byGuid = new Map();
  for (const d of deliveries) {
    if (d.event !== "workflow_job" || d.action !== "queued") continue;
    byGuid.set(d.guid, [...(byGuid.get(d.guid) ?? []), d]);
  }

  let redelivered = 0;
  let skipped = 0;
  for (const attempts of byGuid.values()) {
    if (attempts.some(ok)) continue;
    const latest = attempts.reduce((a, b) => (Date.parse(a.delivered_at) > Date.parse(b.delivered_at) ? a : b));
    if (attempts.length >= MAX_ATTEMPTS || Date.now() - Date.parse(latest.delivered_at) < SETTLE_MS) {
      skipped++;
      continue;
    }
    const detail = await (await gh(jwt, `/app/hook/deliveries/${latest.id}`)).json();
    const repo = detail.request?.payload?.repository?.full_name?.toLowerCase();
    if (!repo || !ALLOWED.has(repo)) {
      skipped++;
      continue;
    }
    await gh(jwt, `/app/hook/deliveries/${latest.id}/attempts`, { method: "POST" });
    redelivered++;
    console.log(JSON.stringify({ msg: "redelivered", guid: latest.guid, repo, status: latest.status_code, attempt: attempts.length + 1 }));
    await sleep(SPACING_MS);
  }

  const summary = { scanned: deliveries.length, queuedGuids: byGuid.size, redelivered, skipped };
  console.log(JSON.stringify({ msg: "summary", ...summary }));
  return summary;
}
