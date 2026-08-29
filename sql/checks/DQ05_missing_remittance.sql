-- DQ-05  Missing remittance for a paid claim            Completeness / HIGH
-- Failure condition: the billing system says PAID but no 835 line was ever
-- received. The claim status is unsupported by cash.
set search_path = rcm, public;

create or replace view rcm.dq05_missing_remittance as
select
    'DQ-05'::text  as check_id,
    'HIGH'::text   as severity,
    'claim'::text  as entity_type,
    claim_id       as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    billed_amount  as amount_impact,
    format('claim status is PAID but no remittance line exists; submitted %s, charge %s',
           claim_submit_date, billed_amount) as finding
from rcm.v_claim_recon
where claim_status = 'PAID'
  and remit_line_count = 0;
