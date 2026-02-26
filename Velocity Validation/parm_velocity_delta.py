"""Compare Thursday velocity recommendations vs current system velocity from Parm report.

Goal
- Validate whether recommended velocity updates have been applied in the system.

Typical inputs
- Thursday recommendations export (CSV): has JDA_ITEM, JDA_LOC, PROPOSED_VELOCITY, plus metadata.
- Parm Management Weekly Report (XLSX): use sheet 'TW Data' for current system state,
  with ITEM, DC NUMBER, and VELOCITY.

Output
- Excel file with:
  - Summary tab (counts + % not updated)
  - Not-updated tab (rows where system velocity != proposed, or missing in Parm)

Usage
  python parm_velocity_delta.py --thursday recs.csv --parm report.xlsx --out delta.xlsx
"""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


THURSDAY_KEY_COLUMNS = ["JDA_ITEM", "JDA_LOC"]
DEFAULT_PARM_SHEET = "TW Data"


def _read_thursday(path: Path) -> pd.DataFrame:
    if path.suffix.lower() != ".csv":
        # Keep it flexible, but most exports are CSV.
        if path.suffix.lower() in {".xlsx", ".xls"}:
            df = pd.read_excel(path, dtype=str)
        else:
            raise ValueError(f"Unsupported Thursday file type: {path.suffix}")
    else:
        df = pd.read_csv(path, dtype=str)

    df.columns = [str(c).strip() for c in df.columns]
    missing = [c for c in THURSDAY_KEY_COLUMNS if c not in df.columns]
    if missing:
        raise KeyError(f"Thursday file missing required columns: {missing}")

    for c in THURSDAY_KEY_COLUMNS:
        df[c] = df[c].astype(str).str.strip()

    # Normalize velocity column name.
    if "PROPOSED_VELOCITY" not in df.columns:
        # allow common variants
        candidates = [c for c in df.columns if "PROPOSED" in c.upper() and "VELOC" in c.upper()]
        if not candidates:
            raise KeyError("Thursday file is missing a proposed velocity column (e.g., PROPOSED_VELOCITY).")
        df = df.rename(columns={candidates[0]: "PROPOSED_VELOCITY"})

    df["PROPOSED_VELOCITY"] = df["PROPOSED_VELOCITY"].astype(str).str.strip()
    return df


def _read_parm(path: Path, sheet: str) -> pd.DataFrame:
    if path.suffix.lower() not in {".xlsx", ".xls"}:
        raise ValueError("Parm report must be an .xlsx/.xls file")

    df = pd.read_excel(path, sheet_name=sheet, dtype=str)
    df.columns = [str(c).strip() for c in df.columns]

    # Coerce key columns (default names in TW Data).
    required = ["ITEM", "DC NUMBER", "VELOCITY"]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise KeyError(
            f"Parm sheet '{sheet}' missing required columns: {missing}. "
            "Make sure you're using the 'TW Data' sheet (or pass --sheet)."
        )

    df["ITEM"] = df["ITEM"].astype(str).str.strip()
    df["DC NUMBER"] = df["DC NUMBER"].astype(str).str.strip()
    df["VELOCITY"] = df["VELOCITY"].astype(str).str.strip()

    # De-dupe defensively: keep last occurrence per item+dc.
    df = df.drop_duplicates(subset=["ITEM", "DC NUMBER"], keep="last")

    return df


def build_delta(thursday: pd.DataFrame, parm: pd.DataFrame) -> tuple[pd.DataFrame, dict[str, object]]:
    th = thursday.copy()
    th = th.rename(columns={"JDA_ITEM": "ITEM", "JDA_LOC": "DC NUMBER"})

    keep_parm_cols = [
        "ITEM",
        "DC NUMBER",
        "VELOCITY",
        "ITEM DESCRIPTION",
        "VENDOR NUMBER",
        "VENDOR NAME",
        "DC NAME",
        "ANALYST",
        "MCAT",
        "PCAT",
        "IMPORT FLAG",
        "First Receipt Flag",
        "Source Type",
    ]
    parm_keep = parm[[c for c in keep_parm_cols if c in parm.columns]].copy()

    merged = th.merge(parm_keep, on=["ITEM", "DC NUMBER"], how="left", indicator=True)

    merged["parm_velocity"] = merged["VELOCITY"].astype(str).str.strip().replace({"nan": ""})
    merged["proposed_velocity"] = merged["PROPOSED_VELOCITY"].astype(str).str.strip().replace({"nan": ""})

    merged["status"] = "UPDATED_MATCH"
    merged.loc[merged["_merge"] == "left_only", "status"] = "MISSING_IN_PARM"
    merged.loc[
        (merged["_merge"] == "both") & (merged["parm_velocity"] != merged["proposed_velocity"]),
        "status",
    ] = "NOT_UPDATED_MISMATCH"

    not_updated = merged[merged["status"].isin(["MISSING_IN_PARM", "NOT_UPDATED_MISMATCH"])].copy()

    # Friendly ordering.
    ordered_cols = [
        "ITEM",
        "DC NUMBER",
        "proposed_velocity",
        "parm_velocity",
        "SAP_VELOCITY",
        "SERVICE_LEVEL",
        "VELOCITY_REASON",
        "status",
        "ITEM DESCRIPTION",
        "VENDOR NUMBER",
        "VENDOR NAME",
        "DC NAME",
        "ANALYST",
        "MCAT",
        "PCAT",
        "IMPORT FLAG",
        "First Receipt Flag",
        "Source Type",
    ]
    ordered_cols = [c for c in ordered_cols if c in not_updated.columns]
    not_updated = not_updated[ordered_cols]

    total = int(len(th))
    missing_in_parm = int((merged["status"] == "MISSING_IN_PARM").sum())
    mismatch = int((merged["status"] == "NOT_UPDATED_MISMATCH").sum())
    updated = int((merged["status"] == "UPDATED_MATCH").sum())
    not_updated_count = missing_in_parm + mismatch

    pct_not_updated = (not_updated_count / total * 100.0) if total else 0.0

    summary = {
        "thursday_rows": total,
        "updated_match_rows": updated,
        "not_updated_mismatch_rows": mismatch,
        "missing_in_parm_rows": missing_in_parm,
        "not_updated_total_rows": not_updated_count,
        "pct_not_updated": round(pct_not_updated, 2),
    }

    # Stable sort for review.
    not_updated = not_updated.sort_values(["DC NUMBER", "ITEM"], kind="stable")

    return not_updated, summary


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare Thursday velocity recommendations to Parm report (TW Data) and output not-updated deltas."
    )
    parser.add_argument("--thursday", required=True, help="Thursday recommendation export (.csv/.xlsx)")
    parser.add_argument("--parm", required=True, help="Parm Management Weekly Report (.xlsx)")
    parser.add_argument("--out", required=True, help="Output .xlsx path")
    parser.add_argument("--sheet", default=DEFAULT_PARM_SHEET, help=f"Parm sheet name (default: {DEFAULT_PARM_SHEET})")

    args = parser.parse_args()

    thursday_path = Path(args.thursday)
    parm_path = Path(args.parm)
    out_path = Path(args.out)

    th = _read_thursday(thursday_path)
    parm = _read_parm(parm_path, sheet=args.sheet)

    not_updated, summary = build_delta(th, parm)

    out_path.parent.mkdir(parents=True, exist_ok=True)

    summary_df = pd.DataFrame(
        [
            {"metric": k, "value": v}
            for k, v in summary.items()
        ]
    )

    with pd.ExcelWriter(out_path, engine="openpyxl") as writer:
        summary_df.to_excel(writer, sheet_name="summary", index=False)
        not_updated.to_excel(writer, sheet_name="not_updated", index=False)

    print("Parm delta complete")
    for k, v in summary.items():
        print(f"- {k}: {v}")
    print(f"Wrote: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
