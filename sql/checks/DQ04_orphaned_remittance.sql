-- DQ-04  Orphaned remittance record                        Integrity / CRITICAL
-- Failure condition: a remittance line references a claim_id that does not
-- exist anywhere in the claims extract. Cash has been posted against a claim
-- the billing system has never heard of.
set search_path = rcm, public;

create or replace view rcm.dq04_orphaned_remittance as
select
    'DQ-04'::text     as check_id,
    'CRITICAL'::text  as severity,
    'remit'::text     as entity_type,
    r.remit_id        as entity_key,
    r.claim_id,
    r.payer_id,
    p.payer_name,
    null::date        as date_of_service,
    null::text        as cpt_code,
    null::numeric     as billed_amount,
    r.paid_amount     as amount_impact,
    format('remittance posted on %s against claim %s, which is absent from the claims feed (check %s)',
           r.remit_date, coalesce(r.claim_id, '<null>'), r.check_eft_number) as finding
from rcm.v_remit r
left join rcm.v_claim_unique c on c.claim_id = r.claim_id
left join rcm.ref_payer      p on p.payer_id = r.payer_id
where c.claim_id is null;
