# Dashboard

Un solo reporte en Looker Studio, tres secciones: Overview (Q1), Retención por cohorte (Q2), Segmentación RFM (Q4).

- `preview.png` — screenshot del reporte completo, 1600 px de ancho
- `thelook_dashboard.pdf` — export a PDF para revisión offline
- `LINKS.md` — URL público del reporte y vistas filtradas relevantes

Construcción detallada (data sources, tiles, layout, filtros, formato): [`BUILD.md`](BUILD.md).

## Convenciones

Los nombres de archivo son estables. Si el reporte cambia, se sobreescribe `preview.png` y se regenera `thelook_dashboard.pdf` completo — nada de `_v2`, para eso está git. Export limpio desde Looker, sin chrome del browser.

Funnel (Q3) e inventario (Q5) no viven en el dashboard: en un tile se achican a un número plano y pierden la lectura. Quien quiera esa vista, corre el SQL. Es una decisión consciente, no una omisión.
