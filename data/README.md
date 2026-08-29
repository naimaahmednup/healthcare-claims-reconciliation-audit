# Data

All files here are synthetic and generated from a fixed seed. No real patient, provider or
payer data is used, and nothing here is PHI.

| File | Rows | What it is |
|---|---|---|
| `raw/claims_source.csv` | 25,230 | Claim headers from the billing system (837-professional equivalent) |
| `raw/payments_remittance.csv` | 23,649 | Payment lines posted from payer remittance (835 ERA equivalent) |
| `raw/_injected_defect_ledger.csv` | 1,380 | Ground truth: every defect the generator planted, used to score the audit suite |
| `reference/payer_reference.csv` | 9 | Payer master — the referential authority for DQ-09 |
| `reference/cpt_reference.csv` | 16 | Charge master |

Regenerate with:

```bash
python3 scripts/generate_data.py --claims 25000 --seed 20260829 --defects on
```

The seed is fixed, so this reproduces the committed files exactly. Passing `--defects off`
produces the clean dataset used by the negative control.

Field-by-field definitions are in [`../docs/DATA_DICTIONARY.md`](../docs/DATA_DICTIONARY.md).

**The defect ledger is not an input to the audit.** No check reads it. It exists only so the
suite can be scored on recall and precision after the fact.
