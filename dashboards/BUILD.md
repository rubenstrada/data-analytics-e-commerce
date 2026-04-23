# BUILD — Dashboard consolidado de TheLook

Un solo reporte en Looker Studio, tres secciones, tres audiencias distintas pero conectadas. Overview para dirección, Retención para growth/CRM, RFM para lifecycle. Funnel e inventario no entran: en un dashboard se degradan a un número plano y pierden la lectura del SQL.

El reporte se construye directo sobre BigQuery (sin exportar a Sheets) para que los números se refresquen solos cuando el dataset público avanza.

## Data sources (Looker Studio → BigQuery)

Tres conectores, uno por sección. Cada uno es una query guardada en BigQuery que devuelve exactamente lo que el reporte pinta — nada de calcular métricas adentro de Looker.

| Source                | Query                                               | Grano                 | Refresh      |
|-----------------------|-----------------------------------------------------|-----------------------|--------------|
| `ds_overview`         | `sql_queries/01_sales_kpis.sql`                     | mes (una fila)        | Daily cache  |
| `ds_cohorts`          | `sql_queries/02_cohort_retention.sql`               | (cohorte, mes_since)  | Daily cache  |
| `ds_rfm_customers`    | `sql_queries/04_rfm_segmentation.sql`               | cliente               | Daily cache  |

El proyecto de facturación para BigQuery lo pone quien abre el reporte en edición. Las queries están tipadas para leer menos de 1 GB, así que el costo por refresh es trivial.

Campos calculados en Looker (los mínimos, para no duplicar lógica SQL):

- `ds_overview.month_label` — `FORMAT_DATETIME("%b %Y", month_start)` para el eje X.
- `ds_rfm_customers.segment_count` — `COUNT(user_id)` agregado por `segment`.
- `ds_rfm_customers.segment_revenue` — `SUM(monetary)` agregado por `segment`.

## Layout (página única, 1600 × 2400 px, grid de 12 columnas)

Tres bandas horizontales. De arriba a abajo: Overview (y=0–700), Cohortes (y=720–1400), RFM (y=1420–2300). Márgenes de 40 px laterales, gutter de 16 px entre tiles.

### Banda 1 — Overview (h = 700 px)

Cuatro scorecards arriba (cols 1-12, divididos 3+3+3+3), gráfico grande abajo (cols 1-12).

| Tile                      | Tipo              | Source          | Dimensión         | Métrica                              | Filtro mes actual |
|---------------------------|-------------------|-----------------|-------------------|--------------------------------------|-------------------|
| Revenue (mes actual)      | Scorecard + delta | ds_overview     | —                 | `revenue` (último mes) vs mes previo | sí                |
| Orders (mes actual)       | Scorecard + delta | ds_overview     | —                 | `orders`                             | sí                |
| AOV (mes actual)          | Scorecard + delta | ds_overview     | —                 | `aov`                                | sí                |
| MoM revenue (%)           | Scorecard         | ds_overview     | —                 | `mom_revenue_pct`                    | sí                |
| Revenue trend (12 meses)  | Time series combo | ds_overview     | `month_start`     | barra `revenue` + línea `aov`        | últimos 12 meses  |

Deltas en scorecards: verde si el cambio es positivo y es revenue/orders/AOV, rojo si es negativo. MoM se muestra crudo, sin color (el signo ya dice todo).

### Banda 2 — Cohortes (h = 680 px)

Tabla heatmap grande (cols 1-8) + scorecard de lectura (cols 9-12).

| Tile                      | Tipo               | Source       | Dimensiones                      | Métrica                  |
|---------------------------|--------------------|--------------|----------------------------------|--------------------------|
| Triángulo de retención    | Pivot heatmap      | ds_cohorts   | Fila: `cohort_month` / Col: `months_since_first` | `retention_pct` |
| Retención M1 (promedio)   | Scorecard          | ds_cohorts   | —                                | AVG(`retention_pct`) filtrado a `months_since_first = 1` |
| Cohortes activas          | Scorecard          | ds_cohorts   | —                                | COUNT DISTINCT `cohort_month` |
| Mejor cohorte M3          | Scorecard + label  | ds_cohorts   | —                                | MAX(`retention_pct`) filtrado a `months_since_first = 3`, con cohorte como label |

Escala de color del heatmap: gradiente de blanco (0%) a verde oscuro (≥12%). Celdas vacías (triángulo superior) en gris muy claro. Número dentro de cada celda a 10 pt. El heatmap entero es la lectura — no se le pone título redundante.

### Banda 3 — RFM (h = 900 px)

Bubble chart central (cols 1-7), tabla a la derecha (cols 8-12), dos scorecards abajo del bubble (cols 1-7, divididos 3+4).

| Tile                          | Tipo             | Source              | Dimensión   | Métricas                                                   |
|-------------------------------|------------------|---------------------|-------------|------------------------------------------------------------|
| Matriz de segmentos (bubble)  | Scatter          | ds_rfm_customers    | `segment`   | X = AVG(`r_score`), Y = AVG(`fm_score`), tamaño = COUNT, color = SUM(`monetary`) |
| Tabla de segmentos            | Table            | ds_rfm_customers    | `segment`   | COUNT, AVG(`monetary`), SUM(`monetary`), AVG(`frequency`)   |
| Cannot Lose (clientes)        | Scorecard        | ds_rfm_customers    | —           | COUNT(`user_id`) filtrado a `segment = 'Cannot Lose'`       |
| Cannot Lose (valor histórico) | Scorecard        | ds_rfm_customers    | —           | SUM(`monetary`) filtrado a `segment = 'Cannot Lose'`        |

La tabla se ordena por SUM(`monetary`) DESC, con barra de porcentaje en la columna de revenue total para que se vea de un vistazo quién concentra el valor.

## Filtros globales (header del reporte)

Un solo control, minimalista. Más filtros = más tentación de hacer slicing que nadie va a mirar.

- **Rango de fecha** (afecta sólo a Overview). Default: últimos 12 meses. Las bandas de Cohortes y RFM ignoran el control porque su lectura pierde sentido recortada.

## Formato y estilo

- Tipografía: Roboto 11 pt body, 18 pt títulos de tile, 28 pt scorecards.
- Paleta: primario `#1a73e8`, éxito `#34a853`, advertencia `#fbbc04`, fondo `#ffffff`, grid `#e0e0e0`. Heatmap RFM y cohortes usan escalas monocromáticas (verdes para cohortes, azules para RFM) para no competir con los scorecards.
- Formato de números: revenue y monetary en `$#,##0` (sin decimales). AOV y porcentajes con un decimal. Counts crudos, sin separador de miles abajo de 1000.
- Títulos de tile en español, lowercase salvo la primera palabra. Nada de "Key Metrics Overview Dashboard".

## Publicación

Compartir en "Anyone with the link → Viewer", sin copia permitida (para que el link público del README apunte siempre al original). Exportar a PDF desde File → Download → PDF y subirlo como `dashboards/thelook_dashboard.pdf`. Screenshot de la página completa a 1600 px de ancho como `dashboards/preview.png`.

Si una sección cambia (query nueva, métrica distinta), se regenera el PDF entero y se sobreescribe el PNG. Nada de `preview_v2.png`.

## Por qué sólo tres queries

Overview responde "¿cómo va el negocio?", Cohortes responde "¿el crecimiento es real o es adquisición quemando cash?", RFM responde "¿a quién le hablamos mañana?". Las tres dialogan con un director en la misma reunión.

Funnel (Q3) es una vista de producto/CRO: vive mejor como número en el README porque la decisión que dispara (A/B en checkout) no se toma leyendo un dashboard. Inventario (Q5) es operativo: el merchandiser quiere el CSV para filtrar por categoría y SKU, no un tile. Afinidad (Q6) no tiene señal en este dataset; meterla sería decorativo.
