#!/bin/sh

set -eu

: "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID is required}"
: "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET is required}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID is required}"
: "${INFISICAL_API_URL:?INFISICAL_API_URL is required}"
: "${INFISICAL_ENV:?INFISICAL_ENV is required}"

cat >/tmp/infisical-bootstrap.mjs <<'EOF_NODE'
import { writeFileSync } from "node:fs";

const required = [
  "INFISICAL_CLIENT_ID",
  "INFISICAL_CLIENT_SECRET",
  "INFISICAL_PROJECT_ID",
  "INFISICAL_API_URL",
  "INFISICAL_ENV",
];

for (const key of required) {
  if (!process.env[key]) {
    console.error(`ERROR: Missing required variable ${key}`);
    process.exit(1);
  }
}

const apiUrl = process.env.INFISICAL_API_URL.replace(/\/+$/, "");
const secretPath = process.env.INFISICAL_SECRET_PATH || "/calcom";

const authResponse = await fetch(`${apiUrl}/v1/auth/universal-auth/login`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    clientId: process.env.INFISICAL_CLIENT_ID,
    clientSecret: process.env.INFISICAL_CLIENT_SECRET,
  }),
});

if (!authResponse.ok) {
  console.error(`ERROR: Infisical auth failed with status ${authResponse.status}`);
  console.error(await authResponse.text());
  process.exit(1);
}

const authPayload = await authResponse.json();
const accessToken = authPayload.accessToken;

if (!accessToken) {
  console.error("ERROR: Infisical auth response did not include accessToken");
  process.exit(1);
}

const secretsUrl = new URL(`${apiUrl}/v3/secrets/raw`);
secretsUrl.searchParams.set("environment", process.env.INFISICAL_ENV);
secretsUrl.searchParams.set("workspaceId", process.env.INFISICAL_PROJECT_ID);
secretsUrl.searchParams.set("expand", "true");
secretsUrl.searchParams.set("secretPath", secretPath);

const secretsResponse = await fetch(secretsUrl, {
  headers: { Authorization: `Bearer ${accessToken}` },
});

if (!secretsResponse.ok) {
  console.error(`ERROR: Infisical secret fetch failed with status ${secretsResponse.status}`);
  console.error(await secretsResponse.text());
  process.exit(1);
}

const secretsPayload = await secretsResponse.json();
const secrets = Array.isArray(secretsPayload) ? secretsPayload : secretsPayload.secrets || [];

if (!secrets.length) {
  console.error(`ERROR: Infisical returned 0 secrets for path ${secretPath}`);
  process.exit(1);
}

const lines = [];
for (const secret of secrets) {
  if (!secret || typeof secret !== "object") continue;
  const key = secret.secretKey;
  const value = secret.secretValue;
  if (!key || value === undefined || value === null) continue;
  const safe = String(value).replace(/'/g, `'\"'\"'`);
  lines.push(`export ${key}='${safe}'`);
}

writeFileSync("/tmp/infisical_env", `${lines.join("\n")}\n`);
console.log(`Infisical bootstrap: loaded ${lines.length} secrets from ${secretPath}`);
EOF_NODE

node /tmp/infisical-bootstrap.mjs
rm -f /tmp/infisical-bootstrap.mjs

. /tmp/infisical_env
rm -f /tmp/infisical_env

: "${DATABASE_URL:?DATABASE_URL is required from Infisical}"
: "${NEXTAUTH_SECRET:?NEXTAUTH_SECRET is required from Infisical}"
: "${CALENDSO_ENCRYPTION_KEY:?CALENDSO_ENCRYPTION_KEY is required from Infisical}"
: "${NEXT_PUBLIC_WEBAPP_URL:?NEXT_PUBLIC_WEBAPP_URL is required from Infisical}"

exec /calcom/scripts/start.sh
