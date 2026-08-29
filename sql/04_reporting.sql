-- =====================================================================
-- 04_reporting.sql
-- The exception register, the run summary, the reconciliation control totals,
-- the payer scorecard and the suite validation scorecard.
--
-- The twelve check views are unioned into a physical register table rather
-- than read live. Two reasons: the register is what an operations team
-- actually works from (you assign, disposition and age exceptions on it), and
-- materialising once keeps the reporting layer fast instead of re-running
-- every check for every summary.
-- =====================================================================

set search_path = rcm, public;

-- ---------------------------------------------------------------------
-- v_all_exceptions : every check, one uniform record shape.
-- ---------------------------------------------------------------------
create or replace view rcm.v_all_exceptions as
select * from rcm.dq01_duplicate_claim_ids           union all
select * from rcm.dq02_duplicate_billing_fingerprint union all
select * from rcm.dq03_duplicate_remittance_posting  union all
select * from rcm.dq04_orphaned_remittance           union all
select * from rcm.dq05_missing_remittance            union all
select * from rcm.dq06_claim_payment_mismatch        union all
select * from rcm.dq07_overpayment                   union all
select * from rcm.dq08_allowed_below_contract        union all
select * from rcm.dq09_unmapped_payer                union all
select * from rcm.dq10_invalid_npi                   union all
select * from rcm.dq11_temporal_integrity            union all
select * from rcm.dq12_mandatory_fields;

-- ---------------------------------------------------------------------
-- dq_exception_register : the worked artefact.
-- ---------------------------------------------------------------------
drop table if exists rcm.dq_exception_register;

create table rcm.dq_exception_register (
    exception_id     bigserial primary key,
    run_id           text        not null,
    run_ts           timestamptz not null default now(),
    check_id         text        not null references rcm.dq_check_catalog(check_id),
    severity         text        not null,
    entity_type      text        not null,
    entity_key       text        not null,
    claim_id         text,
    payer_id         text,
    payer_name       text,
    date_of_service  date,
    cpt_code         text,
    billed_amount    numeric(12,2),
    amount_impact    numeric(12,2),
    finding          text,
    -- disposition columns, filled by the analyst working the queue
    assigned_queue   text,
    disposition      text default 'OPEN',
    resolved_ts      timestamptz
);

create index ix_register_check  on rcm.dq_exception_register (check_id);
create index ix_register_claim  on rcm.dq_exception_register (claim_id);
create index ix_register_payer  on rcm.dq_exception_register (payer_id);

-- ---------------------------------------------------------------------
-- v_dq_summary : the run summary, one row per check.
-- ---------------------------------------------------------------------
create or replace view rcm.v_dq_summary as
with counts as (
    select check_id,
           count(*)                          as exceptions_found,
           count(distinct claim_id)          as claims_affected,
           round(sum(abs(amount_impact)), 2) as financial_impact
    from rcm.dq_exception_register
    group by check_id
),
denominator as (
    select count(*)::numeric as claims_reviewed from rcm.v_claim_unique
)
select
    cat.check_id,
    cat.check_name,
    cat.dimension,
    cat.severity,
    coalesce(c.exceptions_found, 0)  as exceptions_found,
    coalesce(c.claims_affected, 0)   as claims_affected,
    coalesce(c.financial_impact, 0)  as financial_impact_usd,
    round(100.0 * coalesce(c.exceptions_found, 0) / d.claims_reviewed, 3) as exception_rate_pct,
    case when coalesce(c.exceptions_found, 0) = 0 then 'PASS' else 'FAIL' end as result,
    cat.failure_condition,
    cat.escalation
from rcm.dq_check_catalog cat
cross join denominator d
left join counts c on c.check_id = cat.check_id
order by cat.check_id;

-- ---------------------------------------------------------------------
-- v_control_totals : how much of the billed book is accounted for by
-- remittance, and how much is not.
-- ---------------------------------------------------------------------
create or replace view rcm.v_control_totals as
select
    count(*)                                              as claims_in_scope,
    count(*) filter (where remit_line_count > 0)          as claims_with_remittance,
    count(*) filter (where remit_line_count = 0)          as claims_without_remittance,
    round(sum(coalesce(billed_amount, 0)), 2)             as billed_total,
    round(sum(coalesce(allowed_total, 0)), 2)             as allowed_total,
    round(sum(coalesce(paid_total, 0)), 2)                as paid_total,
    round(sum(coalesce(patient_resp_total, 0)), 2)        as patient_responsibility_total,
    round(sum(coalesce(adjustment_total, 0)), 2)          as adjustment_total,
    round(sum(coalesce(billed_amount, 0))
        - sum(coalesce(paid_total, 0) + coalesce(patient_resp_total, 0)
              + coalesce(adjustment_total, 0)), 2)        as unreconciled_variance,
    -- Claims the payer has not adjudicated yet are legitimately unaccounted for
    -- and would otherwise swamp the number that matters. This is the variance
    -- on claims that DID come back on a remittance - the genuine break.
    round(sum(coalesce(billed_amount, 0)) filter (where remit_line_count > 0), 2)
                                                          as billed_total_adjudicated,
    round(sum(balance_variance) filter (where remit_line_count > 0), 2)
                                                          as variance_adjudicated,
    round(sum(abs(balance_variance)) filter (where remit_line_count > 0), 2)
                                                          as abs_variance_adjudicated
from rcm.v_claim_recon;

-- ---------------------------------------------------------------------
-- v_payer_scorecard : where the problems concentrate. Volume alone is
-- misleading, so exceptions are also shown per 1,000 claims.
-- ---------------------------------------------------------------------
create or replace view rcm.v_payer_scorecard as
with base as (
    select coalesce(payer_id, 'UNMAPPED') as payer_id,
           count(*)::numeric as claims,
           sum(coalesce(billed_amount, 0)) as billed
    from rcm.v_claim_unique
    group by 1
),
exc as (
    select coalesce(payer_id, 'UNMAPPED') as payer_id,
           count(*) as exceptions,
           round(sum(abs(amount_impact)), 2) as impact
    from rcm.dq_exception_register
    group by 1
)
select
    b.payer_id,
    coalesce(p.payer_name, 'Unmapped / unknown payer') as payer_name,
    b.claims::int                            as claims,
    round(coalesce(b.billed, 0), 2)          as billed_total,
    coalesce(e.exceptions, 0)                as exceptions,
    coalesce(e.impact, 0)                    as financial_impact_usd,
    round(1000.0 * coalesce(e.exceptions, 0) / b.claims, 1) as exceptions_per_1000_claims
from base b
left join exc e on e.payer_id = b.payer_id
left join rcm.ref_payer p on p.payer_id = b.payer_id
order by exceptions_per_1000_claims desc, b.claims desc;

-- ---------------------------------------------------------------------
-- v_suite_validation : does the audit suite actually work?
--
-- The generator writes a ledger of every defect it planted. Scoring the check
-- output against that ledger turns "the queries returned some rows" into a
-- measured recall and precision per check. A check that finds 310 of 310
-- planted mismatches and nothing else is evidence. A row count on its own is
-- not.
-- ---------------------------------------------------------------------
create or replace view rcm.v_suite_validation as
with injected as (
    select check_id, count(*) as injected_defects
    from rcm.ref_injected_defects
    group by check_id
),
detected as (
    select check_id, count(distinct entity_key) as detected_exceptions
    from rcm.dq_exception_register
    group by check_id
),
matched as (
    select i.check_id, count(*) as true_positives
    from (select distinct check_id, entity_key from rcm.ref_injected_defects) i
    join (select distinct check_id, entity_key from rcm.dq_exception_register) d
      on d.check_id = i.check_id and d.entity_key = i.entity_key
    group by i.check_id
)
select
    cat.check_id,
    cat.check_name,
    coalesce(i.injected_defects, 0)   as injected_defects,
    coalesce(d.detected_exceptions, 0) as detected_exceptions,
    coalesce(m.true_positives, 0)      as true_positives,
    coalesce(i.injected_defects, 0) - coalesce(m.true_positives, 0)   as false_negatives,
    coalesce(d.detected_exceptions, 0) - coalesce(m.true_positives, 0) as false_positives,
    case when coalesce(i.injected_defects, 0) = 0 then null
         else round(100.0 * coalesce(m.true_positives, 0) / i.injected_defects, 1) end as recall_pct,
    case when coalesce(d.detected_exceptions, 0) = 0 then null
         else round(100.0 * coalesce(m.true_positives, 0) / d.detected_exceptions, 1) end as precision_pct,
    case when coalesce(i.injected_defects, 0) = coalesce(m.true_positives, 0)
          and coalesce(d.detected_exceptions, 0) = coalesce(m.true_positives, 0)
         then 'PASS' else 'REVIEW' end as suite_result
from rcm.dq_check_catalog cat
left join injected i on i.check_id = cat.check_id
left join detected d on d.check_id = cat.check_id
left join matched  m on m.check_id = cat.check_id
order by cat.check_id;
