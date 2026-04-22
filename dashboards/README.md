# Dashboards

Cinco screenshots, un PDF, un archivo de links. Nada más vive acá.

- `01_overview.png` — revenue, órdenes, AOV, MoM
- `02_cohort_retention.png` — triángulo de cohortes
- `03_conversion_funnel.png` — drop-off por etapa
- `04_rfm_segmentation.png` — matriz de segmentos
- `05_inventory_affinity.png` — inventario + pares con mayor lift

Exportados a 1600 px de ancho. Con menos, GitHub recomprime y los ejes quedan borrosos; con más, pesan de más sin ganancia visible.

`thelook_dashboard.pdf` es el export completo del reporte (File → Download → PDF desde Looker), páginas en el mismo orden que los PNGs. Para quien quiera revisar offline, típicamente desde el teléfono.

`LINKS.md` tiene el URL público del reporte en modo visualización, cualquier vista filtrada que valga la pena, y la fecha del snapshot detrás de los números.

## Convenciones

Los nombres de archivo son estables. Si una vista cambia, se sobreescribe el PNG; nada de `_v2`, para eso está git. Export limpio desde Looker, sin chrome del browser. El PDF se regenera completo cuando una vista cambia — un PDF con una página vieja al lado de una nueva es peor que no tenerlo.
