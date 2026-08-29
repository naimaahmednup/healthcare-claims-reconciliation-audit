# Test Plan — Claims Reconciliation & Data Quality Audit

| | |
|---|---|
| Document | Test plan, claims-to-payment reconciliation |
| Version | 1.0 |
| Run covered | RUN-2026-08-29 |
| Environment | PostgreSQL 16 |
| Scope | 25,230 claim rows and 23,649 remittance rows for dates of service 2025-07-01 to 2026-06-30 |
| Out of scope | Coding accuracy, medical necessity, patient statements, secondary/tertiary coordination of benefits, denial appeals |

---

## 1. Objective

Establish, for a defined claims population, whether every claim submitted has a matching
payment record, whether those two records agree on the money, and whether the source data is
fit to reconcile in the first place. Anything that fails is routed to a named queue with a
defined clock.

## 2. Reconciliation basis

The audit is built on one identity, applied at the claim grain:

```
billed_amount = paid_amount + patient_responsibility + contractual_adjustment
```

A claim satisfies it when the absolute variance is within **USD 0.01** (rounding tolerance).
Anything outside that has money nobody has accounted for.

Two supporting reference sets are used: the payer master (`ref_payer`) for payer validity, and
the contracted expected allowed amount carried on the claim for underpayment testing.

## 3. Method

| Stage | What happens | Why it is done this way |
|---|---|---|
| Land | Both extracts load into all-`TEXT` staging tables | Casting on load turns a defective row into a load failure. The defective rows are the deliverable, so they must land. |
| Type | Safe casts applied in a materialised layer; a failed cast yields `NULL`, not an error | One malformed value in 25,000 rows must not abort the run |
| De-duplicate | Reconciliation runs on one row per `claim_id` | A duplicated key fans out the join and inflates every dollar total. The duplicates are reported, not dropped. |
| Reconcile | Remittance rolled to the claim grain and joined to the de-duplicated claim | Gives one row per claim carrying both sides and the variance |
| Check | Twelve checks, one view each, uniform exception record | Uniform shape lets every check land in one register |
| Register | Exceptions written to `dq_exception_register` with an owning queue | A finding without an owner is a report, not operations work |
| Report | Control totals, run summary, payer scorecard | The manager reads control totals; the analyst reads the register |

## 4. Entry criteria

- Both extracts present for the period, with row counts recorded before anything is transformed
- Payer master and CPT reference loaded
- Prior run's register closed or carried forward with a documented reason

## 5. Test cases

Severity drives the clock, not the volume. Exposure is the dollar value attributed to the
exception, defined per check in the last column.

| ID | Check | Dimension | Severity | Failure condition | Tolerance / rule | Exposure measured as |
|---|---|---|---|---|---|---|
| DQ-01 | Duplicate claim identifiers | Uniqueness | CRITICAL | The same `claim_id` appears on more than one row of the claims extract | Exact key match; zero tolerance | Billed × extra occurrences |
| DQ-02 | Duplicate billing fingerprint | Uniqueness | CRITICAL | Two or more distinct `claim_id`s share `patient_id`, `provider_npi`, `date_of_service`, `cpt_code` and `billed_amount` | Earliest submission is the original; every later claim in the group is reported | Billed amount of the duplicate |
| DQ-03 | Duplicate remittance posting | Uniqueness | CRITICAL | The same `claim_id` is posted more than once against the same check/EFT number for the same paid amount | Zero tolerance | Duplicated paid amount |
| DQ-04 | Orphaned remittance record | Integrity | CRITICAL | A remittance line references a `claim_id` absent from the claims extract | Zero tolerance | Paid amount |
| DQ-05 | Missing remittance for a paid claim | Completeness | HIGH | Claim status is `PAID` and no remittance line exists | Zero tolerance | Billed amount |
| DQ-06 | Claim-to-payment amount mismatch | Consistency | CRITICAL | The balance identity fails | ± USD 0.01 | Absolute variance |
| DQ-07 | Overpayment | Consistency | CRITICAL | Total paid exceeds the billed charge | Zero tolerance | Amount over the charge |
| DQ-08 | Allowed amount below contract | Consistency | HIGH | On an adjudicated claim, remitted allowed is below the contracted expectation | More than 10% below | Shortfall against contract |
| DQ-09 | Unmapped payer identifier | Integrity | HIGH | `payer_id` is blank or absent from the payer master | Zero tolerance | Billed amount at risk |
| DQ-10 | Invalid provider NPI | Validity | HIGH | `provider_npi` is not 10 numeric digits, or fails the Luhn check over the `80840` prefix | CMS NPI standard | Billed amount at risk |
| DQ-11 | Temporal integrity break | Timeliness | MEDIUM | Remittance before date of service, submission before date of service, or a future date of service | Audit date parameterised at 2026-08-29 | Not measured in dollars |
| DQ-12 | Missing or malformed mandatory field | Completeness | HIGH | `patient_id`, `date_of_service`, `cpt_code`, `icd10_code` or `billed_amount` blank, unparseable, zero or negative | CPT: 4 digits + digit/letter. ICD-10: letter (I, U excluded) + digit + alphanumeric, optional dot and up to 4 more | Billed amount at risk |

### 5.1 Classification rules

The checks are deliberately **mutually exclusive**, so no claim is counted twice and the totals
add up. Three exclusions do that work:

1. A payment above the billed charge is reported **only** under DQ-07, never also under DQ-06.
2. A claim with more than one remittance line is reported **only** under DQ-03. Its balance
   variance is a symptom of the double posting, not a separate defect.
3. A claim with a zero, negative or unparseable charge is reported **only** under DQ-12 and is
   excluded from reconciliation, because there is nothing valid to reconcile it against.

Each exclusion is written into the header of the check that carries it.

## 6. Pass / fail criteria

| Level | Criterion |
|---|---|
| Test case | Passes when it returns zero exception rows |
| Run | Passes when no CRITICAL check has exceptions and total exception rate is below 0.5% of claims |
| Suite | Passes when it detects 100% of seeded defects with no false positives, **and** returns zero exceptions against a clean dataset |

The 2026-08-29 run **failed at run level**, as intended for a demonstration dataset: 1,380
exceptions, 5.49% of claims, with all six CRITICAL checks firing. The suite itself passed both
suite-level criteria.

## 7. Suite validation

A suite that fires on a dirty file has not been tested — a wrong query also returns rows. Two
controls are run every time.

**Positive control.** The generator writes a ledger of every defect it plants. The register is
joined to that ledger by check and entity key, giving recall and precision per check.

Result: 1,380 seeded, 1,380 detected, 0 false negatives, 0 false positives, 100% recall and
100% precision on all twelve checks.

**Negative control.** The same 25,000 claims are regenerated with no defects and every check
must return zero rows (`tests/negative_control.sh`).

Result: 0 exceptions across all twelve checks.

### 7.1 Defect history of the suite itself

The first version of the suite did not pass. Recording what was wrong is part of the test
evidence:

| Iteration | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | DQ-06 recall 76.1%; DQ-07 precision 26.6% | Positive payment drift pushed some mismatches above the billed charge, where DQ-07 claimed them; duplicate postings also doubled paid and looked like overpayments | Made the classes mutually exclusive: DQ-06 excludes paid > billed, DQ-07 excludes claims with more than one remittance line |
| 2 | DQ-11 precision 77.3% | A future-dated service date also made every existing remittance look back-dated, so one root cause raised two exceptions | Rebuilt DQ-11 to report one row per claim listing every temporal rule that broke |
| 3 | DQ-06 recall 99.0% | Three seeded mismatches landed on claims already paying zero, so the injected drift clamped at zero and changed nothing | Generator now releases claims with no room to move rather than half-seeding them |

## 8. Exit criteria and deliverables

- Every exception written to the register with an owning queue — `output/exception_register.csv`
- One exception file per check — `output/exceptions/`
- Control totals and run summary — `output/control_totals.csv`, `output/dq_run_summary.csv`
- Defect log — `docs/DEFECT_LOG.md`
- Audit workbook — `output/Claims_Reconciliation_Audit.xlsx`
- Suite validation evidence — `output/suite_validation.csv`

## 9. Assumptions and limitations

- This dataset posts at most one remittance line per claim in the clean case; production feeds
  with partial payments or reversals would need DQ-03 and DQ-06 re-based on a payment-sequence
  key rather than a line count.
- Denials (835 claim status code 4) legitimately allow zero and are out of scope for DQ-08.
- Secondary and tertiary payer coordination is not modelled, so patient responsibility is
  treated as final.
- The contracted expected allowed amount is carried on the claim. In production it would be
  priced from a contract table, and DQ-08 would test against that instead.
- All data is synthetic. The checks are real; the numbers describe a generated book of business.
