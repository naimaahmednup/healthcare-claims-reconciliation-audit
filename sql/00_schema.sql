-- =====================================================================
-- 00_schema.sql
-- Healthcare Claims Reconciliation & Data Quality Audit
-- Target: PostgreSQL 13+
--
-- Landing tables are deliberately all TEXT. Source extracts from billing
-- systems and payer ERA files arrive dirty; if the loader casts on the way in,
-- the bad rows fail the load and the defects you were hired to find never make
-- it into the database. Type enforcement happens one layer up, in 02_typed_views,
-- where a failed cast becomes a finding instead of a load error.
-- =====================================================================

drop schema if exists rcm cascade;
create schema rcm;

set search_path = rcm, public;

-- ---------------------------------------------------------------------
-- Landing / staging
-- ---------------------------------------------------------------------

create table rcm.stg_claims_source (
    claim_id                text,
    patient_id              text,
    encounter_id            text,
    provider_npi            text,
    facility_id             text,
    place_of_service        text,
    payer_id                text,
    payer_name              text,
    date_of_service         text,
    claim_submit_date       text,
    cpt_code                text,
    icd10_code              text,
    units                   text,
    billed_amount           text,
    expected_allowed_amount text,
    claim_status            text,
    source_system           text,
    ingest_batch_id         text
);

create table rcm.stg_payments_remittance (
    remit_id                text,
    claim_id                text,
    payer_id                text,
    check_eft_number        text,
    remit_date              text,
    allowed_amount          text,
    paid_amount             text,
    patient_responsibility  text,
    contractual_adjustment  text,
    carc_code               text,
    carc_description        text,
    claim_status_code       text,
    posted_flag             text,
    ingest_batch_id         text
);

create index ix_stg_claims_claim_id on rcm.stg_claims_source (claim_id);
create index ix_stg_remit_claim_id  on rcm.stg_payments_remittance (claim_id);

-- ---------------------------------------------------------------------
-- Reference / master data
-- ---------------------------------------------------------------------

create table rcm.ref_payer (
    payer_id      text primary key,
    payer_name    text not null,
    payer_type    text not null,
    contract_rate numeric(5,2) not null
);

create table rcm.ref_cpt (
    cpt_code        text primary key,
    cpt_description text not null,
    standard_charge numeric(12,2) not null
);

-- Ground truth for suite validation. Loaded only when the audit is run against
-- the seeded dataset; scoring the checks against it is what proves the checks
-- work, rather than assuming they do.
create table rcm.ref_injected_defects (
    defect_ref  text primary key,
    check_id    text not null,
    entity_type text not null,
    entity_key  text not null,
    description text
);

-- ---------------------------------------------------------------------
-- Check catalogue: the machine-readable half of the test plan
-- ---------------------------------------------------------------------

create table rcm.dq_check_catalog (
    check_id          text primary key,
    check_name        text not null,
    dimension         text not null,   -- Uniqueness / Completeness / Validity / Consistency / Integrity / Timeliness
    severity          text not null,   -- CRITICAL / HIGH / MEDIUM
    failure_condition text not null,
    escalation        text not null
);

insert into rcm.dq_check_catalog values
('DQ-01','Duplicate claim identifiers','Uniqueness','CRITICAL',
 'The same claim_id appears on more than one row in the claims extract.',
 'Hold the batch. Raise a P2 ticket with the interface team; do not release to the payer until the resend is collapsed to one row.'),
('DQ-02','Duplicate billing fingerprint','Uniqueness','CRITICAL',
 'Two or more distinct claim_ids share patient_id, provider_npi, date_of_service, cpt_code and billed_amount.',
 'Route to the Charge Entry lead for clinical confirmation before submission. Duplicate billing is a compliance exposure, not just a data issue.'),
('DQ-03','Duplicate remittance posting','Uniqueness','CRITICAL',
 'The same claim_id is posted more than once against the same check/EFT number for the same paid amount.',
 'Freeze posting for the affected check. Notify Cash Posting supervisor same day; reversal must be booked before month-end close.'),
('DQ-04','Orphaned remittance record','Integrity','CRITICAL',
 'A remittance line references a claim_id that does not exist in the claims extract.',
 'Return to the Cash Posting queue. If the claim cannot be located within 2 business days, escalate to the payer as an unidentified payment.'),
('DQ-05','Missing remittance for paid claim','Completeness','HIGH',
 'A claim carries status PAID in the billing system but no remittance line was received.',
 'Route to A/R Follow-up. Status is unsupported by cash; correct the claim status or locate the missing 835.'),
('DQ-06','Claim-to-payment amount mismatch','Consistency','CRITICAL',
 'billed_amount <> paid_amount + patient_responsibility + contractual_adjustment, beyond a USD 0.01 rounding tolerance.',
 'Route to Payment Variance analyst with the claim and remittance evidence. Anything above USD 500 goes to the Payer Relations lead the same day.'),
('DQ-07','Overpayment','Consistency','CRITICAL',
 'Total paid on a claim exceeds the billed charge.',
 'Report to Refunds/Credit Balance immediately. Overpayments carry a statutory refund clock; do not hold in a working file.'),
('DQ-08','Allowed amount below contract','Consistency','HIGH',
 'Remitted allowed_amount is more than 10% below the contracted expected_allowed_amount on an adjudicated (non-denied) claim.',
 'Bundle by payer and route to Contract Management for an underpayment appeal. Escalate at 25 claims or USD 5,000, whichever comes first.'),
('DQ-09','Unmapped payer identifier','Integrity','HIGH',
 'payer_id on the claim is blank or absent from the payer master.',
 'Return to the Enrollment/Payer Maintenance owner. Claim cannot be routed or reconciled until the payer is mapped.'),
('DQ-10','Invalid provider NPI','Validity','HIGH',
 'provider_npi is not 10 numeric digits or fails the Luhn check digit over the 80840 prefix.',
 'Return to Provider Data Management. A claim with an invalid NPI will reject at the clearinghouse.'),
('DQ-11','Temporal integrity break','Timeliness','MEDIUM',
 'Remittance dated before the date of service, claim submitted before the date of service, or a date of service in the future.',
 'Route to the source-system owner. Recurring breaks in one feed indicate a mapping or timezone defect and go to the interface team.'),
('DQ-12','Missing or malformed mandatory field','Completeness','HIGH',
 'patient_id, date_of_service, cpt_code, icd10_code or billed_amount is blank, malformed, zero or negative.',
 'Return to Charge Entry for correction. Claim is not submittable and must not be counted in reconciliation totals.');

-- ---------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------

-- Cast that yields NULL instead of aborting the query, so one malformed value
-- in 25,000 rows does not take down the whole audit run.
create or replace function rcm.safe_date(p_value text)
returns date language plpgsql immutable as $$
begin
    if p_value is null or btrim(p_value) = '' then
        return null;
    end if;
    return p_value::date;
exception when others then
    return null;
end;
$$;

create or replace function rcm.safe_numeric(p_value text)
returns numeric language plpgsql immutable as $$
begin
    if p_value is null or btrim(p_value) = '' then
        return null;
    end if;
    return p_value::numeric;
exception when others then
    return null;
end;
$$;

-- NPI validation per the CMS standard: 10 digits, the tenth being a Luhn
-- check digit calculated over the constant 80840 prefix plus the first nine.
create or replace function rcm.fn_npi_is_valid(p_npi text)
returns boolean language plpgsql immutable as $$
declare
    v_payload text;
    v_sum     int := 0;
    v_digit   int;
    i         int;
    v_pos     int := 0;
begin
    if p_npi is null or p_npi !~ '^[0-9]{10}$' then
        return false;
    end if;

    v_payload := '80840' || left(p_npi, 9);

    for i in reverse length(v_payload)..1 loop
        v_digit := substr(v_payload, i, 1)::int;
        if v_pos % 2 = 0 then
            v_digit := v_digit * 2;
            if v_digit > 9 then
                v_digit := v_digit - 9;
            end if;
        end if;
        v_sum := v_sum + v_digit;
        v_pos := v_pos + 1;
    end loop;

    return ((10 - (v_sum % 10)) % 10) = right(p_npi, 1)::int;
end;
$$;
