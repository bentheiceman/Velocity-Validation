"""
HDS Velocity Reclassification Workflow Diagram
Generates .png and .pdf with clean layout, no overlapping, readable text.
"""

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
import os

# ── Settings ──────────────────────────────────────────────────────────────────
FIG_W, FIG_H = 22, 30
DPI = 200
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Colors
C_PARAM   = "#e8e8e8"   # light gray
C_SOURCE  = "#dce6f1"   # light blue-gray
C_HDP     = "#fff3cd"   # yellow highlight (NEW)
C_UNIVERSE= "#f0f0f0"   # light gray
C_FILTER  = "#d6eaf8"   # pale blue
C_G1      = "#d4edda"   # green
C_G2      = "#cce5ff"   # blue
C_G3      = "#f8d7da"   # red/pink
C_SSCOV   = "#fce4ec"   # light pink
C_OUTPUT  = "#e2d5f1"   # purple
C_ARROW   = "#444444"
C_TEXT    = "#1a1a1a"    # near-black for all text (high contrast)
C_BORDER_HDP = "#e6a800" # darker gold border for NEW items

def draw_box(ax, x, y, w, h, text, facecolor, edgecolor="#666666", fontsize=8,
             lw=1.5, bold=False, text_color=None):
    """Draw a rounded box with centered text."""
    tc = text_color or C_TEXT
    box = FancyBboxPatch(
        (x - w/2, y - h/2), w, h,
        boxstyle="round,pad=0.02",
        facecolor=facecolor, edgecolor=edgecolor, linewidth=lw,
        transform=ax.transData, zorder=2
    )
    ax.add_patch(box)
    weight = "bold" if bold else "normal"
    ax.text(x, y, text, ha="center", va="center", fontsize=fontsize,
            color=tc, fontweight=weight, zorder=3,
            linespacing=1.35, family="sans-serif")


def draw_section_label(ax, x, y, text, fontsize=11):
    """Draw a section header label."""
    ax.text(x, y, text, ha="center", va="center", fontsize=fontsize,
            color="#333333", fontweight="bold", family="sans-serif",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="white",
                      edgecolor="#999999", linewidth=1.2),
            zorder=4)


def draw_arrow(ax, x1, y1, x2, y2, label="", color=C_ARROW):
    """Draw an arrow between two points, with optional label."""
    ax.annotate(
        "", xy=(x2, y2), xytext=(x1, y1),
        arrowprops=dict(arrowstyle="-|>", color=color, lw=1.5,
                        connectionstyle="arc3,rad=0"),
        zorder=1
    )
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx + 0.3, my, label, ha="left", va="center", fontsize=7,
                color="#555555", style="italic", zorder=4)


def main():
    fig, ax = plt.subplots(1, 1, figsize=(FIG_W, FIG_H))
    ax.set_xlim(0, 22)
    ax.set_ylim(0, 30)
    ax.set_aspect("equal")
    ax.axis("off")

    # Title
    ax.text(11, 29.3, "HDS Velocity Reclassification Workflow", ha="center", va="center",
            fontsize=18, fontweight="bold", color="#222222", family="sans-serif")
    ax.text(11, 28.85, "Updated March 19, 2026  —  COALESCE HDP First Receipt Logic Highlighted",
            ha="center", va="center", fontsize=10, color="#666666", family="sans-serif")

    # ── ROW 1: Parameters (y≈27.5) ───────────────────────────────────────────
    draw_section_label(ax, 11, 28.1, "STEP 1: Parameters")
    params_text = (
        "forecast_weeks = 13    |    weight_dollars = 0.45    |    weight_units = 0.55\n"
        "Tier A ≤ 10%    |    Tier B ≤ 30%    |    Tier C ≤ 60%    |    Tier D ≤ 100%"
    )
    draw_box(ax, 11, 27.2, 14, 0.9, params_text, C_PARAM, fontsize=9)

    # ── ROW 2: Source CTEs (y≈25.5) ──────────────────────────────────────────
    draw_section_label(ax, 11, 26.35, "Source CTEs")

    src_boxes = [
        (2.5,  "calendar_info\n(fiscal week)"),
        (5.5,  "filtered_ipr_team\n(vendor mapping)"),
        (8.5,  "unit_price\n(avg retail VBAP)"),
        (11.5, "merchant_cat_alignment\n(cat_merchant_ref)"),
        (14.5, "joined\n(skuextract +\ndmdunit +\nsupersession_vw)"),
        (17.5, "forecast\n(13-wk dfutoskufcst)"),
        (20.0, "in-stock (m)\n(8-wk weekly)"),
    ]
    for sx, stxt in src_boxes:
        draw_box(ax, sx, 25.15, 2.7, 1.1, stxt, C_SOURCE, fontsize=7)

    src_boxes2 = [
        (5.5,  "filtered_soq\n(FY2025 SOQ)"),
        (8.5,  "high_cube_items\n(business list)"),
    ]
    for sx, stxt in src_boxes2:
        draw_box(ax, sx, 23.7, 2.7, 0.85, stxt, C_SOURCE, fontsize=7)

    # ── ROW 3: HDP First Receipt Cross-Reference (NEW) (y≈22.8) ─────────────
    draw_section_label(ax, 16, 23.7, "★  NEW: HDP First Receipt Cross-Reference  ★")

    hdp_text = (
        "hdp_first_receipt_xref CTE\n"
        "v_hdp_first_receive_date  ×  ITEM_X_REF  ×  TEMPO_IMPACTED_WAREHOUSES\n"
        "(Temporary — until post-Tempo HDS first receipts accumulate)"
    )
    draw_box(ax, 16, 22.65, 8, 1.1, hdp_text, C_HDP, C_BORDER_HDP, fontsize=8, lw=2.5, bold=False)

    # ── ROW 4: all_dc_skus Universe (y≈21) ───────────────────────────────────
    draw_section_label(ax, 11, 21.6, "all_dc_skus  (Active DC-SKU Universe)")

    draw_box(ax, 5, 20.55, 5.5, 1.2,
             "MPC (ia_mpc.mpc)\n+ LEFT JOINs:\ndmdunit, plant, ipr_team,\natp, atlas, frdt, supersession_vw,\nskuextract, instock, etc.",
             C_UNIVERSE, fontsize=7)

    draw_box(ax, 11, 20.55, 5.5, 1.2,
             "★  NEW: LEFT JOIN\nhdp_first_receipt_xref\nON material + plant",
             C_HDP, C_BORDER_HDP, fontsize=8, lw=2.5, bold=True)

    draw_box(ax, 17, 20.55, 5.5, 1.2,
             "★  COALESCE Logic:\nsku_status = COALESCE(hds_fr, hdp_fr)\nsku_dc_first_receive_date\nproposed_velocity\nfirst_receipt_flg",
             C_HDP, C_BORDER_HDP, fontsize=7.5, lw=2.5, bold=True)

    # Arrows: sources → universe
    draw_arrow(ax, 11, 24.7, 5, 21.2)
    draw_arrow(ax, 16, 22.1, 11, 21.2)

    # Arrows within universe row
    draw_arrow(ax, 7.75, 20.55, 8.25, 20.55)
    draw_arrow(ax, 13.75, 20.55, 14.25, 20.55)

    # ── ROW 5: Filter (y≈18.8) ───────────────────────────────────────────────
    draw_section_label(ax, 11, 19.45, "all_active_not_filtered_out_forecasted")

    filter_text = (
        "WHERE is_active = true  AND  is_filtered_out = false\n"
        "+ LEFT JOIN forecast  →  is_forecasted flag"
    )
    draw_box(ax, 11, 18.55, 12, 0.85, filter_text, C_FILTER, fontsize=8)

    draw_arrow(ax, 11, 19.95, 11, 19.0)

    # ── ROW 6: Three Groups (y≈16.5) ─────────────────────────────────────────

    # Group 1
    draw_section_label(ax, 4.5, 17.5, "GROUP 1")
    g1_text = (
        "Forecasted + (Not New  OR  New+Superseded)\n\n"
        "velocity_weight =\n"
        "  (0.45 × weekly_fcst_$) + (0.55 × weekly_fcst_units)\n\n"
        "PERCENT_RANK() OVER\n"
        "  (PARTITION BY dc, mcat ORDER BY weight DESC)\n\n"
        "Classify:  A ≤ 10%  |  B ≤ 30%  |  C ≤ 60%  |  D ≤ 100%\n"
        "Missing COGS → 'Missing Data'"
    )
    draw_box(ax, 4.5, 15.65, 6.5, 3.0, g1_text, C_G1, "#28a745", fontsize=7.5, lw=2)

    # Group 2
    draw_section_label(ax, 11.5, 17.5, "GROUP 2")
    g2_text = (
        "Forecasted + New + Not Superseded\n\n"
        "Force velocity = C\n"
        "(new items without supersession\n"
        "get default mid-tier)"
    )
    draw_box(ax, 11.5, 16.15, 5, 2.0, g2_text, C_G2, "#007bff", fontsize=8, lw=2)

    # Group 3
    draw_section_label(ax, 18, 17.5, "GROUP 3")
    g3_text = (
        "Not Forecasted\n\n"
        "New  →  C\n"
        "Not New  →  E"
    )
    draw_box(ax, 18, 16.15, 4.5, 2.0, g3_text, C_G3, "#dc3545", fontsize=8, lw=2)

    # Arrows: filter → groups
    draw_arrow(ax, 7, 18.12, 4.5, 17.15, "Forecasted +\nNot New / Superseded")
    draw_arrow(ax, 11, 18.12, 11.5, 17.15, "Forecasted +\nNew + Not Superseded")
    draw_arrow(ax, 15, 18.12, 18, 17.15, "Not Forecasted")

    # ── ROW 7: UNION ALL (y≈13.5) ────────────────────────────────────────────
    draw_box(ax, 11, 13.5, 6, 0.7,
             "UNION ALL  (3 Groups Combined)", "#e0e0e0", fontsize=9, bold=True)

    draw_arrow(ax, 4.5, 14.15, 11, 13.9)
    draw_arrow(ax, 11.5, 15.15, 11, 13.9)
    draw_arrow(ax, 18, 15.15, 11, 13.9)

    # ── ROW 8: SSCOV + Safety Stock (y≈11.8) ─────────────────────────────────
    draw_section_label(ax, 11, 12.7, "SSCOV & Safety Stock Calculation")

    sscov_text = (
        "SSCOV weeks mapping  (import_flag × cube × velocity)\n"
        "  Domestic/Low:  A=4, B=4, C=3, D=3  |  Import/Low:  A=6, B=6, C=4, D=3\n"
        "  High-cube adjustments apply\n\n"
        "Current Safety Stock  =  weekly_avg_fcst_qty  ×  current_sscov\n"
        "Proposed Safety Stock  =  weekly_avg_fcst_qty  ×  proposed_sscov\n"
        "Δ Safety Stock ($)  =  (proposed − current) × weekly_avg × COGS"
    )
    draw_box(ax, 11, 11.35, 14, 1.8, sscov_text, C_SSCOV, fontsize=8)

    draw_arrow(ax, 11, 13.15, 11, 12.25)

    # ── ROW 9: Velocity Change Class (y≈9.5) ─────────────────────────────────
    vcc_text = (
        "velocity_change_class:\n"
        "Match  |  Promotion  |  Demotion  |  Unclassified"
    )
    draw_box(ax, 11, 9.5, 8, 0.85, vcc_text, "#fafafa", fontsize=8)
    draw_arrow(ax, 11, 10.45, 11, 9.95)

    # ── ROW 10: Analysis Output (y≈8.0) ──────────────────────────────────────
    draw_section_label(ax, 11, 8.8, "Final Output Tables")

    draw_box(ax, 7, 7.7, 8, 1.1,
             "dm_supplychain.public.\nsku_velocity_reclassification_analysis_hds\n(full analysis — all active SKUs)",
             C_OUTPUT, "#6f42c1", fontsize=8, lw=2, bold=True)

    draw_box(ax, 16.5, 7.7, 7, 1.1,
             "dm_supplychain.public.\nsku_velocity_reclassification_summary_hds\n(velocity changes only: proposed ≠ system)",
             C_OUTPUT, "#6f42c1", fontsize=8, lw=2, bold=True)

    draw_arrow(ax, 11, 9.07, 7, 8.3)
    draw_arrow(ax, 7, 7.15, 16.5, 7.15, "WHERE proposed ≠ system")

    # ── LEGEND ────────────────────────────────────────────────────────────────
    legend_y = 5.8
    ax.text(2, legend_y + 0.5, "Legend:", fontsize=10, fontweight="bold", color="#333333")

    legend_items = [
        (C_HDP,    C_BORDER_HDP, "★  NEW March 2026: HDP First Receipt COALESCE Logic (temporary Tempo measure)"),
        (C_G1,     "#28a745",    "GROUP 1: Forecasted + Not New / Superseded → Percentile-ranked A–D"),
        (C_G2,     "#007bff",    "GROUP 2: Forecasted + New + Not Superseded → Forced C"),
        (C_G3,     "#dc3545",    "GROUP 3: Not Forecasted → New=C, Not New=E"),
        (C_OUTPUT, "#6f42c1",    "Output Tables"),
    ]
    for i, (fc, ec, label) in enumerate(legend_items):
        ly = legend_y - i * 0.55
        box = FancyBboxPatch((2, ly - 0.18), 0.6, 0.36,
                             boxstyle="round,pad=0.02", facecolor=fc,
                             edgecolor=ec, linewidth=1.5, zorder=2)
        ax.add_patch(box)
        ax.text(3.0, ly, label, va="center", fontsize=8, color=C_TEXT)

    # ── Save ──────────────────────────────────────────────────────────────────
    png_path = os.path.join(OUT_DIR, "HDS_Velocity_Reclassification_Workflow.png")
    pdf_path = os.path.join(OUT_DIR, "HDS_Velocity_Reclassification_Workflow.pdf")

    fig.savefig(png_path, dpi=DPI, bbox_inches="tight", facecolor="white", pad_inches=0.3)
    fig.savefig(pdf_path, bbox_inches="tight", facecolor="white", pad_inches=0.3)
    plt.close(fig)

    print(f"PNG saved: {png_path}")
    print(f"PDF saved: {pdf_path}")


if __name__ == "__main__":
    main()
