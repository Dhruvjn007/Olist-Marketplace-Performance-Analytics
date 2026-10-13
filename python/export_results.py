"""
export_results.py
-----------------
Reads the analytics views built by sql/05-07, saves each one as a CSV in
outputs/results/, and draws four charts into outputs/charts/.

SQL does the heavy lifting; pandas is only used to fetch results and plot.

Runs automatically at the end of run_pipeline.py. To re-run only this step:
    python python/export_results.py
Connection details come from python/config.py.
"""

from pathlib import Path

import matplotlib
matplotlib.use("Agg")                      # render to files, no window needed
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import pandas as pd
from sqlalchemy import create_engine

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "outputs" / "results"
CHARTS = ROOT / "outputs" / "charts"
RESULTS.mkdir(parents=True, exist_ok=True)
CHARTS.mkdir(parents=True, exist_ok=True)

from config import DATABASE_URL

# SQLAlchemy needs to be told to use the psycopg (v3) driver
engine = create_engine(DATABASE_URL.replace("postgresql://", "postgresql+psycopg://", 1))

VIEWS = [
    "v_monthly_growth", "v_category_monthly",
    "v_rfm_segments",
    "v_delivery_kpis", "v_delay_vs_review", "v_delivery_by_state",
    "v_delivery_monthly", "v_delay_root_cause", "v_seller_delivery",
    "v_delivery_route",
]

# Chart styling: one accent hue, gray for context, red only for "bad".
BLUE, ORANGE, GRAY, RED = "#2a78d6", "#eb6834", "#8a8984", "#e34948"
INK, MUTED = "#0b0b0b", "#52514e"
plt.rcParams.update({
    "font.size": 10, "axes.edgecolor": "#d6d5d0", "axes.labelcolor": MUTED,
    "xtick.color": MUTED, "ytick.color": MUTED, "axes.titleweight": "bold",
    "axes.titlesize": 12, "axes.titlecolor": INK, "axes.spines.top": False,
    "axes.spines.right": False, "axes.grid": True, "grid.color": "#ecebe7",
    "grid.linewidth": 0.8, "axes.axisbelow": True, "figure.dpi": 130,
})


def export_views() -> dict[str, pd.DataFrame]:
    frames = {}
    for v in VIEWS:
        df = pd.read_sql(f"SELECT * FROM analytics.{v}", engine)
        df.to_csv(RESULTS / f"{v}.csv", index=False)
        frames[v] = df
        print(f"  {v:<22} {len(df):>5} rows -> outputs/results/{v}.csv")
    return frames


def chart_monthly_revenue(df: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(10, 4.5))
    x = range(len(df))
    ax.plot(x, df["revenue"] / 1e6, color=BLUE, lw=2, marker="o", ms=4, label="Monthly revenue")
    ax.plot(x, df["revenue_3m_avg"] / 1e6, color=GRAY, lw=2, ls="--", label="3-month moving avg")
    peak = df["revenue"].idxmax()
    ax.annotate(f"Black Friday {df.loc[peak, 'year_month']}\n+{df.loc[peak, 'revenue_mom_pct']:.0f}% MoM",
                (peak, df.loc[peak, "revenue"] / 1e6), xytext=(-120, -30),
                textcoords="offset points", color=INK, fontsize=9,
                arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    ax.set_xticks(list(x))
    ax.set_xticklabels(df["year_month"], rotation=45, ha="right")
    ax.set_ylabel("Revenue (R$ millions)")
    ax.set_title("Monthly revenue grew ~6x through 2017, then plateaued in 2018")
    ax.legend(frameon=False, loc="upper left")
    fig.tight_layout()
    fig.savefig(CHARTS / "01_monthly_revenue.png")
    plt.close(fig)


def chart_rfm(df: pd.DataFrame) -> None:
    df = df.sort_values("pct_revenue")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    y = range(len(df))
    h = 0.38
    ax.barh([i + h / 2 for i in y], df["pct_customers"], height=h - 0.03, color=GRAY, label="% of customers")
    ax.barh([i - h / 2 for i in y], df["pct_revenue"], height=h - 0.03, color=BLUE, label="% of revenue")
    for i, (c, r) in enumerate(zip(df["pct_customers"], df["pct_revenue"])):
        ax.text(c + 0.4, i + h / 2, f"{c:.1f}%", va="center", fontsize=8, color=MUTED)
        ax.text(r + 0.4, i - h / 2, f"{r:.1f}%", va="center", fontsize=8, color=INK)
    ax.set_yticks(list(y))
    ax.set_yticklabels(df["segment"])
    ax.xaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.set_title("RFM segments: share of customers vs share of revenue")
    ax.legend(frameon=False, loc="lower right")
    fig.tight_layout()
    fig.savefig(CHARTS / "02_rfm_segments.png")
    plt.close(fig)


def chart_delay_vs_review(df: pd.DataFrame) -> None:
    fig, ax = plt.subplots(figsize=(9, 4.5))
    labels = df["delay_bucket"].str[3:]                    # drop the "1. " sort prefix
    colors = [RED if "late" in b else BLUE for b in df["delay_bucket"]]
    bars = ax.bar(labels, df["avg_review"], color=colors, width=0.6)
    for b, v in zip(bars, df["avg_review"]):
        ax.text(b.get_x() + b.get_width() / 2, v + 0.05, f"{v:.2f}", ha="center", fontsize=9, color=INK)
    ax.set_ylim(0, 5)
    ax.set_ylabel("Average review score (1-5)")
    ax.set_title("Late deliveries drag reviews from 4.3 down to 1.7")
    plt.setp(ax.get_xticklabels(), rotation=15, ha="right")
    fig.tight_layout()
    fig.savefig(CHARTS / "03_delay_vs_review.png")
    plt.close(fig)


def chart_late_by_state(df: pd.DataFrame) -> None:
    df = df.sort_values("late_pct")
    avg = (df["late_pct"] * df["delivered_orders"]).sum() / df["delivered_orders"].sum()
    fig, ax = plt.subplots(figsize=(8, 7))
    colors = [RED if v > avg else BLUE for v in df["late_pct"]]
    ax.barh(df["state"], df["late_pct"], color=colors, height=0.7)
    ax.axvline(avg, color=MUTED, lw=1, ls="--")
    ax.text(avg + 0.3, 0.2, f"national avg {avg:.1f}%", color=MUTED, fontsize=8)
    ax.xaxis.set_major_locator(mtick.MultipleLocator(5))
    ax.xaxis.set_major_formatter(mtick.PercentFormatter(decimals=0))
    ax.set_title("Late-delivery rate by customer state")
    fig.tight_layout()
    fig.savefig(CHARTS / "04_late_by_state.png")
    plt.close(fig)


def main() -> None:
    print("Exporting analytics views...")
    f = export_views()
    print("Drawing charts...")
    chart_monthly_revenue(f["v_monthly_growth"])
    chart_rfm(f["v_rfm_segments"])
    chart_delay_vs_review(f["v_delay_vs_review"])
    chart_late_by_state(f["v_delivery_by_state"])
    print(f"Done. Charts in {CHARTS.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
