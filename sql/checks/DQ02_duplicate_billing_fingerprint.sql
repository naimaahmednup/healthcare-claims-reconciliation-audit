-- DQ-02  Duplicate billing fingerprint                    Uniqueness / CRITICAL
-- Failure condition: two or more distinct claim_ids share patient_id,
-- provider_npi, date_of_service, cpt_code and billed_amount. The claim_id is
-- new, so DQ-01 cannot see it - this is the same service billed twice.
-- The earliest-submitted claim in each group is treated as the original; every
-- later claim in the group is reported.
-- Claims missing any fingerprint field are excluded and reported by DQ-12
-- instead, so an incomplete row is never mistaken for a duplicate.
set search_path = rcm, public;

create or replace view rcm.dq02_duplicate_billing_fingerprint as
with fingerprinted as (
    select
        claim_id, patient_id, provider_npi, date_of_service, cpt_code,
        billed_amount, claim_submit_date, payer_id, payer_name, source_system,
        row_number() over w  as occurrence_rank,
        first_value(claim_id) over w as original_claim_id
    from rcm.v_claim_unique
    where patient_id      is not null
      and provider_npi    is not null
      and date_of_service is not null
      and cpt_code        is not null
      and billed_amount   is not null
      and billed_amount   > 0
    window w as (
        partition by patient_id, provider_npi, date_of_service, cpt_code, billed_amount
        order by claim_submit_date nulls last, claim_id
    )
)
select
    'DQ-02'::text     as check_id,
    'CRITICAL'::text  as severity,
    'claim'::text     as entity_type,
    claim_id          as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    billed_amount     as amount_impact,
    format('duplicate of %s - same patient, provider, date of service, CPT and charge; submitted %s',
           original_claim_id, claim_submit_date) as finding
from fingerprinted
where occurrence_rank > 1;
