-- =====================================================================
-- 03_checks.sql   Create every data quality check view.
-- Each check is one file, one view, one failure condition.
-- =====================================================================
\ir checks/DQ01_duplicate_claim_ids.sql
\ir checks/DQ02_duplicate_billing_fingerprint.sql
\ir checks/DQ03_duplicate_remittance_posting.sql
\ir checks/DQ04_orphaned_remittance.sql
\ir checks/DQ05_missing_remittance.sql
\ir checks/DQ06_claim_payment_mismatch.sql
\ir checks/DQ07_overpayment.sql
\ir checks/DQ08_allowed_below_contract.sql
\ir checks/DQ09_unmapped_payer.sql
\ir checks/DQ10_invalid_npi.sql
\ir checks/DQ11_temporal_integrity.sql
\ir checks/DQ12_mandatory_fields.sql
