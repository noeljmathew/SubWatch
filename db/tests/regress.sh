#!/usr/bin/env bash
# Rebuild a scratch database from schema.sql, seed.sql and detection.sql, take
# a snapshot (snapshot.sql) and diff it with v1_baseline/. alert_messages.csv is
# skipped (see v1_baseline/README.md). Exits non-zero if anything differs.
#
#   db/tests/regress.sh [database]      default: subwatch_test
#
# The working "subwatch" database is never touched.
set -euo pipefail

DB="${1:-subwatch_test}"
if [ "$DB" = "subwatch" ]; then
    echo "refusing to rebuild the working database 'subwatch'" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

dropdb --if-exists "$DB"
createdb "$DB"
for f in schema seed detection; do
    psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/db/$f.sql"
done
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -v outdir="$OUT" -f "$ROOT/db/tests/snapshot.sql"

diff -r -x alert_messages.csv -x README.md "$ROOT/db/tests/v1_baseline" "$OUT"
echo "snapshot matches v1_baseline"
