-- DQ-11  Temporal integrity break                        Timeliness / MEDIUM
-- Failure conditions (any one):
--   a) a remittance on the claim is dated before the date of service
--   b) the claim was submitted before the date of service
--   c) the date of service is in the future relative to the audit date
--
-- Reported one row per claim with every rule that broke, not one row per rule.
-- A single bad date of service breaks several rules at once, and three tickets
-- for one root cause wastes the correction queue's time.
--
-- The audit date is parameterised so a re-run for a historic period does not
-- retroactively flag rows that were not future-dated when the period closed.
set search_path = rcm, public;

create or replace view rcm.dq11_temporal_integrity as
with audit_ctx as (
    select date '2026-08-29' as audit_date
),
flagged as (
    select
        c.*,
        array_remove(array[
            case when c.date_of_service is not null
                  and exists (select 1
                                from rcm.v_remit r
                               where r.claim_id = c.claim_id
                                 and r.remit_date is not null
                                 and r.remit_date < c.date_of_service)
                 then 'remittance dated before the date of service' end,
            case when c.claim_submit_date is not null
                  and c.date_of_service is not null
                  and c.claim_submit_date < c.date_of_service
                 then format('claim submitted %s, before the date of service %s',
                             c.claim_submit_date, c.date_of_service) end,
            case when c.date_of_service > a.audit_date
                 then format('date of service %s is in the future (audit date %s)',
                             c.date_of_service, a.audit_date) end
        ], null) as issues
    from rcm.v_claim_unique c
    cross join audit_ctx a
)
select
    'DQ-11'::text   as check_id,
    'MEDIUM'::text  as severity,
    'claim'::text   as entity_type,
    claim_id        as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    0::numeric      as amount_impact,
    array_to_string(issues, '; ') as finding
from flagged
where cardinality(issues) > 0;
