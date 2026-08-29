-- DQ-09  Unmapped payer identifier                        Integrity / HIGH
-- Failure condition: payer_id on the claim is blank, or not present in the
-- payer master. The claim cannot be routed, priced or reconciled.
set search_path = rcm, public;

create or replace view rcm.dq09_unmapped_payer as
select
    'DQ-09'::text  as check_id,
    'HIGH'::text   as severity,
    'claim'::text  as entity_type,
    c.claim_id     as entity_key,
    c.claim_id,
    c.payer_id,
    c.payer_name,
    c.date_of_service,
    c.cpt_code,
    c.billed_amount,
    c.billed_amount as amount_impact,
    case
        when c.payer_id is null
            then 'payer_id is blank on the claim record'
        else format('payer_id %s is not present in the payer master (claim carries name "%s")',
                    c.payer_id, coalesce(c.payer_name, '<null>'))
    end as finding
from rcm.v_claim_unique c
left join rcm.ref_payer p on p.payer_id = c.payer_id
where p.payer_id is null;
