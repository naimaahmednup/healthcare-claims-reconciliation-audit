-- DQ-08  Allowed amount below contract                  Consistency / HIGH
-- Failure condition: on an adjudicated (non-denied) claim, the remitted allowed
-- amount is more than 10% below the contracted expected allowed amount.
-- This is the underpayment side only; anything paid above the charge is DQ-07.
-- Denied claims (835 claim status code 4) legitimately allow zero and are out
-- of scope.
set search_path = rcm, public;

create or replace view rcm.dq08_allowed_below_contract as
select
    'DQ-08'::text  as check_id,
    'HIGH'::text   as severity,
    'claim'::text  as entity_type,
    claim_id       as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    round(expected_allowed_amount - allowed_total, 2) as amount_impact,
    format('allowed %s against a contracted expectation of %s (%s%% below contract)',
           allowed_total, expected_allowed_amount,
           round(100 * (expected_allowed_amount - allowed_total) / expected_allowed_amount, 1)) as finding
from rcm.v_claim_recon
where remit_line_count = 1
  and remit_status_code = '1'
  and allowed_total is not null
  and allowed_total > 0
  and expected_allowed_amount > 0
  and allowed_total < expected_allowed_amount * 0.90;
