-- DQ-01  Duplicate claim identifiers                      Uniqueness / CRITICAL
-- Failure condition: the same claim_id appears on more than one row of the
-- claims extract. Usually an interface resend that was never collapsed.
-- amount_impact: the charge value duplicated (billed x extra occurrences).
set search_path = rcm, public;

create or replace view rcm.dq01_duplicate_claim_ids as
with dup as (
    select claim_id,
           count(*)                                   as occurrences,
           string_agg(distinct source_system, ', ')    as source_systems,
           string_agg(distinct ingest_batch_id, ', ')  as ingest_batches,
           max(billed_amount)                         as billed_amount
    from rcm.v_claim
    group by claim_id
    having count(*) > 1
)
select
    'DQ-01'::text        as check_id,
    'CRITICAL'::text     as severity,
    'claim'::text        as entity_type,
    d.claim_id           as entity_key,
    d.claim_id,
    c.payer_id,
    c.payer_name,
    c.date_of_service,
    c.cpt_code,
    c.billed_amount,
    round(coalesce(d.billed_amount, 0) * (d.occurrences - 1), 2) as amount_impact,
    format('claim_id received %s times (source systems: %s; batches: %s)',
           d.occurrences, d.source_systems, d.ingest_batches)     as finding
from dup d
join rcm.v_claim_unique c using (claim_id);
