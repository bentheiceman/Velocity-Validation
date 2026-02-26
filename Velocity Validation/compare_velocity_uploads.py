"""Compare velocity upload outputs.

Purpose
- Identify which DC/SKU rows changed between a prior upload file and a newly recalculated file.
- Designed for the HDS velocity reclassification workflow where outputs are filtered exports
  from the Snowflake summary table.

Inputs
- Old file: CSV/XLSX with JDA_ITEM, JDA_LOC, and a proposed velocity column.
- New file: same structure.

Output
- A CSV listing rows where the proposed velocity differs (or rows only in one side).

Usage
  python compare_velocity_uploads.py --old old.xlsx --new new.xlsx --out delta.csv

Notes
- Proposed velocity column is auto-detected from common names: PROPOSED_VELOCITY,
  PROPOSED_VELOCITY_, PROPOSED_VELOCITY__, PROPOSED_VELOCITY (case-insensitive),
  PROPOSED_VELOCITY_ (duplicate), or PROPOSED_VELOCITY-like.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


KEY_COLUMNS = ["JDA_ITEM", "JDA_LOC"]


def _read_table(path: Path) -> pd.DataFrame:
    if path.suffix.lower() in {".xlsx", ".xls"}:
        return pd.read_excel(path)
    if path.suffix.lower() == ".csv":
        return pd.read_csv(path)
    raise ValueError(f"Unsupported file type: {path.suffix}")


def _normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = [str(c).strip() for c in df.columns]
    return df


def _find_proposed_velocity_column(df: pd.DataFrame) -> str:
    colmap = {c.upper().strip(): c for c in df.columns}

    candidates = [
        "PROPOSED_VELOCITY",
        "PROPOSED_VELOCITY_",
        "PROPOSED_VELOCITY__",
        "PROPOSED VELOCITY",
        "PROPOSED VELOCITY_",
    ]
    for c in candidates:
        if c in colmap:
            return colmap[c]

    # Fallback: any column containing both words.
    for upper, original in colmap.items():
        if "PROPOSED" in upper and "VELOC" in upper:
            return original

    raise KeyError(
        "Could not find proposed velocity column. Expected one of: "
        + ", ".join(candidates)
        + " (case-insensitive)."
    )


def _coerce_key_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    missing = [c for c in KEY_COLUMNS if c not in df.columns]
    if missing:
        raise KeyError(f"Missing required columns: {missing}")

    for c in KEY_COLUMNS:
        df[c] = df[c].astype(str).str.strip()

    return df


def compare(old_path: Path, new_path: Path) -> tuple[pd.DataFrame, dict[str, int]]:
    old_df = _coerce_key_columns(_normalize_columns(_read_table(old_path)))
    new_df = _coerce_key_columns(_normalize_columns(_read_table(new_path)))

    old_prop = _find_proposed_velocity_column(old_df)
    new_prop = _find_proposed_velocity_column(new_df)

    old_keep = old_df[KEY_COLUMNS + [old_prop]].rename(columns={old_prop: "proposed_velocity_old"})
    new_keep = new_df[KEY_COLUMNS + [new_prop]].rename(columns={new_prop: "proposed_velocity_new"})

    merged = old_keep.merge(new_keep, on=KEY_COLUMNS, how="outer", indicator=True)

    merged["proposed_velocity_old"] = merged["proposed_velocity_old"].astype(str).str.strip().replace({"nan": ""})
    merged["proposed_velocity_new"] = merged["proposed_velocity_new"].astype(str).str.strip().replace({"nan": ""})

    changed = merged[
        (merged["_merge"] != "both")
        | (merged["proposed_velocity_old"] != merged["proposed_velocity_new"])
    ].copy()

    summary = {
        "old_rows": int(len(old_keep)),
        "new_rows": int(len(new_keep)),
        "changed_rows": int(len(changed)),
        "only_in_old": int((merged["_merge"] == "left_only").sum()),
        "only_in_new": int((merged["_merge"] == "right_only").sum()),
        "different_velocity": int(
            ((merged["_merge"] == "both") & (merged["proposed_velocity_old"] != merged["proposed_velocity_new"])).sum()
        ),
    }

    # Make output easier to scan.
    changed = changed.sort_values(["JDA_LOC", "JDA_ITEM"], kind="stable")

    return changed, summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Diff two velocity upload outputs (old vs new).")
    parser.add_argument("--old", required=True, help="Path to prior upload file (.csv/.xlsx)")
    parser.add_argument("--new", required=True, help="Path to newly recalculated file (.csv/.xlsx)")
    parser.add_argument("--out", required=True, help="Where to write delta CSV")
    args = parser.parse_args()

    old_path = Path(args.old)
    new_path = Path(args.new)
    out_path = Path(args.out)

    changed, summary = compare(old_path, new_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    changed.to_csv(out_path, index=False)

    print("Compare complete")
    for k, v in summary.items():
        print(f"- {k}: {v}")
    print(f"Wrote: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
