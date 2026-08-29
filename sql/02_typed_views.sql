-- =====================================================================
-- 02_typed_views.sql
-- Typed, deduplicated and reconciled layer over the landing tables.
-- Everything downstream reads these, never the staging tables directly.
--
-- These are materialised views, not plain views. The safe-cast functions run
-- once per row here; leaving them as plain views made all twelve checks pay
-- the casting cost again on every execution, which took an audit run from
-- seconds to minutes. Refresh order is claim/remit -> rollup -> recon and is
-- handled by 05_run_audit.sql.
-- =====================================================================

set search_path = rcm, public;

-- ---------------------------------------------------------------------
-- v_claim : every claim row as received, with types applied safely.
-- Row count matches the extract exactly, duplicates included.
-- ---------------------------------------------------------------------
create materialized view rcm.v_claim as
select
    btrim(claim_id)                              as claim_id,
    nullif(btrim(patient_id), '')                as patient_id,
    nullif(btrim(encounter_id), '')              as encounter_id,
    nullif(btrim(provider_npi), '')              as provider_npi,
    nullif(btrim(facility_id), '')               as facility_id,
    nullif(btrim(place_of_service), '')          as place_of_service,
    nullif(btrim(payer_id), '')                  as payer_id,
    nullif(btrim(payer_name), '')                as payer_name,
    rcm.safe_date(date_of_service)               as date_of_service,
    rcm.safe_date(claim_submit_date)             as claim_submit_date,
    nullif(btrim(cpt_code), '')                  as cpt_code,
    nullif(btrim(icd10_code), '')                as icd10_code,
    rcm.safe_numeric(units)                      as units,
    rcm.safe_numeric(billed_amount)              as billed_amount,
    rcm.safe_numeric(expected_allowed_amount)    as expected_allowed_amount,
    nullif(btrim(claim_status), '')              as claim_status,
    nullif(btrim(source_system), '')             as source_system,
    nullif(btrim(ingest_batch_id), '')           as ingest_batch_id,
    -- raw values kept for the validity checks, which have to see the original text
    date_of_service                              as date_of_service_raw,
    cpt_code                                     as cpt_code_raw,
    icd10_code                                   as icd10_code_raw,
    billed_amount                                as billed_amount_raw
from rcm.stg_claims_source;

-- ---------------------------------------------------------------------
-- v_claim_unique : one row per claim_id.
-- Reconciliation must run on a deduplicated key or the duplicate rows fan out
-- the join and corrupt every dollar total. The duplicates themselves are not
-- discarded - they are reported by DQ-01.
-- ---------------------------------------------------------------------
create materialized view rcm.v_claim_unique as
select distinct on (claim_id) *
from rcm.v_claim
order by claim_id, ingest_batch_id, source_system;

-- ---------------------------------------------------------------------
-- v_remit : typed remittance lines.
-- ---------------------------------------------------------------------
create materialized view rcm.v_remit as
select
    btrim(remit_id)                                as remit_id,
    nullif(btrim(claim_id), '')                    as claim_id,
    nullif(btrim(payer_id), '')                    as payer_id,
    nullif(btrim(check_eft_number), '')            as check_eft_number,
    rcm.safe_date(remit_date)                      as remit_date,
    rcm.safe_numeric(allowed_amount)               as allowed_amount,
    rcm.safe_numeric(paid_amount)                  as paid_amount,
    rcm.safe_numeric(patient_responsibility)       as patient_responsibility,
    rcm.safe_numeric(contractual_adjustment)       as contractual_adjustment,
    nullif(btrim(carc_code), '')                   as carc_code,
    nullif(btrim(carc_description), '')            as carc_description,
    nullif(btrim(claim_status_code), '')           as claim_status_code,
    nullif(btrim(posted_flag), '')                 as posted_flag,
    nullif(btrim(ingest_batch_id), '')             as ingest_batch_id
from rcm.stg_payments_remittance;

-- ---------------------------------------------------------------------
-- v_remit_by_claim : remittance rolled up to the claim grain.
-- ---------------------------------------------------------------------
create materialized view rcm.v_remit_by_claim as
select
    claim_id,
    count(*)                                     as remit_line_count,
    sum(allowed_amount)                          as allowed_total,
    sum(paid_amount)                             as paid_total,
    sum(patient_responsibility)                  as patient_resp_total,
    sum(contractual_adjustment)                  as adjustment_total,
    min(remit_date)                              as first_remit_date,
    max(remit_date)                              as last_remit_date,
    min(claim_status_code)                        as remit_status_code,
    string_agg(distinct carc_code, ',' order by carc_code) as carc_codes,
    string_agg(distinct check_eft_number, ',')    as check_eft_numbers
from rcm.v_remit
where claim_id is not null
group by claim_id;

-- ---------------------------------------------------------------------
-- v_claim_recon : the reconciliation grain. One row per unique claim, with the
-- payment side attached. This is the table the whole audit argues from.
--
-- Balance identity used throughout:
--     billed_amount = paid + patient_responsibility + contractual_adjustment
-- ---------------------------------------------------------------------
create materialized view rcm.v_claim_recon as
select
    c.claim_id,
    c.patient_id,
    c.provider_npi,
    c.facility_id,
    c.payer_id,
    c.payer_name,
    c.date_of_service,
    c.claim_submit_date,
    c.cpt_code,
    c.claim_status,
    c.source_system,
    c.billed_amount,
    c.expected_allowed_amount,
    coalesce(r.remit_line_count, 0)   as remit_line_count,
    r.allowed_total,
    r.paid_total,
    r.patient_resp_total,
    r.adjustment_total,
    r.first_remit_date,
    r.last_remit_date,
    r.remit_status_code,
    r.carc_codes,
    r.check_eft_numbers,
    coalesce(r.paid_total, 0)
      + coalesce(r.patient_resp_total, 0)
      + coalesce(r.adjustment_total, 0)          as remit_accounted_total,
    c.billed_amount
      - ( coalesce(r.paid_total, 0)
        + coalesce(r.patient_resp_total, 0)
        + coalesce(r.adjustment_total, 0) )      as balance_variance
from rcm.v_claim_unique c
left join rcm.v_remit_by_claim r using (claim_id);

-- ---------------------------------------------------------------------
-- Indexes. The checks join claim to remittance on claim_id repeatedly; without
-- these the audit run is dominated by sequential scans.
-- ---------------------------------------------------------------------
create index ix_v_claim_claim_id        on rcm.v_claim (claim_id);
create unique index ux_v_claim_unique   on rcm.v_claim_unique (claim_id);
create index ix_v_remit_claim_id        on rcm.v_remit (claim_id);
create index ix_v_remit_dedupe          on rcm.v_remit (claim_id, check_eft_number, paid_amount);
create unique index ux_v_remit_by_claim on rcm.v_remit_by_claim (claim_id);
create unique index ux_v_claim_recon    on rcm.v_claim_recon (claim_id);
create index ix_v_claim_recon_payer     on rcm.v_claim_recon (payer_id);
