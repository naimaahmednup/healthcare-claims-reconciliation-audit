-- =====================================================================
-- 01_load.sql   Load the CSV extracts into the landing tables.
-- Run from the repository root:  psql -f sql/01_load.sql
-- \copy is used (not COPY) so the files are read by the client, which means
-- this works against a managed/remote Postgres as well as a local one.
-- =====================================================================

set search_path = rcm, public;

truncate table rcm.stg_claims_source;
truncate table rcm.stg_payments_remittance;
truncate table rcm.ref_payer;
truncate table rcm.ref_cpt;
truncate table rcm.ref_injected_defects;

\copy rcm.stg_claims_source       from 'data/raw/claims_source.csv'            with (format csv, header true, null '')
\copy rcm.stg_payments_remittance from 'data/raw/payments_remittance.csv'      with (format csv, header true, null '')
\copy rcm.ref_payer               from 'data/reference/payer_reference.csv'    with (format csv, header true)
\copy rcm.ref_cpt                 from 'data/reference/cpt_reference.csv'      with (format csv, header true)
\copy rcm.ref_injected_defects    from 'data/raw/_injected_defect_ledger.csv'  with (format csv, header true)

analyze rcm.stg_claims_source;
analyze rcm.stg_payments_remittance;

select 'claims_source'       as table_name, count(*) as rows_loaded from rcm.stg_claims_source
union all
select 'payments_remittance', count(*) from rcm.stg_payments_remittance
union all
select 'payer_reference',     count(*) from rcm.ref_payer
union all
select 'cpt_reference',       count(*) from rcm.ref_cpt;
