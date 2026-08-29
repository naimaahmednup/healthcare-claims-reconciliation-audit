"""
Synthetic RCM dataset generator
Healthcare Claims Reconciliation & Data Quality Audit

Produces three CSV extracts that mimic what a Revenue Cycle Management (RCM)
operations team receives every day:

  1. claims_source.csv        - claim headers from the practice management /
                                billing system (the 837 professional feed)
  2. payments_remittance.csv  - payment lines posted from payer remittance
                                advice (the 835 ERA feed)
  3. payer_reference.csv      - the payer master used for referential checks

No real patient data is used. Everything is generated from a fixed random seed,
so the dataset is byte-for-byte reproducible.

Two modes:
  --defects on   (default) inject a known, ledgered set of data quality defects
  --defects off  emit a clean dataset used as the negative control for the
                 audit suite (every check must return zero rows)

Usage:
  python scripts/generate_data.py --claims 25000 --seed 20260829 --defects on
"""

import argparse
import csv
import os
import random
from datetime import date, timedelta
from decimal import Decimal

# --------------------------------------------------------------------------
# Reference data
# --------------------------------------------------------------------------

PAYERS = [
    # payer_id,        payer_name,                        payer_type,   base_rate, share
    ("PAY-MCR-001", "Medicare Part B",                    "MEDICARE",   0.62, 0.26),
    ("PAY-MCD-002", "State Medicaid",                     "MEDICAID",   0.48, 0.13),
    ("PAY-BCB-003", "Blue Cross Blue Shield",             "COMMERCIAL", 0.71, 0.18),
    ("PAY-UHC-004", "UnitedHealthcare",                   "COMMERCIAL", 0.68, 0.14),
    ("PAY-AET-005", "Aetna",                              "COMMERCIAL", 0.69, 0.10),
    ("PAY-CIG-006", "Cigna",                              "COMMERCIAL", 0.67, 0.07),
    ("PAY-HUM-007", "Humana Medicare Advantage",          "MEDICARE",   0.64, 0.07),
    ("PAY-TRC-008", "TRICARE East",                       "GOVERNMENT", 0.60, 0.03),
    ("PAY-WCP-009", "Workers Compensation Fund",          "WORKCOMP",   0.75, 0.02),
]

# CPT code -> (description, charge in cents)
CPT_CHARGES = {
    "99213": ("Office visit, established patient, 20-29 min",   18500),
    "99214": ("Office visit, established patient, 30-39 min",   26400),
    "99215": ("Office visit, established patient, 40-54 min",   36900),
    "99203": ("Office visit, new patient, 30-44 min",           24800),
    "99204": ("Office visit, new patient, 45-59 min",           37500),
    "80053": ("Comprehensive metabolic panel",                   6200),
    "85025": ("Complete blood count with differential",          4800),
    "36415": ("Routine venipuncture",                            1800),
    "71046": ("Chest X-ray, 2 views",                            9700),
    "73630": ("Foot X-ray, complete",                            8900),
    "93000": ("Electrocardiogram, complete",                     7400),
    "20610": ("Arthrocentesis, major joint",                    22300),
    "12001": ("Simple wound repair, 2.5 cm or less",            19600),
    "87635": ("SARS-CoV-2 amplified probe technique",           10200),
    "90471": ("Immunization administration",                     4100),
    "99396": ("Preventive visit, established, 40-64 yrs",       31200),
}

ICD10 = ["E11.9", "I10", "J06.9", "M54.50", "Z00.00", "R51.9",
         "K21.9", "F41.1", "J45.909", "N39.0", "E78.5", "M25.561"]

# CARC = Claim Adjustment Reason Code (X12 835)
DENIAL_CARC = [
    ("16",  "Claim lacks information or has submission/billing error"),
    ("18",  "Exact duplicate claim or service"),
    ("27",  "Expenses incurred after coverage terminated"),
    ("29",  "Time limit for filing has expired"),
    ("50",  "Non-covered service, not deemed a medical necessity"),
    ("97",  "Benefit included in payment for another service"),
    ("197", "Precertification / authorization absent"),
]

FACILITIES = [
    ("FAC-01", "Riverside Family Medicine",   "11"),
    ("FAC-02", "Northgate Internal Medicine", "11"),
    ("FAC-03", "Lakeside Urgent Care",        "20"),
    ("FAC-04", "Summit Orthopedics Clinic",   "11"),
    ("FAC-05", "Harborview Outpatient Lab",   "81"),
]

SOURCE_SYSTEMS = ["EPIC_PB", "ATHENA_PM", "ECW_BILLING"]

DOS_START = date(2025, 7, 1)
DOS_END = date(2026, 6, 30)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def npi_check_digit(nine_digits: str) -> str:
    """NPI check digit: Luhn over the 80840 prefix + the 9 base digits."""
    payload = "80840" + nine_digits
    total = 0
    for i, ch in enumerate(reversed(payload)):
        d = int(ch)
        if i % 2 == 0:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return str((10 - (total % 10)) % 10)


def make_npi(rng) -> str:
    base = "".join(str(rng.randint(0, 9)) for _ in range(9))
    return base + npi_check_digit(base)


def money(cents: int) -> str:
    return f"{Decimal(cents) / 100:.2f}"


def weighted_choice(rng, items, weights):
    return rng.choices(items, weights=weights, k=1)[0]


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------

class Ledger:
    """Records every defect intentionally injected, so the audit suite can be
    scored against ground truth instead of against its own output."""

    def __init__(self):
        self.rows = []

    def add(self, check_id, entity, key, description):
        self.rows.append({
            "defect_ref": f"INJ-{len(self.rows) + 1:04d}",
            "check_id": check_id,
            "entity_type": entity,
            "entity_key": key,
            "description": description,
        })

    def write(self, path):
        with open(path, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=[
                "defect_ref", "check_id", "entity_type", "entity_key", "description"])
            w.writeheader()
            w.writerows(self.rows)


def build(n_claims, seed, inject):
    rng = random.Random(seed)
    ledger = Ledger()

    providers = []
    for i in range(40):
        providers.append({
            "npi": make_npi(rng),
            "name": f"Provider {i + 1:02d}",
        })

    payer_ids = [p[0] for p in PAYERS]
    payer_weights = [p[4] for p in PAYERS]
    payer_rate = {p[0]: p[3] for p in PAYERS}
    payer_name = {p[0]: p[1] for p in PAYERS}

    cpts = list(CPT_CHARGES.keys())
    dos_span = (DOS_END - DOS_START).days

    claims = []
    remits = []

    # ---- clean core dataset -------------------------------------------------
    # Patient/DOS/CPT combinations are drawn without replacement so the clean
    # dataset contains no accidental logical duplicates. That keeps the ground
    # truth exact: every duplicate the audit finds was put there on purpose.
    seen_combo = set()

    for i in range(1, n_claims + 1):
        claim_id = f"CLM-2026-{i:06d}"

        while True:
            patient_id = f"PT-{rng.randint(1, 9000):05d}"
            dos = DOS_START + timedelta(days=rng.randint(0, dos_span))
            cpt = weighted_choice(rng, cpts, [12, 10, 4, 6, 4, 9, 9, 7, 5, 3, 5, 3, 3, 4, 6, 5])
            combo = (patient_id, dos, cpt)
            if combo not in seen_combo:
                seen_combo.add(combo)
                break

        prov = rng.choice(providers)
        fac = rng.choice(FACILITIES)
        payer_id = weighted_choice(rng, payer_ids, payer_weights)
        charge = CPT_CHARGES[cpt][1]
        units = 1 if rng.random() > 0.08 else rng.randint(2, 3)
        billed = charge * units

        submit = dos + timedelta(days=rng.randint(1, 10))

        # contracted expectation, with a little per-claim contract noise
        rate = payer_rate[payer_id] * rng.uniform(0.97, 1.03)
        expected_allowed = int(round(billed * rate))

        # claim lifecycle
        roll = rng.random()
        if roll < 0.055:
            status = "DENIED"
        elif roll < 0.115:
            status = "PENDING"        # payer has not adjudicated yet
        else:
            status = "PAID"

        claims.append({
            "claim_id": claim_id,
            "patient_id": patient_id,
            "encounter_id": f"ENC-{i:07d}",
            "provider_npi": prov["npi"],
            "facility_id": fac[0],
            "place_of_service": fac[2],
            "payer_id": payer_id,
            "payer_name": payer_name[payer_id],
            "date_of_service": dos.isoformat(),
            "claim_submit_date": submit.isoformat(),
            "cpt_code": cpt,
            "icd10_code": rng.choice(ICD10),
            "units": units,
            "billed_amount": money(billed),
            "expected_allowed_amount": money(expected_allowed),
            "claim_status": status,
            "source_system": rng.choice(SOURCE_SYSTEMS),
            "ingest_batch_id": f"BATCH-{submit.strftime('%Y%m%d')}",
            "_billed_cents": billed,
            "_expected_cents": expected_allowed,
            "_dos": dos,
            "_submit": submit,
        })

    # ---- remittance rows ----------------------------------------------------
    remit_seq = 0

    def new_remit(claim, allowed_c, paid_c, patient_c, adj_c, carc, carc_desc,
                  status_code, remit_dt, check_no):
        nonlocal remit_seq
        remit_seq += 1
        return {
            "remit_id": f"RMT-{remit_seq:07d}",
            "claim_id": claim["claim_id"],
            "payer_id": claim["payer_id"],
            "check_eft_number": check_no,
            "remit_date": remit_dt.isoformat(),
            "allowed_amount": money(allowed_c),
            "paid_amount": money(paid_c),
            "patient_responsibility": money(patient_c),
            "contractual_adjustment": money(adj_c),
            "carc_code": carc,
            "carc_description": carc_desc,
            "claim_status_code": status_code,
            "posted_flag": "Y",
            "ingest_batch_id": f"ERA-{remit_dt.strftime('%Y%m%d')}",
            "_claim": claim,
        }

    for claim in claims:
        if claim["claim_status"] == "PENDING":
            continue

        remit_dt = claim["_submit"] + timedelta(days=rng.randint(14, 60))
        check_no = f"EFT{rng.randint(100000, 999999)}"
        billed = claim["_billed_cents"]

        if claim["claim_status"] == "DENIED":
            carc, desc = rng.choice(DENIAL_CARC)
            remits.append(new_remit(claim, 0, 0, 0, billed, carc, desc,
                                    "4", remit_dt, check_no))
        else:
            allowed = claim["_expected_cents"]
            # patient responsibility: deductible / coinsurance / copay
            pr_roll = rng.random()
            if pr_roll < 0.45:
                patient = 0
            elif pr_roll < 0.80:
                patient = int(round(allowed * rng.choice([0.10, 0.20])))
            else:
                patient = rng.choice([1500, 2000, 2500, 3500, 5000])
                patient = min(patient, allowed)
            paid = allowed - patient
            adj = billed - allowed
            remits.append(new_remit(claim, allowed, paid, patient, adj, "45",
                                    "Charge exceeds fee schedule/contracted rate",
                                    "1", remit_dt, check_no))

    if not inject:
        return claims, remits, ledger

    # ----------------------------------------------------------------------
    # Defect injection. Each block targets one check in the audit suite and
    # writes what it did to the ledger.
    # ----------------------------------------------------------------------
    claim_index = {c["claim_id"]: c for c in claims}
    paid_claims = [c for c in claims if c["claim_status"] == "PAID"]
    remit_by_claim = {}
    for r in remits:
        remit_by_claim.setdefault(r["claim_id"], []).append(r)

    used = set()

    def pick(pool, n):
        """Sample rows that no earlier injection block has touched, so one row
        never carries two defects and the ground truth stays additive."""
        out = []
        candidates = [x for x in pool if x["claim_id"] not in used]
        rng.shuffle(candidates)
        for c in candidates[:n]:
            used.add(c["claim_id"])
            out.append(c)
        return out

    # DQ-01 exact duplicate claim_id (same key re-sent by the interface engine)
    for c in pick(claims, 90):
        dup = dict(c)
        dup["source_system"] = "ATHENA_PM"
        dup["ingest_batch_id"] = c["ingest_batch_id"] + "-R"
        claims.append(dup)
        ledger.add("DQ-01", "claim", c["claim_id"],
                   "Exact claim_id re-submitted under a resend batch")

    # DQ-02 logical duplicate: new claim_id, identical billing fingerprint
    for idx, c in enumerate(pick(claims[:n_claims], 140), start=1):
        dup = dict(c)
        dup["claim_id"] = f"CLM-2026-9{idx:05d}"
        dup["encounter_id"] = f"ENC-9{idx:06d}"
        dup["claim_submit_date"] = (c["_submit"] + timedelta(days=rng.randint(1, 6))).isoformat()
        dup["source_system"] = rng.choice(SOURCE_SYSTEMS)
        dup["claim_status"] = "PENDING"   # a resubmission is not adjudicated
        claims.append(dup)
        claim_index[dup["claim_id"]] = dup
        ledger.add("DQ-02", "claim", dup["claim_id"],
                   f"Duplicate billing fingerprint of {c['claim_id']} "
                   f"(same patient, DOS, CPT, charge) under a new claim id")

    # DQ-03 duplicate remittance posting (same claim posted twice)
    for c in pick(paid_claims, 75):
        src = remit_by_claim.get(c["claim_id"])
        if not src:
            continue
        dup = dict(src[0])
        remit_seq += 1
        dup["remit_id"] = f"RMT-{remit_seq:07d}"
        dup["ingest_batch_id"] = dup["ingest_batch_id"] + "-R"
        remits.append(dup)
        ledger.add("DQ-03", "remit", dup["remit_id"],
                   f"Second posting of claim {c['claim_id']} under the same check/EFT")

    # DQ-04 orphaned remittance (payment for a claim that is not in the source)
    for i in range(120):
        template = rng.choice(paid_claims)
        remit_seq += 1
        ghost_id = f"CLM-2026-8{i + 1:05d}"
        remit_dt = template["_submit"] + timedelta(days=rng.randint(14, 60))
        allowed = template["_expected_cents"]
        remits.append({
            "remit_id": f"RMT-{remit_seq:07d}",
            "claim_id": ghost_id,
            "payer_id": template["payer_id"],
            "check_eft_number": f"EFT{rng.randint(100000, 999999)}",
            "remit_date": remit_dt.isoformat(),
            "allowed_amount": money(allowed),
            "paid_amount": money(allowed),
            "patient_responsibility": money(0),
            "contractual_adjustment": money(template["_billed_cents"] - allowed),
            "carc_code": "45",
            "carc_description": "Charge exceeds fee schedule/contracted rate",
            "claim_status_code": "1",
            "posted_flag": "Y",
            "ingest_batch_id": f"ERA-{remit_dt.strftime('%Y%m%d')}",
            "_claim": None,
        })
        ledger.add("DQ-04", "remit", f"RMT-{remit_seq:07d}",
                   f"Remittance posted against claim {ghost_id}, absent from the claims feed")

    # DQ-05 paid-status claim with no remittance at all
    for c in pick(paid_claims, 60):
        for r in list(remits):
            if r["claim_id"] == c["claim_id"]:
                remits.remove(r)
        ledger.add("DQ-05", "claim", c["claim_id"],
                   "Claim carries PAID status but no remittance line was received")

    # DQ-06 claim-to-payment amount mismatch (balance identity broken)
    # The drift is kept strictly inside 0 < paid < billed. A payment above the
    # charge is an overpayment and belongs to DQ-07; a payment driven to zero
    # would leave the balance untouched on a claim that was already paying
    # nothing. Both would blur the two defect classes and make the counts
    # unusable as evidence, so claims with no room to move either way are
    # released back to the pool rather than half-injected.
    injected_mismatch = 0
    for c in pick(paid_claims, 500):
        if injected_mismatch >= 310:
            used.discard(c["claim_id"])
            continue
        rs = [r for r in remits if r["claim_id"] == c["claim_id"]]
        if not rs:
            used.discard(c["claim_id"])
            continue
        r = rs[0]
        paid_c = int(round(float(r["paid_amount"]) * 100))
        headroom_up = c["_billed_cents"] - paid_c - 100
        can_up = headroom_up > 200
        can_down = paid_c - 100 > 150
        if can_up and (not can_down or rng.random() < 0.5):
            drift = rng.randint(150, min(9500, headroom_up))
        elif can_down:
            drift = -rng.randint(150, min(9500, paid_c - 100))
        else:
            used.discard(c["claim_id"])
            continue
        r["paid_amount"] = money(paid_c + drift)
        ledger.add("DQ-06", "claim", c["claim_id"],
                   f"Paid + patient responsibility + adjustment no longer balances to the "
                   f"billed amount on claim {c['claim_id']}")
        injected_mismatch += 1

    # DQ-07 overpayment: paid exceeds the billed charge
    for c in pick(paid_claims, 45):
        rs = [r for r in remits if r["claim_id"] == c["claim_id"]]
        if not rs:
            continue
        r = rs[0]
        over = c["_billed_cents"] + rng.randint(500, 6000)
        r["paid_amount"] = money(over)
        r["allowed_amount"] = money(over)
        r["contractual_adjustment"] = money(0)
        r["patient_responsibility"] = money(0)
        ledger.add("DQ-07", "claim", c["claim_id"],
                   f"Paid amount exceeds the billed charge on claim {c['claim_id']}")

    # DQ-08 allowed amount below the contracted expectation (underpayment risk)
    for c in pick(paid_claims, 200):
        rs = [r for r in remits if r["claim_id"] == c["claim_id"]]
        if not rs:
            continue
        r = rs[0]
        shortfall = int(round(c["_expected_cents"] * rng.uniform(0.72, 0.88)))
        r["allowed_amount"] = money(shortfall)
        pr = int(round(float(r["patient_responsibility"]) * 100))
        pr = min(pr, shortfall)
        r["patient_responsibility"] = money(pr)
        r["paid_amount"] = money(shortfall - pr)
        r["contractual_adjustment"] = money(c["_billed_cents"] - shortfall)
        ledger.add("DQ-08", "claim", c["claim_id"],
                   f"Allowed amount is more than 10% below the contracted expectation "
                   f"on claim {c['claim_id']}")

    # DQ-09 payer id not present in the payer master
    bad_payers = ["PAY-XXX-999", "PAY-UNK-000", "", "PAY-BCB-03"]
    for c in pick(claims[:n_claims], 55):
        c["payer_id"] = rng.choice(bad_payers)
        c["payer_name"] = "UNMAPPED"
        ledger.add("DQ-09", "claim", c["claim_id"],
                   "Payer id is blank or absent from the payer master")

    # DQ-10 malformed provider NPI
    for c in pick(claims[:n_claims], 70):
        style = rng.random()
        if style < 0.4:
            c["provider_npi"] = c["provider_npi"][:9]              # 9 digits
        elif style < 0.7:
            c["provider_npi"] = c["provider_npi"][:9] + "X"        # non-numeric
        else:
            base = c["provider_npi"][:9]                            # bad check digit
            wrong = str((int(c["provider_npi"][9]) + 3) % 10)
            c["provider_npi"] = base + wrong
        ledger.add("DQ-10", "claim", c["claim_id"],
                   "Provider NPI fails the 10-digit Luhn standard")

    # DQ-11 temporal integrity breaks
    for c in pick(claims[:n_claims], 85):
        mode = rng.random()
        if mode < 0.45:
            rs = [r for r in remits if r["claim_id"] == c["claim_id"]]
            if rs:
                rs[0]["remit_date"] = (c["_dos"] - timedelta(days=rng.randint(2, 40))).isoformat()
                ledger.add("DQ-11", "claim", c["claim_id"],
                           "Remittance dated before the date of service")
                continue
            mode = 0.9
        if mode < 0.75:
            c["claim_submit_date"] = (c["_dos"] - timedelta(days=rng.randint(1, 15))).isoformat()
            ledger.add("DQ-11", "claim", c["claim_id"],
                       "Claim submitted before the date of service")
        else:
            c["date_of_service"] = (date(2026, 8, 29) + timedelta(days=rng.randint(5, 90))).isoformat()
            ledger.add("DQ-11", "claim", c["claim_id"],
                       "Date of service is in the future")

    # DQ-12 missing mandatory fields / malformed codes
    for c in pick(claims[:n_claims], 130):
        field = rng.choice(["cpt_code", "icd10_code", "date_of_service",
                            "billed_amount", "patient_id"])
        if field == "cpt_code":
            c["cpt_code"] = rng.choice(["", "9921", "ABCDE", "99213A"])
            note = "CPT code blank or not a valid 5-character code"
        elif field == "icd10_code":
            c["icd10_code"] = rng.choice(["", "XX999", "E119"])
            note = "ICD-10 code blank or malformed"
        elif field == "date_of_service":
            c["date_of_service"] = ""
            note = "Date of service is blank"
        elif field == "billed_amount":
            c["billed_amount"] = rng.choice(["0.00", "-125.00"])
            note = "Billed amount is zero or negative"
        else:
            c["patient_id"] = ""
            note = "Patient identifier is blank"
        ledger.add("DQ-12", "claim", c["claim_id"], note)

    return claims, remits, ledger


# --------------------------------------------------------------------------

CLAIM_COLS = ["claim_id", "patient_id", "encounter_id", "provider_npi", "facility_id",
              "place_of_service", "payer_id", "payer_name", "date_of_service",
              "claim_submit_date", "cpt_code", "icd10_code", "units", "billed_amount",
              "expected_allowed_amount", "claim_status", "source_system", "ingest_batch_id"]

REMIT_COLS = ["remit_id", "claim_id", "payer_id", "check_eft_number", "remit_date",
              "allowed_amount", "paid_amount", "patient_responsibility",
              "contractual_adjustment", "carc_code", "carc_description",
              "claim_status_code", "posted_flag", "ingest_batch_id"]


def write_csv(path, cols, rows):
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--claims", type=int, default=25000)
    ap.add_argument("--seed", type=int, default=20260829)
    ap.add_argument("--defects", choices=["on", "off"], default="on")
    ap.add_argument("--outdir", default="data/raw")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    os.makedirs("data/reference", exist_ok=True)

    claims, remits, ledger = build(args.claims, args.seed, args.defects == "on")

    # deterministic ordering so the CSVs are reproducible
    claims.sort(key=lambda c: (c["claim_id"], c["ingest_batch_id"]))
    remits.sort(key=lambda r: r["remit_id"])

    write_csv(os.path.join(args.outdir, "claims_source.csv"), CLAIM_COLS, claims)
    write_csv(os.path.join(args.outdir, "payments_remittance.csv"), REMIT_COLS, remits)

    with open("data/reference/payer_reference.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["payer_id", "payer_name", "payer_type", "contract_rate"])
        for pid, name, ptype, rate, _ in PAYERS:
            w.writerow([pid, name, ptype, f"{rate:.2f}"])

    with open("data/reference/cpt_reference.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["cpt_code", "cpt_description", "standard_charge"])
        for code, (desc, charge) in sorted(CPT_CHARGES.items()):
            w.writerow([code, desc, money(charge)])

    if args.defects == "on":
        ledger.write(os.path.join(args.outdir, "_injected_defect_ledger.csv"))

    print(f"claims rows written   : {len(claims):,}")
    print(f"remittance rows written: {len(remits):,}")
    print(f"defects injected       : {len(ledger.rows):,}")


if __name__ == "__main__":
    main()
