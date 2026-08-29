# Data Dictionary

Three input files, one derived reconciliation grain. All data is synthetic.

---

## 1. `data/raw/claims_source.csv` — claims extract (837-professional equivalent)

One row per claim header as received from the billing system. **25,230 rows**, which includes
duplicate rows — that is what DQ-01 exists to find.

| Field | Type | Description | Notes for the audit |
|---|---|---|---|
| `claim_id` | text | Claim identifier assigned by the billing system | Expected unique. DQ-01 tests it. |
| `patient_id` | text | Internal patient identifier | Mandatory (DQ-12). Part of the DQ-02 fingerprint. |
| `encounter_id` | text | Encounter the charge belongs to | Not used in reconciliation |
| `provider_npi` | text | Rendering provider NPI | 10 digits, Luhn check over the `80840` prefix (DQ-10) |
| `facility_id` | text | Clinic or facility | Reporting dimension |
| `place_of_service` | text | CMS place-of-service code (11 office, 20 urgent care, 81 lab) | Reporting dimension |
| `payer_id` | text | Payer identifier | Must exist in `ref_payer` (DQ-09) |
| `payer_name` | text | Payer name as carried on the claim | Denormalised; `ref_payer` is authoritative |
| `date_of_service` | date | Date the service was rendered | Mandatory (DQ-12), drives DQ-11 |
| `claim_submit_date` | date | Date the claim was submitted | Must not precede the date of service (DQ-11) |
| `cpt_code` | text | Primary procedure code | 4 digits + digit or letter (DQ-12) |
| `icd10_code` | text | Primary diagnosis code | Letter (I, U excluded) + digit + alphanumeric, optional dot and up to 4 more (DQ-12) |
| `units` | numeric | Service units billed | Multiplies the charge |
| `billed_amount` | numeric | Gross charge | Must be greater than zero (DQ-12). Left side of the balance identity. |
| `expected_allowed_amount` | numeric | Contracted amount expected from this payer | Baseline for DQ-08 |
| `claim_status` | text | `PAID`, `DENIED` or `PENDING` | `PAID` with no remittance is DQ-05 |
| `source_system` | text | `EPIC_PB`, `ATHENA_PM` or `ECW_BILLING` | Used to attribute defects to a feed |
| `ingest_batch_id` | text | Load batch | A `-R` suffix marks a resend |

## 2. `data/raw/payments_remittance.csv` — remittance extract (835 ERA equivalent)

One row per payment line posted from payer remittance advice. **23,649 rows.**

| Field | Type | Description | Notes for the audit |
|---|---|---|---|
| `remit_id` | text | Posting identifier | Unique per posting |
| `claim_id` | text | Claim the payment applies to | Must exist in the claims extract (DQ-04) |
| `payer_id` | text | Paying payer | |
| `check_eft_number` | text | Check or EFT the payment arrived on | With `claim_id` and amount, the duplicate-posting key (DQ-03) |
| `remit_date` | date | Date of the remittance | Must not precede the date of service (DQ-11) |
| `allowed_amount` | numeric | Amount the payer recognised | Compared to `expected_allowed_amount` (DQ-08) |
| `paid_amount` | numeric | Amount paid to the provider | Must not exceed the charge (DQ-07) |
| `patient_responsibility` | numeric | Deductible, coinsurance and copay | Part of the balance identity |
| `contractual_adjustment` | numeric | Billed minus allowed, written off under contract | Part of the balance identity |
| `carc_code` | text | Claim Adjustment Reason Code | `45` fee-schedule adjustment; `16`, `18`, `27`, `29`, `50`, `97`, `197` on denials |
| `carc_description` | text | Text of the CARC | |
| `claim_status_code` | text | 835 CLP02 status | `1` processed as primary, `4` denied |
| `posted_flag` | text | Whether the line was posted | |
| `ingest_batch_id` | text | Load batch | A `-R` suffix marks a re-post |

## 3. `data/reference/` — master data

**`payer_reference.csv`** — `payer_id`, `payer_name`, `payer_type` (MEDICARE, MEDICAID,
COMMERCIAL, GOVERNMENT, WORKCOMP), `contract_rate`. The referential authority for DQ-09.

**`cpt_reference.csv`** — `cpt_code`, `cpt_description`, `standard_charge`. The charge master.

## 4. `data/raw/_injected_defect_ledger.csv` — ground truth

Written by the generator, one row per seeded defect: `defect_ref`, `check_id`, `entity_type`,
`entity_key`, `description`. **Not an input to the audit.** It exists only so the suite can be
scored on recall and precision. Production runs have no equivalent, which is why the negative
control matters there instead.

---

## 5. `rcm.v_claim_recon` — the reconciliation grain

One row per **unique** claim (25,140), carrying both sides and the variance. Exported as
`output/claim_reconciliation.csv` and loaded to the Recon Detail tab of the workbook.

| Field | Source | Description |
|---|---|---|
| `claim_id` … `expected_allowed_amount` | claims | De-duplicated claim attributes |
| `remit_line_count` | remittance | Postings against this claim. `0` feeds DQ-05; `>1` feeds DQ-03. |
| `allowed_total`, `paid_total`, `patient_resp_total`, `adjustment_total` | remittance | Rolled to the claim grain |
| `remit_accounted_total` | derived | `paid + patient responsibility + adjustment` |
| `balance_variance` | derived | `billed_amount − remit_accounted_total`. Zero when the claim foots. |

### Derived objects

| Object | What it is |
|---|---|
| `rcm.v_claim` | Typed claims, all rows, safe casts applied. Raw text retained for the validity checks. |
| `rcm.v_claim_unique` | One row per `claim_id`, the reconciliation denominator |
| `rcm.v_remit` | Typed remittance lines |
| `rcm.v_remit_by_claim` | Remittance rolled to the claim grain |
| `rcm.dq01…dq12` | One view per check, uniform exception shape |
| `rcm.dq_exception_register` | Physical register of every exception, with queue and disposition |
| `rcm.dq_check_catalog` | The test plan in machine-readable form |

### The uniform exception record

Every check emits the same twelve columns, which is what lets them share one register:

`check_id`, `severity`, `entity_type`, `entity_key`, `claim_id`, `payer_id`, `payer_name`,
`date_of_service`, `cpt_code`, `billed_amount`, `amount_impact`, `finding`

`entity_type` is `claim` or `remit`, and `entity_key` is the identifier of whichever one the
exception is about — the claim for a claim-level defect, the posting for a posting-level one.
`amount_impact` is defined per check in the test plan; `finding` is the sentence an analyst
reads to understand the exception without opening the source data.
