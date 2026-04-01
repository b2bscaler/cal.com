#!/bin/sh
set -eu
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

if [ -n "${DATABASE_HOST:-}" ]; then
  DB_WAIT_TARGET="$DATABASE_HOST"
elif [ -n "${DATABASE_URL:-}" ]; then
  DB_WAIT_TARGET="$(node -e '
    try {
      const url = new URL(process.env.DATABASE_URL);
      const port = url.port || "5432";
      process.stdout.write(`${url.hostname}:${port}`);
    } catch (error) {
      process.exit(1);
    }
  ')"
else
  DB_WAIT_TARGET=""
fi

if [ -n "$DB_WAIT_TARGET" ]; then
  scripts/wait-for-it.sh "$DB_WAIT_TARGET" -- echo "database is up"
else
  echo "DATABASE_HOST and DATABASE_URL are unset; skipping database wait."
fi

npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
yarn start
