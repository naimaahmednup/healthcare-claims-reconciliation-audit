# Audit Findings — RUN-2026-08-29

**Population:** 25,230 claim rows and 23,649 remittance rows — 48,879 rows compared — for dates
of service 2025-07-01 to 2026-06-30.
**Result: FAIL at run level.** 1,380 exceptions across 25,140 unique claims (5.49%), all six
CRITICAL checks firing, USD 129,116.55 of exposure identified.

---

## 1. Control totals

| Measure | Value |
|---|---|
| Unique claims in scope | 25,140 |
| Claims with a remittance line | 23,454 |
| Claims with no remittance line | 1,686 |
| Billed | $4,459,219.00 |
| Allowed | $2,521,842.10 |
| Paid | $2,269,048.95 |
| Patient responsibility | $252,740.52 |
| Contractual adjustment | $1,653,118.26 |
| **Variance on adjudicated claims** | **−$21,307.73** |
| Absolute variance on adjudicated claims | $31,125.91 |

The net figure understates the problem, and it is worth being explicit about why. Positive and
negative variances offset: $31,125.91 of claims do not foot, but they net to −$21,307.73.
**Read the absolute figure when sizing the work, the net figure only when sizing the cash
position.**

The 1,686 claims with no remittance are mostly legitimate — claims the payer has not adjudicated
yet. Sixty of them are not: those carry a `PAID` status with no payment behind it (DQ-05).

## 2. Findings by class

| Class | Checks | Volume | Exposure |
|---|---|---|---|
| Duplication — claims | DQ-01, DQ-02 | 230 | $39,966.00 |
| Duplication — payments | DQ-03 | 75 | $7,536.98 |
| Payment variance | DQ-06, DQ-07 | 355 | $11,260.91 |
| Match integrity | DQ-04, DQ-05 | 180 | $25,793.45 |
| Contract variance | DQ-08 | 200 | $4,140.21 |
| Source data quality | DQ-09, DQ-10, DQ-11, DQ-12 | 340 | $40,419.00 |
| **Total** | | **1,380** | **$129,116.55** |

**Severity mix:** 780 CRITICAL (56.5%), 515 HIGH (37.3%), 85 MEDIUM (6.2%).

### What matters most

**1. 230 duplicate claims, and 140 of them are invisible to a key-based check.** The 90 exact
`claim_id` duplicates are an interface resend problem — annoying, contained, fixable at
ingestion. The other 140 are the same service billed under a *different* claim id, matched on
patient, provider, date of service, CPT and charge. Those can reach the payer and be paid twice,
which makes them a compliance exposure rather than a data-cleanliness one. $25,936.00 of charges.

**2. 355 claims where the money does not agree.** 310 fail the balance identity and 45 were paid
above the billed charge. Individually small — the median mismatch is $22.41, the largest $94.50 — but each one is
a claim whose true balance is unknown, and the 45 overpayments carry a statutory refund clock
that starts on identification.

**3. 120 payments posted against claims that do not exist.** $13,269.45 of cash with nothing to
apply it to. This ages as unapplied cash and, unlike the variance findings, it does not resolve
itself.

**4. Source data quality is the upstream cause of a quarter of everything.** 340 exceptions —
blank patient identifiers, malformed codes, unmapped payers, invalid NPIs, impossible dates —
none of which need an audit to catch. They need validation at entry. Every one of these claims
either rejects at the clearinghouse or cannot be reconciled at all.

## 3. Where the exceptions concentrate

| Payer | Claims | Exceptions | Per 1,000 claims | Exposure |
|---|---|---|---|---|
| Unmapped / invalid payer ids | 55 | 55 | 1,000.0 | $8,665.00 |
| TRICARE East | 752 | 49 | 65.2 | $3,994.93 |
| Humana Medicare Advantage | 1,684 | 99 | 58.8 | $11,928.39 |
| Aetna | 2,411 | 137 | 56.8 | $13,171.56 |
| Cigna | 1,735 | 97 | 55.9 | $6,637.78 |
| State Medicaid | 3,352 | 183 | 54.6 | $16,669.43 |
| Blue Cross Blue Shield | 4,537 | 242 | 53.3 | $22,584.12 |
| Workers Compensation Fund | 512 | 26 | 50.8 | $2,101.38 |
| Medicare Part B | 6,548 | 327 | 49.9 | $27,453.58 |
| UnitedHealthcare | 3,554 | 165 | 46.4 | $15,910.38 |

Medicare Part B has the largest raw exception count and the largest exposure, but it also has
the largest book — at 49.9 per 1,000 claims it is the *cleanest* payer in the file. Ranking by
volume would have sent the team to the wrong place. The genuine outlier is the unmapped payer
group, where the rate is 1,000 per 1,000 by definition: every claim with an unmappable payer id
is an exception.

Setting the unmapped group aside, the spread across real payers is narrow (46 to 65 per 1,000).
That pattern says the defects are **originating in our own feeds, not in any one payer's
behaviour** — a payer-specific problem would show as one row well clear of the others.

## 4. Recommendations

| # | Recommendation | Rationale | Owner |
|---|---|---|---|
| 1 | Enforce a duplicate guard at charge entry on patient + date of service + CPT + charge | Catches the 140 fingerprint duplicates before submission, where DQ-02 catches them only afterwards | Charge Entry / Application owner |
| 2 | Add an idempotency key of check number + claim + amount to the posting job | Removes DQ-03 as a class rather than reversing it monthly | Cash Posting / Application owner |
| 3 | Validate NPI, CPT, ICD-10, payer id and required fields at entry | 340 exceptions, all mechanically detectable at the point of capture | Application owner |
| 4 | Collapse resends on the claim key at ingestion | Removes DQ-01 at source; the `-R` batch suffix already identifies them | Interface / EDI |
| 5 | Run this suite daily rather than at close | The overpayment refund clock and the timely-filing clock both run from the event, not from the review | Data Operations |
| 6 | Report absolute variance alongside net in the monthly pack | Net variance hid 60% of the reconciliation work this run | Data Operations |

## 5. Confidence in these numbers

The findings are only worth as much as the checks that produced them, so both were tested.

- **Positive control:** the suite was scored against a ledger of 1,380 seeded defects and found
  all 1,380, with no false positives — 100% recall and 100% precision on every check.
- **Negative control:** the same 25,000 claims regenerated with no defects raised zero
  exceptions across all twelve checks.
- **Independent recomputation:** the Excel workbook re-derives DQ-05, DQ-06 and DQ-07 in native
  formulas from the raw remittance amounts, with no reference to the SQL result. The two agree
  on all 25,140 claims — zero disagreements.

Three iterations were needed to get there. The failures and their fixes are recorded in
[`TEST_PLAN.md`](TEST_PLAN.md) §7.1.
