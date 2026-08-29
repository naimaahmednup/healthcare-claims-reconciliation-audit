# SOP — Daily Claims-to-Payment Reconciliation and Exception Handling

**Owner:** Data Operations, RCM Global Operations  ·  **Version:** 1.0  ·  **Effective:** 2026-08-29  ·  **Review:** quarterly
**Applies to:** every analyst who runs or works the claims reconciliation exception queue.

---

### 1. Purpose
Confirm each day that claims submitted by the billing system are matched by payer remittance and
that the two agree on the money. Route what does not reconcile to the team that can fix it,
within a defined clock.

### 2. Reconciliation rule
A claim is reconciled when
`billed_amount = paid_amount + patient_responsibility + contractual_adjustment`
within **USD 0.01**. Anything outside that tolerance is an exception and must be dispositioned.

### 3. Daily procedure

| # | Step | Action | Evidence produced |
|---|---|---|---|
| 1 | Confirm receipt | Both extracts present for the period. Record row counts **before** any transformation. | Row counts in the run log |
| 2 | Load | `psql -f sql/01_load.sql`. Loaded counts must equal received counts. | Load count output |
| 3 | Run the audit | `./scripts/run_audit.sh` | Exception register, run summary |
| 4 | Read control totals first | Billed, allowed, paid, patient responsibility, adjustment, and the variance on adjudicated claims. | `output/control_totals.csv` |
| 5 | Triage | Work CRITICAL before HIGH before MEDIUM. Within a severity, work by exposure descending. | Register updated |
| 6 | Route | Assign each exception to its owning queue (section 4). Do not fix another team's data yourself. | `assigned_queue` populated |
| 7 | Disposition | Set every exception to `RESOLVED`, `WAIVED` (with a written reason) or `CARRIED FORWARD`. Nothing is left `OPEN` past its SLA without escalation. | `disposition`, `resolved_ts` |
| 8 | Close | Confirm the run summary and the workbook cross-foot agree, then publish. | Signed-off workbook |

### 4. Escalation matrix

| Check | Defect | Owning queue | SLA | Escalate to |
|---|---|---|---|---|
| DQ-01 | Duplicate claim identifiers | Interface / EDI | 24h | Integration lead — hold the batch, do not release to the payer |
| DQ-02 | Duplicate billing fingerprint | Charge Entry | 24h | Compliance, if confirmed as duplicate billing |
| DQ-03 | Duplicate remittance posting | Cash Posting | 24h | Cash Posting supervisor — reversal must be booked before month-end close |
| DQ-04 | Orphaned remittance | Cash Posting | 24h | Payer, as an unidentified payment, if unmatched after 2 business days |
| DQ-05 | Missing remittance on a PAID claim | A/R Follow-up | 3d | A/R manager at 10 claims or USD 5,000 |
| DQ-06 | Claim-to-payment mismatch | Payment Variance | 24h | Payer Relations same day for any single variance above USD 500 |
| DQ-07 | Overpayment | Refunds / Credit Balance | 24h | Compliance — statutory refund clock starts on identification, not on review |
| DQ-08 | Allowed below contract | Contract Management | 3d | Payer Relations at 25 claims or USD 5,000, whichever comes first |
| DQ-09 | Unmapped payer | Payer Maintenance | 3d | Enrollment lead — claim cannot be routed until mapped |
| DQ-10 | Invalid provider NPI | Provider Data Management | 3d | Credentialing — claim will reject at the clearinghouse |
| DQ-11 | Temporal integrity break | Source System Owner | 5d | Interface team if the same feed repeats — indicates a mapping or timezone defect |
| DQ-12 | Missing or malformed field | Charge Entry | 3d | Charge Entry supervisor — claim is not submittable |

### 5. Rules that do not bend
1. **Never correct data in the extract.** Corrections are made in the source system and re-extracted, or the audit is auditing itself.
2. **Never close an exception without a disposition reason.** "Looks fine" is not a disposition.
3. **De-duplicate before reconciling.** A duplicated claim key fans out the payment join and corrupts every total on the report.
4. **Report an overpayment on the day it is found.** The refund clock runs from identification. It does not wait for the queue.
5. **One defect, one queue.** If a claim appears to fail two checks, apply the classification rules in the test plan; it belongs to one of them.
6. **Escalate a repeated defect, not just a large one.** The same defect in three consecutive runs is a process failure and goes to the source system owner regardless of dollar value.

### 6. Controls
- **Cross-foot.** The Excel workbook re-derives DQ-05, DQ-06 and DQ-07 independently of the SQL. The Dashboard difference column must read zero before the run is published.
- **Negative control.** After any change to a check, run `./tests/negative_control.sh`. A check that fires on clean data is wrong and must not ship.
- **Change control.** Any change to a tolerance, threshold or check logic is recorded in the test plan and the commit message, with the reason.

### 7. Definitions
**835 / remittance advice** — the payer's electronic explanation of payment.
**CARC** — Claim Adjustment Reason Code; the payer's stated reason for an adjustment.
**Allowed amount** — the contracted amount the payer recognises for the service.
**Contractual adjustment** — billed minus allowed; written off under contract, never billed to the patient.
**Orphaned record** — a payment posted against a claim identifier the billing system never issued.
