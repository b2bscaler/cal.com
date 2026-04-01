#!/bin/sh

set -eu

echo "Infisical Wrapper: Starting Cal.com bootstrap..."

INFISICAL_SECRET_PATH="${INFISICAL_SECRET_PATH:-/calcom}"
REQUIRED_BOOTSTRAP_VARS="INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET INFISICAL_PROJECT_ID INFISICAL_API_URL INFISICAL_ENV"
REQUIRED_RUNTIME_VARS="DATABASE_URL NEXTAUTH_SECRET CALENDSO_ENCRYPTION_KEY NEXT_PUBLIC_WEBAPP_URL"

require_vars() {
    missing=""
    for key in "$@"; do
        eval "value=\${$key:-}"
        if [ -z "$value" ]; then
            missing="$missing $key"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: Missing required variables:$missing"
        exit 1
    fi
}

require_vars $REQUIRED_BOOTSTRAP_VARS

if [ "$#" -eq 0 ]; then
    echo "ERROR: No command provided to infisical wrapper."
    exit 1
fi

AUTH_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({clientId: process.env.INFISICAL_CLIENT_ID, clientSecret: process.env.INFISICAL_CLIENT_SECRET}))')

echo "Infisical Wrapper: Requesting access token..."
TOKEN_RESPONSE=$(wget -q -O - \
    --header="Content-Type: application/json" \
    --post-data="$AUTH_PAYLOAD" \
    "$INFISICAL_API_URL/v1/auth/universal-auth/login")

ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | node -e '
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
    process.stdout.write(parsed.accessToken || "");
  } catch (error) {
    process.exit(1);
  }
});
')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to get access token from Infisical."
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "Infisical Wrapper: Fetching secrets from '$INFISICAL_SECRET_PATH' in env '$INFISICAL_ENV'..."
SECRETS_RESPONSE=$(wget -q -O - \
    --header="Authorization: Bearer $ACCESS_TOKEN" \
    "$INFISICAL_API_URL/v3/secrets/raw?environment=$INFISICAL_ENV&workspaceId=$INFISICAL_PROJECT_ID&expand=true&secretPath=$INFISICAL_SECRET_PATH")

SECRET_COUNT=$(printf '%s' "$SECRETS_RESPONSE" | node -e '
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
    const secrets = Array.isArray(parsed) ? parsed : parsed.secrets || [];
    process.stdout.write(String(secrets.length));
  } catch (error) {
    process.exit(1);
  }
});
')

if [ -z "$SECRET_COUNT" ] || [ "$SECRET_COUNT" = "0" ]; then
    echo "ERROR: Infisical returned 0 secrets for path '$INFISICAL_SECRET_PATH'."
    exit 1
fi

printf '%s' "$SECRETS_RESPONSE" | node -e '
const fs = require("fs");

let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
    const secrets = Array.isArray(parsed) ? parsed : parsed.secrets || [];
    const lines = [];

    for (const secret of secrets) {
      if (!secret || typeof secret !== "object") continue;
      const key = secret.secretKey;
      const value = secret.secretValue;
      if (!key || value === undefined || value === null) continue;
      const safeValue = String(value).replace(/'"'"'/g, "'"'"'\"'"'"'\"'"'"'");
      lines.push(`export ${key}='"'"'${safeValue}'"'"'`);
    }

    fs.writeFileSync("/tmp/infisical_env", lines.join("\n") + "\n");
  } catch (error) {
    console.error(`Failed to parse Infisical secrets: ${error.message}`);
    process.exit(1);
  }
});
'

echo "Infisical Wrapper: Loaded $SECRET_COUNT secrets."
. /tmp/infisical_env
rm -f /tmp/infisical_env

require_vars $REQUIRED_RUNTIME_VARS

echo "Infisical Wrapper: Executing command..."
exec "$@"
