-- DQ-06  Claim-to-payment amount mismatch               Consistency / CRITICAL
-- Failure condition: the balance identity fails beyond a 1 cent tolerance.
--     billed_amount = paid + patient_responsibility + contractual_adjustment
--
-- Two exclusions keep the exception classes mutually exclusive, so no claim is
-- counted twice and the totals in the report add up:
--   * paid_total > billed_amount is an overpayment and belongs to DQ-07
--   * a claim with more than one remittance line is a duplicate posting and
--     belongs to DQ-03; its variance is a symptom, not a separate defect
--   * a claim with a zero, negative or unparseable charge cannot be
--     reconciled at all and belongs to DQ-12
set search_path = rcm, public;

create or replace view rcm.dq06_claim_payment_mismatch as
select
    'DQ-06'::text     as check_id,
    'CRITICAL'::text  as severity,
    'claim'::text     as entity_type,
    claim_id          as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    round(balance_variance, 2) as amount_impact,
    format('billed %s vs accounted %s (paid %s + patient resp %s + adjustment %s); variance %s',
           billed_amount, remit_accounted_total, paid_total,
           patient_resp_total, adjustment_total, round(balance_variance, 2)) as finding
from rcm.v_claim_recon
where remit_line_count = 1
  and billed_amount > 0
  and paid_total <= billed_amount
  and abs(balance_variance) > 0.01;
