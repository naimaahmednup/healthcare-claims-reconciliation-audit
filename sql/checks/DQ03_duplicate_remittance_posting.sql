-- DQ-03  Duplicate remittance posting                     Uniqueness / CRITICAL
-- Failure condition: the same claim_id is posted more than once against the
-- same check/EFT number for the same paid amount. Cash is overstated until the
-- second posting is reversed.
set search_path = rcm, public;

create or replace view rcm.dq03_duplicate_remittance_posting as
with ranked as (
    select r.*,
           row_number() over (partition by r.claim_id, r.check_eft_number, r.paid_amount
                              order by r.remit_id)      as posting_rank,
           first_value(r.remit_id) over (partition by r.claim_id, r.check_eft_number, r.paid_amount
                                         order by r.remit_id) as original_remit_id
    from rcm.v_remit r
    where r.claim_id is not null
)
select
    'DQ-03'::text     as check_id,
    'CRITICAL'::text  as severity,
    'remit'::text     as entity_type,
    k.remit_id        as entity_key,
    k.claim_id,
    k.payer_id,
    c.payer_name,
    c.date_of_service,
    c.cpt_code,
    c.billed_amount,
    k.paid_amount     as amount_impact,
    format('second posting of claim %s on check %s for %s (original posting %s)',
           k.claim_id, k.check_eft_number, k.paid_amount, k.original_remit_id) as finding
from ranked k
left join rcm.v_claim_unique c on c.claim_id = k.claim_id
where k.posting_rank > 1;
