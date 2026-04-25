"""Genera dashboards/preview.png con las tres bandas del reporte consolidado.

Overview (Q1), Retenci\u00f3n por cohorte (Q2) y Segmentaci\u00f3n RFM (Q4).
Todas las m\u00e9tricas salen de BigQuery en vivo contra el dataset p\u00fablico.
"""
from __future__ import annotations
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
from matplotlib.ticker import FuncFormatter
from matplotlib.patches import FancyBboxPatch
import seaborn as sns
from google.cloud import bigquery

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "dashboards" / "preview.png"

PRIMARY = "#1a73e8"
SUCCESS = "#34a853"
WARN = "#fbbc04"
DANGER = "#d93025"
MUTED = "#5f6368"
BG = "#ffffff"
GRID = "#e0e0e0"

client = bigquery.Client()

Q1 = """
WITH m AS (
  SELECT DATE_TRUNC(DATE(created_at), MONTH) AS month_start,
         COUNT(DISTINCT order_id) AS orders,
         SUM(sale_price) AS revenue
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled','Returned')
  GROUP BY 1
)
SELECT month_start, orders, revenue, revenue / orders AS aov
FROM m WHERE month_start >= DATE_SUB((SELECT MAX(month_start) FROM m), INTERVAL 11 MONTH)
ORDER BY month_start
"""

Q2 = """
WITH valid AS (
  SELECT user_id, DATE_TRUNC(DATE(created_at), MONTH) AS m
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled','Returned')
),
first_ord AS (SELECT user_id, MIN(m) AS cohort_month FROM valid GROUP BY user_id),
size_ AS (SELECT cohort_month, COUNT(DISTINCT user_id) AS n FROM first_ord GROUP BY 1),
act AS (
  SELECT f.cohort_month,
         DATE_DIFF(v.m, f.cohort_month, MONTH) AS months_since,
         COUNT(DISTINCT v.user_id) AS retained
  FROM first_ord f JOIN valid v USING (user_id)
  WHERE v.m >= f.cohort_month
  GROUP BY 1, 2
),
max_obs AS (SELECT DATE_TRUNC(MAX(m), MONTH) AS max_m FROM valid)
SELECT a.cohort_month, a.months_since,
       ROUND(a.retained / s.n * 100, 2) AS ret_pct,
       DATE_ADD(a.cohort_month, INTERVAL a.months_since MONTH) < (SELECT max_m FROM max_obs) AS closed
FROM act a JOIN size_ s USING (cohort_month)
WHERE a.months_since BETWEEN 0 AND 6 AND s.n >= 100
ORDER BY a.cohort_month, a.months_since
"""

Q4 = """
WITH ref AS (SELECT MAX(DATE(created_at)) AS d
             FROM `bigquery-public-data.thelook_ecommerce.order_items`
             WHERE status NOT IN ('Cancelled','Returned')),
c AS (
  SELECT oi.user_id,
         DATE_DIFF(r.d, DATE(MAX(oi.created_at)), DAY) AS recency,
         COUNT(DISTINCT oi.order_id) AS freq,
         SUM(oi.sale_price) AS monetary
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi CROSS JOIN ref r
  WHERE oi.status NOT IN ('Cancelled','Returned')
  GROUP BY oi.user_id, r.d
),
s AS (
  SELECT *,
    NTILE(5) OVER (ORDER BY recency DESC) AS r_,
    NTILE(5) OVER (ORDER BY freq ASC) AS f_,
    NTILE(5) OVER (ORDER BY monetary ASC) AS m_
  FROM c
),
lab AS (
  SELECT *, (f_ + m_) / 2.0 AS fm,
    CASE
      WHEN r_ = 1 AND (f_ + m_) / 2.0 >= 4.5 THEN 'Cannot Lose'
      WHEN r_ <= 2 AND (f_ + m_) / 2.0 >= 3.5 THEN 'At Risk'
      WHEN r_ >= 4 AND (f_ + m_) / 2.0 >= 4.0 THEN 'Champions'
      WHEN r_ >= 3 AND (f_ + m_) / 2.0 >= 4.0 THEN 'Loyal'
      WHEN r_ >= 4 AND (f_ + m_) / 2.0 BETWEEN 2.5 AND 3.9 THEN 'Potential Loyalists'
      WHEN r_ = 5 AND (f_ + m_) / 2.0 <= 2.0 THEN 'New Customers'
      WHEN r_ = 4 AND (f_ + m_) / 2.0 <= 2.0 THEN 'Promising'
      WHEN r_ <= 2 AND (f_ + m_) / 2.0 BETWEEN 2.0 AND 3.4 THEN 'Hibernating'
      WHEN r_ <= 2 AND (f_ + m_) / 2.0 <= 1.9 THEN 'Lost'
      ELSE 'Needs Attention'
    END AS segment
  FROM s
)
SELECT segment,
       COUNT(*) AS customers,
       ROUND(SUM(monetary), 2) AS total_monetary,
       ROUND(AVG(monetary), 2) AS avg_monetary,
       ROUND(AVG(r_), 2) AS avg_r,
       ROUND(AVG(fm), 2) AS avg_fm
FROM lab GROUP BY segment ORDER BY total_monetary DESC
"""


def fmt_money(x):
    if x >= 1_000_000:
        return f"${x/1_000_000:.2f}M"
    if x >= 1_000:
        return f"${x/1_000:.0f}k"
    return f"${x:,.0f}"


def draw_scorecard(ax, title, value, delta=None, delta_color=None):
    ax.set_facecolor("#f8f9fa")
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_xticks([]); ax.set_yticks([])
    ax.text(0.03, 0.78, title, fontsize=10, color=MUTED, fontweight="500", transform=ax.transAxes)
    ax.text(0.03, 0.38, value, fontsize=20, color="#202124", fontweight="700", transform=ax.transAxes)
    if delta is not None:
        color = delta_color or (SUCCESS if delta.startswith("+") else DANGER)
        ax.text(0.03, 0.10, delta, fontsize=11, color=color, fontweight="600", transform=ax.transAxes)


def main():
    print("Querying BigQuery...")
    df_q1 = client.query(Q1).to_dataframe()
    df_q2 = client.query(Q2).to_dataframe()
    df_q4 = client.query(Q4).to_dataframe()

    df_q1["month_start"] = pd.to_datetime(df_q1["month_start"])
    last = df_q1.iloc[-1]
    prev = df_q1.iloc[-2]
    mom_rev = (last["revenue"] - prev["revenue"]) / prev["revenue"] * 100
    mom_orders = (last["orders"] - prev["orders"]) / prev["orders"] * 100
    aov_delta = last["aov"] - prev["aov"]

    fig = plt.figure(figsize=(16, 24), facecolor=BG)
    gs = GridSpec(14, 12, figure=fig, hspace=0.9, wspace=0.55,
                  left=0.04, right=0.96, top=0.97, bottom=0.03)

    fig.text(0.04, 0.985, "TheLook \u00b7 Dashboard consolidado",
             fontsize=22, fontweight="700", color="#202124")
    fig.text(0.04, 0.972, f"Snapshot: {df_q1['month_start'].max():%Y-%m-%d}  \u00b7  Fuente: bigquery-public-data.thelook_ecommerce",
             fontsize=10, color=MUTED)

    fig.text(0.04, 0.948, "1. Overview", fontsize=14, fontweight="700", color="#202124")
    fig.text(0.04, 0.940, "Revenue, \u00f3rdenes, AOV y MoM \u2014 \u00faltimos 12 meses", fontsize=9.5, color=MUTED)

    sc1 = fig.add_subplot(gs[1, 0:3])
    sc2 = fig.add_subplot(gs[1, 3:6])
    sc3 = fig.add_subplot(gs[1, 6:9])
    sc4 = fig.add_subplot(gs[1, 9:12])
    draw_scorecard(sc1, "Revenue (mes en curso)", fmt_money(last["revenue"]), f"{mom_rev:+.1f}% MoM")
    draw_scorecard(sc2, "\u00d3rdenes", f"{int(last['orders']):,}", f"{mom_orders:+.1f}% MoM")
    draw_scorecard(sc3, "AOV", f"${last['aov']:.2f}", f"{aov_delta:+.2f} vs mes previo",
                   delta_color=SUCCESS if aov_delta >= 0 else DANGER)
    draw_scorecard(sc4, "Revenue YoY",
                   f"{(last['revenue']/df_q1.iloc[0]['revenue'] - 1)*100:+.0f}%",
                   f"{fmt_money(df_q1.iloc[0]['revenue'])} \u2192 {fmt_money(last['revenue'])}",
                   delta_color=MUTED)

    ax_trend = fig.add_subplot(gs[2:5, 0:12])
    ax_trend.set_facecolor("#fafbfc")
    ax2 = ax_trend.twinx()
    months = df_q1["month_start"].dt.strftime("%b %y")
    bars = ax_trend.bar(months, df_q1["revenue"], color=PRIMARY, alpha=0.88, label="Revenue")
    ax2.plot(months, df_q1["aov"], color="#ea4335", marker="o", linewidth=2.2, label="AOV", zorder=5)
    ax_trend.set_ylabel("Revenue", color=PRIMARY, fontsize=10)
    ax2.set_ylabel("AOV ($)", color="#ea4335", fontsize=10)
    ax_trend.tick_params(axis="y", labelcolor=PRIMARY)
    ax2.tick_params(axis="y", labelcolor="#ea4335")
    ax_trend.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x/1000:.0f}k"))
    ax2.yaxis.set_major_formatter(FuncFormatter(lambda x, _: f"${x:.0f}"))
    ax_trend.set_title("Revenue mensual (barra) y AOV (l\u00ednea)", loc="left", fontsize=11,
                       fontweight="600", color="#202124", pad=8)
    ax_trend.grid(True, axis="y", color=GRID, linewidth=0.7, alpha=0.8)
    ax_trend.set_axisbelow(True)
    for spine in ["top", "right"]:
        ax_trend.spines[spine].set_visible(False)
        ax2.spines[spine].set_visible(False)
    for bar, val in zip(bars, df_q1["revenue"]):
        ax_trend.text(bar.get_x() + bar.get_width()/2, val, fmt_money(val),
                      ha="center", va="bottom", fontsize=8, color="#202124")

    fig.text(0.04, 0.635, "2. Retenci\u00f3n por cohorte", fontsize=14, fontweight="700", color="#202124")
    fig.text(0.04, 0.627, "Tri\u00e1ngulo de retenci\u00f3n, \u00faltimas 12 cohortes con \u2265100 clientes, solo celdas cerradas",
             fontsize=9.5, color=MUTED)

    df_q2["cohort_month"] = pd.to_datetime(df_q2["cohort_month"])
    df_q2.loc[~df_q2["closed"] & (df_q2["months_since"] != 0), "ret_pct"] = np.nan
    pivot = (df_q2.pivot(index="cohort_month", columns="months_since", values="ret_pct")
                 .tail(12))
    pivot.index = pd.to_datetime(pivot.index).strftime("%Y-%m")

    ax_heat = fig.add_subplot(gs[6:9, 0:8])
    sns.heatmap(pivot, annot=True, fmt=".1f", cmap="Greens", ax=ax_heat,
                cbar_kws={"label": "% retenidos", "shrink": 0.75},
                linewidths=0.3, linecolor="white", mask=pivot.isna(),
                annot_kws={"fontsize": 9})
    ax_heat.set_xlabel("Meses desde la primera compra", fontsize=10)
    ax_heat.set_ylabel("Cohorte", fontsize=10)
    ax_heat.set_title("Retenci\u00f3n %", loc="left", fontsize=11, fontweight="600", color="#202124", pad=6)

    closed = df_q2[df_q2["closed"] & (df_q2["months_since"] == 1)]
    m1_mean = closed["ret_pct"].mean()
    best_m3 = df_q2[df_q2["closed"] & (df_q2["months_since"] == 3)].nlargest(1, "ret_pct")
    n_cohorts = df_q2["cohort_month"].nunique()

    sc_c1 = fig.add_subplot(gs[6, 8:12])
    sc_c2 = fig.add_subplot(gs[7, 8:12])
    sc_c3 = fig.add_subplot(gs[8, 8:12])
    draw_scorecard(sc_c1, "M1 promedio (cohortes maduras)", f"{m1_mean:.2f}%",
                   f"n={len(closed)} cohortes", delta_color=MUTED)
    if not best_m3.empty:
        row = best_m3.iloc[0]
        draw_scorecard(sc_c2, "Mejor M3 hist\u00f3rico", f"{row['ret_pct']:.2f}%",
                       f"cohorte {row['cohort_month'].strftime('%Y-%m')}", delta_color=MUTED)
    else:
        draw_scorecard(sc_c2, "Mejor M3 hist\u00f3rico", "n/a", "sin cohortes M3 cerrado", delta_color=MUTED)
    draw_scorecard(sc_c3, "Cohortes activas", f"{n_cohorts}", "todas las mensuales observadas",
                   delta_color=MUTED)

    fig.text(0.04, 0.375, "3. Segmentaci\u00f3n RFM", fontsize=14, fontweight="700", color="#202124")
    fig.text(0.04, 0.367, "Scoring por quintiles. Tama\u00f1o = clientes, color = revenue total.",
             fontsize=9.5, color=MUTED)

    ax_bub = fig.add_subplot(gs[10:14, 0:7])
    sizes = df_q4["customers"] / df_q4["customers"].max() * 2200 + 60
    scat = ax_bub.scatter(df_q4["avg_r"], df_q4["avg_fm"], s=sizes,
                          c=df_q4["total_monetary"], cmap="Blues",
                          alpha=0.85, edgecolors="#202124", linewidths=0.6)
    for _, row in df_q4.iterrows():
        ax_bub.annotate(row["segment"], (row["avg_r"], row["avg_fm"]),
                        fontsize=8.5, ha="center", va="center",
                        color="#202124", fontweight="600")
    ax_bub.set_xlabel("Recency score promedio (5 = m\u00e1s reciente)", fontsize=10)
    ax_bub.set_ylabel("FM score promedio (frequency + monetary)", fontsize=10)
    ax_bub.set_title("Matriz de segmentos", loc="left", fontsize=11, fontweight="600", color="#202124", pad=6)
    ax_bub.set_xlim(0.5, 5.5); ax_bub.set_ylim(0.5, 5.5)
    ax_bub.grid(True, color=GRID, linewidth=0.7, alpha=0.7)
    ax_bub.set_axisbelow(True)
    for spine in ["top", "right"]:
        ax_bub.spines[spine].set_visible(False)
    cbar = plt.colorbar(scat, ax=ax_bub, shrink=0.7, pad=0.02)
    cbar.set_label("Revenue total ($)", fontsize=9)
    cbar.ax.yaxis.set_major_formatter(FuncFormatter(lambda x, _: fmt_money(x)))

    ax_tbl = fig.add_subplot(gs[10:14, 7:12])
    ax_tbl.axis("off")
    df_tbl = df_q4.copy()
    df_tbl["customers"] = df_tbl["customers"].apply(lambda x: f"{x:,}")
    df_tbl["total_monetary"] = df_tbl["total_monetary"].apply(fmt_money)
    df_tbl["avg_monetary"] = df_tbl["avg_monetary"].apply(lambda x: f"${x:.0f}")
    table_data = df_tbl[["segment", "customers", "total_monetary", "avg_monetary"]].values
    tbl = ax_tbl.table(cellText=table_data,
                       colLabels=["segmento", "clientes", "revenue total", "avg monetary"],
                       loc="center", cellLoc="left", colLoc="left",
                       bbox=[0, 0, 1, 0.95])
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(9)
    tbl.scale(1, 1.35)
    for (i, j), cell in tbl.get_celld().items():
        cell.set_edgecolor("#f0f0f0")
        if i == 0:
            cell.set_facecolor("#eef3fd")
            cell.set_text_props(fontweight="700", color="#202124")
        else:
            cell.set_facecolor("#ffffff" if i % 2 else "#fafbfc")
    ax_tbl.set_title("Tabla de segmentos (ordenada por revenue)", loc="left",
                     fontsize=11, fontweight="600", color="#202124", pad=6)

    fig.text(0.04, 0.012,
             "Construcci\u00f3n, data sources, layout y formato detallados en dashboards/BUILD.md  \u00b7  Funnel (Q3) e inventario (Q5) no entran al dashboard por decisi\u00f3n de dise\u00f1o.",
             fontsize=9, color=MUTED, style="italic")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT, dpi=130, bbox_inches="tight", facecolor=BG)
    print(f"Export: {OUT}")


if __name__ == "__main__":
    main()
