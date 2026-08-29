-- =====================================================================
-- 06_export.sql   Export the audit outputs for the workbook and for review.
-- Run from the repository root:  psql -f sql/06_export.sql
-- =====================================================================

set search_path = rcm, public;

\copy (select * from rcm.v_dq_summary)      to 'output/dq_run_summary.csv'      with (format csv, header true)
\copy (select * from rcm.v_control_totals)  to 'output/control_totals.csv'      with (format csv, header true)
\copy (select * from rcm.v_payer_scorecard) to 'output/payer_scorecard.csv'     with (format csv, header true)
\copy (select * from rcm.v_suite_validation) to 'output/suite_validation.csv'   with (format csv, header true)

\copy (select run_id, check_id, severity, entity_type, entity_key, claim_id, payer_id, payer_name, date_of_service, cpt_code, billed_amount, amount_impact, assigned_queue, disposition, finding from rcm.dq_exception_register order by check_id, entity_key) to 'output/exception_register.csv' with (format csv, header true)

-- One file per check, which is how the correction queues actually receive work.
\copy (select * from rcm.dq01_duplicate_claim_ids           order by claim_id) to 'output/exceptions/DQ-01_duplicate_claim_ids.csv'           with (format csv, header true)
\copy (select * from rcm.dq02_duplicate_billing_fingerprint order by claim_id) to 'output/exceptions/DQ-02_duplicate_billing_fingerprint.csv' with (format csv, header true)
\copy (select * from rcm.dq03_duplicate_remittance_posting  order by entity_key) to 'output/exceptions/DQ-03_duplicate_remittance_posting.csv' with (format csv, header true)
\copy (select * from rcm.dq04_orphaned_remittance           order by entity_key) to 'output/exceptions/DQ-04_orphaned_remittance.csv'          with (format csv, header true)
\copy (select * from rcm.dq05_missing_remittance            order by claim_id) to 'output/exceptions/DQ-05_missing_remittance.csv'            with (format csv, header true)
\copy (select * from rcm.dq06_claim_payment_mismatch        order by claim_id) to 'output/exceptions/DQ-06_claim_payment_mismatch.csv'        with (format csv, header true)
\copy (select * from rcm.dq07_overpayment                   order by claim_id) to 'output/exceptions/DQ-07_overpayment.csv'                   with (format csv, header true)
\copy (select * from rcm.dq08_allowed_below_contract        order by claim_id) to 'output/exceptions/DQ-08_allowed_below_contract.csv'        with (format csv, header true)
\copy (select * from rcm.dq09_unmapped_payer                order by claim_id) to 'output/exceptions/DQ-09_unmapped_payer.csv'                with (format csv, header true)
\copy (select * from rcm.dq10_invalid_npi                   order by claim_id) to 'output/exceptions/DQ-10_invalid_npi.csv'                   with (format csv, header true)
\copy (select * from rcm.dq11_temporal_integrity            order by claim_id) to 'output/exceptions/DQ-11_temporal_integrity.csv'            with (format csv, header true)
\copy (select * from rcm.dq12_mandatory_fields              order by claim_id) to 'output/exceptions/DQ-12_mandatory_fields.csv'              with (format csv, header true)

-- The reconciliation grain itself, for the Excel workbook's formula-based
-- rebuild of the same checks.
\copy (select claim_id, patient_id, provider_npi, payer_id, payer_name, date_of_service, claim_submit_date, cpt_code, claim_status, billed_amount, expected_allowed_amount, remit_line_count, allowed_total, paid_total, patient_resp_total, adjustment_total, remit_accounted_total, balance_variance from rcm.v_claim_recon order by claim_id) to 'output/claim_reconciliation.csv' with (format csv, header true)
