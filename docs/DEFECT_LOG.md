# Defect Log — RUN-2026-08-29

Twelve defect classes raised against the claims and remittance extracts for dates of service
2025-07-01 to 2026-06-30. Volume and exposure come from the exception register; root cause is
the analyst's assessment and is stated as such.

**Run totals:** 1,380 exceptions across 25,140 unique claims (5.49%) · USD 129,116.55 exposure
· 780 CRITICAL, 515 HIGH, 85 MEDIUM.

---

| ID | Check | Severity | Volume | Exposure (USD) | Owning queue | SLA | Status |
|---|---|---|---|---|---|---|---|
| DEF-001 | DQ-01 Duplicate claim identifiers | CRITICAL | 90 | 14,030.00 | Interface / EDI | 24h | OPEN |
| DEF-002 | DQ-02 Duplicate billing fingerprint | CRITICAL | 140 | 25,936.00 | Charge Entry | 24h | OPEN |
| DEF-003 | DQ-03 Duplicate remittance posting | CRITICAL | 75 | 7,536.98 | Cash Posting | 24h | OPEN |
| DEF-004 | DQ-04 Orphaned remittance record | CRITICAL | 120 | 13,269.45 | Cash Posting | 24h | OPEN |
| DEF-005 | DQ-05 Missing remittance for a paid claim | HIGH | 60 | 12,524.00 | A/R Follow-up | 3d | OPEN |
| DEF-006 | DQ-06 Claim-to-payment amount mismatch | CRITICAL | 310 | 9,765.55 | Payment Variance | 24h | OPEN |
| DEF-007 | DQ-07 Overpayment | CRITICAL | 45 | 1,495.36 | Refunds / Credit Balance | 24h | OPEN |
| DEF-008 | DQ-08 Allowed amount below contract | HIGH | 200 | 4,140.21 | Contract Management | 3d | OPEN |
| DEF-009 | DQ-09 Unmapped payer identifier | HIGH | 55 | 8,665.00 | Payer Maintenance | 3d | OPEN |
| DEF-010 | DQ-10 Invalid provider NPI | HIGH | 70 | 12,923.00 | Provider Data Management | 3d | OPEN |
| DEF-011 | DQ-11 Temporal integrity break | MEDIUM | 85 | not measured | Source System Owner | 5d | OPEN |
| DEF-012 | DQ-12 Missing or malformed mandatory field | HIGH | 130 | 18,831.00 | Charge Entry | 3d | OPEN |

---

## DEF-001 · DQ-01 Duplicate claim identifiers · CRITICAL · 90 claims · USD 14,030.00

**Evidence.** `CLM-2026-000678` was received twice, from `ATHENA_PM` and `ECW_BILLING`, in
batches `BATCH-20260614` and `BATCH-20260614-R`. Charge $185.00 on both rows.
**Probable root cause.** The interface engine re-sent a batch without collapsing on the claim key.
Every affected claim has a matching `-R` resend batch, which points at the resend path rather
than at charge entry.
**Impact.** Duplicated charge value in every downstream total until the key is de-duplicated.
The reconciliation in this audit de-duplicates first, so the control totals are unaffected — but
any report that does not will overstate revenue.
**Action.** Interface / EDI to collapse on the claim key at ingestion. Hold the affected batches.
**Evidence file.** `output/exceptions/DQ-01_duplicate_claim_ids.csv`

## DEF-002 · DQ-02 Duplicate billing fingerprint · CRITICAL · 140 claims · USD 25,936.00

**Evidence.** `CLM-2026-900001` carries the same patient, provider, date of service (2026-06-07),
CPT 99214 and $264.00 charge as `CLM-2026-007297`, submitted nine days later under a new claim id.
**Probable root cause.** An encounter re-keyed in charge entry with no duplicate guard on the
patient / date-of-service / CPT combination.
**Impact.** This is the compliance-sensitive one. A new claim id makes it invisible to a
key-based duplicate check, so it can reach the payer and be paid twice.
**Action.** Charge Entry to confirm clinically before any resubmission; escalate to Compliance
for any confirmed duplicate submission. Longer term, a duplicate guard at entry.
**Evidence file.** `output/exceptions/DQ-02_duplicate_billing_fingerprint.csv`

## DEF-003 · DQ-03 Duplicate remittance posting · CRITICAL · 75 postings · USD 7,536.98

**Evidence.** `RMT-0023515` posts claim `CLM-2026-006882` for $126.86 on check `EFT177694` —
already posted as `RMT-0006502`.
**Probable root cause.** The same 835 file posted twice; the posting job has no idempotency key
on check number plus claim.
**Impact.** Cash overstated by $7,536.98 until reversed. Also distorts payment variance
reporting, because the doubled payment looks like an overpayment.
**Action.** Cash Posting to freeze the affected checks and book reversals before month-end close.
**Evidence file.** `output/exceptions/DQ-03_duplicate_remittance_posting.csv`

## DEF-004 · DQ-04 Orphaned remittance record · CRITICAL · 120 postings · USD 13,269.45

**Evidence.** `RMT-0023590` posts $71.29 on 2026-03-09 against claim `CLM-2026-800001`, which
does not exist anywhere in the claims feed. Check `EFT334149`.
**Probable root cause.** Payer remitted against a claim number the billing system never issued —
typically a payer-assigned claim number, or a claim purged after submission.
**Impact.** Cash posted with no claim to apply it to. Sits as unapplied cash and ages.
**Action.** Cash Posting to attempt a match on patient, date of service and amount. Unmatched
after 2 business days goes back to the payer as an unidentified payment.
**Evidence file.** `output/exceptions/DQ-04_orphaned_remittance.csv`

## DEF-005 · DQ-05 Missing remittance for a paid claim · HIGH · 60 claims · USD 12,524.00

**Evidence.** `CLM-2026-000103` (Medicare Part B, $18.00, submitted 2025-08-14) carries status
`PAID` with no remittance line at all.
**Probable root cause.** Either the status was advanced manually, or the 835 for that check was
never ingested. The two are distinguishable by checking whether other claims on the same check
posted.
**Impact.** Reported cash is unsupported. If the status is wrong, these claims are silently
dropping out of A/R follow-up while still unpaid.
**Action.** A/R Follow-up to reconcile status against the remittance file; correct the status or
locate the missing 835.
**Evidence file.** `output/exceptions/DQ-05_missing_remittance.csv`

## DEF-006 · DQ-06 Claim-to-payment amount mismatch · CRITICAL · 310 claims · USD 9,765.55

**Evidence.** `CLM-2026-000072`: billed $18.00, accounted $13.18 (paid $7.92 + patient
responsibility $0.00 + adjustment $5.26). Variance $4.82.
**Probable root cause.** Partial adjustments posted without the matching contractual write-off,
so the claim no longer foots to the charge.
**Impact.** The largest exception class by volume. Individually small, collectively $9,765.55 of
unexplained variance, and each one is a claim whose true balance is unknown.
**Action.** Payment Variance to work by exposure descending. Any single variance above USD 500
goes to Payer Relations the same day.
**Evidence file.** `output/exceptions/DQ-06_claim_payment_mismatch.csv`

## DEF-007 · DQ-07 Overpayment · CRITICAL · 45 claims · USD 1,495.36

**Evidence.** `CLM-2026-000535`: paid $89.41 against a billed charge of $48.00 on check
`EFT252950`. Overpaid by $41.41.
**Probable root cause.** Duplicate payer-side adjudication, or a coordination-of-benefits error
where two payers each paid as primary.
**Impact.** Small in dollars, high in risk. Retained overpayments carry a statutory refund
obligation that runs from the date of identification.
**Action.** Refunds / Credit Balance the same day. Do not hold in a working file.
**Evidence file.** `output/exceptions/DQ-07_overpayment.csv`

## DEF-008 · DQ-08 Allowed amount below contract · HIGH · 200 claims · USD 4,140.21

**Evidence.** `CLM-2026-000051` (State Medicaid, CPT 80053): allowed $26.01 against a contracted
expectation of $30.02 — 13.4% below contract.
**Probable root cause.** The payer priced below the loaded contract rate. Either their fee
schedule is stale or ours is.
**Impact.** Recoverable underpayment. Concentration by payer matters more than the total —
see the Payer Scorecard tab.
**Action.** Contract Management to bundle by payer and appeal. Escalate to Payer Relations at
25 claims or USD 5,000.
**Evidence file.** `output/exceptions/DQ-08_allowed_below_contract.csv`

## DEF-009 · DQ-09 Unmapped payer identifier · HIGH · 55 claims · USD 8,665.00

**Evidence.** `CLM-2026-000074` carries `payer_id` `PAY-BCB-03` — a truncated form of
`PAY-BCB-003` — and payer name `UNMAPPED`. Others carry `PAY-XXX-999`, `PAY-UNK-000` or a blank.
**Probable root cause.** A near-miss identifier suggests manual entry rather than a genuinely
new payer; the blanks suggest claims flowing before payer maintenance completed.
**Impact.** These claims cannot be routed, priced or reconciled. Every one is an exception in
the payer scorecard.
**Action.** Payer Maintenance to map or correct. Add a referential constraint at entry.
**Evidence file.** `output/exceptions/DQ-09_unmapped_payer.csv`

## DEF-010 · DQ-10 Invalid provider NPI · HIGH · 70 claims · USD 12,923.00

**Evidence.** `CLM-2026-000113` carries `provider_npi` `776728045X` — not 10 numeric digits.
Others are 9 digits, or 10 digits failing the Luhn check over the `80840` prefix.
**Probable root cause.** Provider records created without NPI validation at entry.
**Impact.** Every one of these will reject at the clearinghouse, so the exposure is delay rather
than loss — but it is delay on $12,923.00 of charges that has not started yet.
**Action.** Provider Data Management to correct; add the Luhn check at entry rather than at audit.
**Evidence file.** `output/exceptions/DQ-10_invalid_npi.csv`

## DEF-011 · DQ-11 Temporal integrity break · MEDIUM · 85 claims

**Evidence.** `CLM-2026-000393` was submitted 2025-11-16 for a date of service of 2026-09-29 —
a service date more than a year after submission, and in the future relative to the audit date.
**Probable root cause.** A date mapping defect in the source feed. Dates are being written
without sequence or timezone validation.
**Impact.** No direct dollar exposure, but these dates drive timely-filing calculations and
aging. A wrong service date can lose a claim to a filing limit.
**Action.** Source System Owner to trace the mapping. If the same feed repeats next run, it goes
to the interface team as a defect, not a data correction.
**Evidence file.** `output/exceptions/DQ-11_temporal_integrity.csv`

## DEF-012 · DQ-12 Missing or malformed mandatory field · HIGH · 130 claims · USD 18,831.00

**Evidence.** `CLM-2026-000109` has a blank `patient_id`. Others carry blank or malformed CPT
and ICD-10 codes, blank dates of service, or zero and negative charges.
**Probable root cause.** Required fields are not enforced at charge entry, so a claim can be
saved incomplete.
**Impact.** None of these are submittable, and claims with an invalid charge are excluded from
reconciliation entirely — there is nothing to reconcile them against.
**Action.** Charge Entry to correct. The durable fix is field-level validation at entry.
**Evidence file.** `output/exceptions/DQ-12_mandatory_fields.csv`
