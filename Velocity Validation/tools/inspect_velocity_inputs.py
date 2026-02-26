import pandas as pd
from pathlib import Path

THURSDAY_PATH = Path(r"C:\Users\1015723\Downloads\HDS_velocity_New_SKU_bucket_excluded.csv")
PARM_PATH = Path(r"C:\Users\1015723\OneDrive - HD Supply, Inc\Desktop\Parm Management Weekly Report FW1_working_20260209_110642.xlsx")


def main() -> None:
    print("Exists Thursday:", THURSDAY_PATH.exists(), THURSDAY_PATH)
    print("Exists Parm:", PARM_PATH.exists(), PARM_PATH)

    th = pd.read_csv(THURSDAY_PATH, dtype=str)
    print("\nThursday shape:", th.shape)
    print("Thursday columns:", list(th.columns))
    print("Thursday head:")
    print(th.head(5).to_string(index=False))

    xl = pd.ExcelFile(PARM_PATH)
    print("\nParm sheets:", xl.sheet_names)
    parmdf = xl.parse(xl.sheet_names[0], dtype=str)
    print("Parm shape:", parmdf.shape)
    print("Parm columns:", list(parmdf.columns))
    print("Parm head:")
    print(parmdf.head(5).to_string(index=False))


if __name__ == "__main__":
    main()
