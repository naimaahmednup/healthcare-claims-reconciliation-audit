#!/usr/bin/env bash
# ---------------------------------------------------------------------
# End-to-end audit run. Execute from the repository root.
#
#   ./scripts/run_audit.sh
#
# Connection is taken from the standard PG* environment variables, so it works
# against a local cluster or a managed instance without editing the SQL:
#   export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGDATABASE=rcm_audit
# ---------------------------------------------------------------------
set -euo pipefail

DB="${PGDATABASE:-rcm_audit}"
PSQL="psql -v ON_ERROR_STOP=1 -d $DB"

echo "==> 1/6  schema"        && $PSQL -q -f sql/00_schema.sql
echo "==> 2/6  load extracts" && $PSQL -q -f sql/01_load.sql
echo "==> 3/6  typed layer"   && $PSQL -q -f sql/02_typed_views.sql
echo "==> 4/6  checks"        && $PSQL -q -f sql/03_checks.sql
echo "==> 5/6  reporting"     && $PSQL -q -f sql/04_reporting.sql
echo "==> 6/6  audit run"     && $PSQL -f sql/05_run_audit.sql

mkdir -p output/exceptions
$PSQL -q -f sql/06_export.sql
echo
echo "Exception files written to output/ and output/exceptions/"
