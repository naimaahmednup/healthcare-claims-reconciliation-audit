-- DQ-07  Overpayment                                    Consistency / CRITICAL
-- Failure condition: total paid on a claim exceeds the billed charge.
-- Carries a statutory refund clock, so it is separated from DQ-06 and worked
-- by a different queue. Claims with more than one remittance line are excluded:
-- an apparent overpayment caused by a double posting is a cash posting defect
-- and is reported once, under DQ-03.
set search_path = rcm, public;

create or replace view rcm.dq07_overpayment as
select
    'DQ-07'::text     as check_id,
    'CRITICAL'::text  as severity,
    'claim'::text     as entity_type,
    claim_id          as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    round(paid_total - billed_amount, 2) as amount_impact,
    format('paid %s against a billed charge of %s; overpaid by %s (check %s)',
           paid_total, billed_amount, round(paid_total - billed_amount, 2),
           check_eft_numbers) as finding
from rcm.v_claim_recon
where remit_line_count = 1
  and billed_amount > 0
  and paid_total is not null
  and paid_total > billed_amount;
