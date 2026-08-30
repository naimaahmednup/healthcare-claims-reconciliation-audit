#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Negative control.
#
# A check suite that fires on a dirty file proves nothing on its own - a bad
# query can flag rows for the wrong reason and still look productive. This
# rebuilds the same 25,000 claims with no defects injected and asserts that
# every one of the twelve checks returns zero rows. Any check that still fires
# here is flagging clean data and is wrong.
#
# Usage (from the repository root):  ./tests/negative_control.sh
# ---------------------------------------------------------------------
set -euo pipefail

CTRL_DB="${CTRL_DB:-rcm_audit_control}"

echo "==> building a clean dataset (no injected defects)"
python3 scripts/generate_data.py --claims 25000 --seed 20260829 --defects off --outdir data/control

echo "==> loading into $CTRL_DB"
psql -q -d postgres -c "drop database if exists $CTRL_DB with (force)" -c "create database $CTRL_DB"

PSQL="psql -v ON_ERROR_STOP=1 -q -d $CTRL_DB"
$PSQL -f sql/00_schema.sql

$PSQL -c "\\copy rcm.stg_claims_source       from 'data/control/claims_source.csv'       with (format csv, header true, null '')"
$PSQL -c "\\copy rcm.stg_payments_remittance from 'data/control/payments_remittance.csv' with (format csv, header true, null '')"
$PSQL -c "\\copy rcm.ref_payer               from 'data/reference/payer_reference.csv'   with (format csv, header true)"
$PSQL -c "\\copy rcm.ref_cpt                 from 'data/reference/cpt_reference.csv'     with (format csv, header true)"

$PSQL -f sql/02_typed_views.sql
$PSQL -f sql/03_checks.sql
$PSQL -f sql/04_reporting.sql

echo
echo "==> asserting every check returns zero exceptions on clean data"
FAILURES=$(psql -t -A -d "$CTRL_DB" -c \
  "select count(*) from rcm.v_all_exceptions")

psql -d "$CTRL_DB" -c \
  "select check_id, count(*) as false_positives
     from rcm.v_all_exceptions group by check_id order by check_id"

if [ "$FAILURES" = "0" ]; then
    echo
    echo "NEGATIVE CONTROL PASSED - 0 exceptions raised against a clean dataset."
    exit 0
else
    echo
    echo "NEGATIVE CONTROL FAILED - $FAILURES exception(s) raised against clean data."
    exit 1
fi
