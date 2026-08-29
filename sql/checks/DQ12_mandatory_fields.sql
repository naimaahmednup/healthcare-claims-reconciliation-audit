-- DQ-12  Missing or malformed mandatory field           Completeness / HIGH
-- Failure condition: any of patient_id, date_of_service, cpt_code, icd10_code
-- or billed_amount is blank, unparseable, or fails its format rule.
--   cpt_code   : 5 characters, four digits plus a digit or letter
--   icd10_code : letter (I and U excluded), digit, alphanumeric, optional
--                dot and up to four further alphanumerics
--   billed     : must parse to a number greater than zero
-- One row per claim, listing every field that failed, so Charge Entry gets one
-- ticket per claim rather than one per field.
set search_path = rcm, public;

create or replace view rcm.dq12_mandatory_fields as
with flagged as (
    select
        c.*,
        array_remove(array[
            case when c.patient_id is null
                 then 'patient_id blank' end,
            case when c.date_of_service is null
                 then 'date_of_service blank or unparseable' end,
            case when c.cpt_code is null
                     then 'cpt_code blank'
                 when btrim(c.cpt_code_raw) !~ '^[0-9]{4}[0-9A-Z]$'
                     then format('cpt_code "%s" is malformed', btrim(c.cpt_code_raw)) end,
            case when c.icd10_code is null
                     then 'icd10_code blank'
                 when btrim(c.icd10_code_raw) !~ '^[A-TV-Z][0-9][0-9A-Z](\.[0-9A-Z]{1,4})?$'
                     then format('icd10_code "%s" is malformed', btrim(c.icd10_code_raw)) end,
            case when c.billed_amount is null
                     then 'billed_amount blank or unparseable'
                 when c.billed_amount <= 0
                     then format('billed_amount is %s', c.billed_amount) end
        ], null) as issues
    from rcm.v_claim_unique c
)
select
    'DQ-12'::text  as check_id,
    'HIGH'::text   as severity,
    'claim'::text  as entity_type,
    claim_id       as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    coalesce(billed_amount, 0) as amount_impact,
    array_to_string(issues, '; ') as finding
from flagged
where cardinality(issues) > 0;
