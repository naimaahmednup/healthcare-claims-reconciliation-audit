-- =====================================================================
-- 05_run_audit.sql
-- Execute the audit: populate the exception register and print the summary.
-- Safe to re-run; the register is rebuilt for the run id.
-- =====================================================================

set search_path = rcm, public;

\set run_id 'RUN-2026-08-29'

-- Refresh the typed layer in dependency order before scoring anything.
refresh materialized view rcm.v_claim;
refresh materialized view rcm.v_claim_unique;
refresh materialized view rcm.v_remit;
refresh materialized view rcm.v_remit_by_claim;
refresh materialized view rcm.v_claim_recon;
analyze rcm.v_claim_recon;

delete from rcm.dq_exception_register where run_id = :'run_id';

insert into rcm.dq_exception_register
    (run_id, check_id, severity, entity_type, entity_key, claim_id, payer_id,
     payer_name, date_of_service, cpt_code, billed_amount, amount_impact, finding,
     assigned_queue)
select
    :'run_id', e.check_id, e.severity, e.entity_type, e.entity_key, e.claim_id,
    e.payer_id, e.payer_name, e.date_of_service, e.cpt_code, e.billed_amount,
    e.amount_impact, e.finding,
    case e.check_id
        when 'DQ-01' then 'Interface / EDI'
        when 'DQ-02' then 'Charge Entry'
        when 'DQ-03' then 'Cash Posting'
        when 'DQ-04' then 'Cash Posting'
        when 'DQ-05' then 'A/R Follow-up'
        when 'DQ-06' then 'Payment Variance'
        when 'DQ-07' then 'Refunds / Credit Balance'
        when 'DQ-08' then 'Contract Management'
        when 'DQ-09' then 'Payer Maintenance'
        when 'DQ-10' then 'Provider Data Management'
        when 'DQ-11' then 'Source System Owner'
        when 'DQ-12' then 'Charge Entry'
    end
from rcm.v_all_exceptions e;

analyze rcm.dq_exception_register;

\echo ''
\echo '=== RECONCILIATION CONTROL TOTALS ==='
select * from rcm.v_control_totals;

\echo ''
\echo '=== DATA QUALITY RUN SUMMARY ==='
select check_id, check_name, dimension, severity, exceptions_found,
       claims_affected, financial_impact_usd, exception_rate_pct, result
from rcm.v_dq_summary;

\echo ''
\echo '=== SUITE VALIDATION AGAINST THE SEEDED DEFECT LEDGER ==='
select check_id, injected_defects, detected_exceptions, true_positives,
       false_negatives, false_positives, recall_pct, precision_pct, suite_result
from rcm.v_suite_validation;
