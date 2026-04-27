/* =============================================================================
   04_rfm_segmentation.sql
   -----------------------------------------------------------------------------
   Segmentación RFM de clientes (Recency, Frequency, Monetary) con scoring por
   quintiles (NTILE 5) y matriz estándar de segmentos de negocio.

   Dataset : bigquery-public-data.thelook_ecommerce.order_items
   Grano   : una fila por cliente (user_id)
   Output  : scores R, F, M (1-5), celda RFM combinada y segmento de negocio.

   Por qué quintiles y no thresholds manuales
   ------------------------------------------
   Los cortes hand-picked ("VIP = 3+ órdenes en los últimos 30 días") son
   frágiles: dependen de estacionalidad, tamaño del catálogo y ventana de
   reporte. Con quintiles cada score es RELATIVO a la base actual de
   clientes, así que la distribución de segmentos queda estable y
   comparable en el tiempo. Es la diferencia entre un RFM que envejece
   bien y uno que hay que re-tunear cada trimestre.

   Convención de scoring
   ---------------------
   - Recency  : MENOS días desde la última compra es MEJOR, así que NTILE
                se hace en orden DESC para que el cliente más reciente
                reciba el 5.
   - Frequency: más órdenes = mejor -> NTILE ASC.
   - Monetary : más gasto = mejor  -> NTILE ASC.

   Tie-break en NTILE
   ------------------
   Con miles de clientes en frequency=1, los NTILE sin tie-break no son
   determinísticos: el orden de los empates puede cambiar entre corridas y
   la distribución de segmentos se mueve sola. Se agrega user_id como
   criterio de desempate final en los tres scores para que la matriz sea
   estable entre ejecuciones sucesivas sobre el mismo snapshot.

   Fecha de referencia
   -------------------
   "Hoy" se ancla a MAX(created_at) del propio dataset. Esto mantiene la
   Recency relevante a medida que el dataset público crece, sin fechas
   hard-coded que se vuelven mentira en 6 meses.

   Matriz de segmentos
   -------------------
   Basada en el esquema (R, F+M) popularizado por Blast Analytics y usado
   en herramientas de CRM / lifecycle. Simplificada para no dejar celdas
   ambiguas.
============================================================================= */

WITH reference AS (
  -- "Hoy" dinámico: la fecha de la última transacción observada en el dataset
  SELECT MAX(DATE(created_at)) AS as_of_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled', 'Returned')
),

customer_rfm AS (
  SELECT
    oi.user_id,
    DATE_DIFF(r.as_of_date, DATE(MAX(oi.created_at)), DAY) AS recency_days,
    COUNT(DISTINCT oi.order_id)                            AS frequency,
    ROUND(SUM(oi.sale_price), 2)                           AS monetary
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  CROSS JOIN reference r
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY oi.user_id, r.as_of_date
),

scored AS (
  SELECT
    user_id,
    recency_days,
    frequency,
    monetary,
    NTILE(5) OVER (ORDER BY recency_days DESC, monetary DESC, user_id) AS r_score,
    NTILE(5) OVER (ORDER BY frequency    ASC,  monetary ASC,  user_id) AS f_score,
    NTILE(5) OVER (ORDER BY monetary     ASC,  frequency ASC, user_id) AS m_score
  FROM customer_rfm
),

labeled AS (
  SELECT
    *,
    CONCAT(CAST(r_score AS STRING),
           CAST(f_score AS STRING),
           CAST(m_score AS STRING))        AS rfm_cell,
    -- FM = score de valor (frequency + monetary promediados). Reduce la
    -- matriz a 2D (R vs FM) que es más fácil de mapear a segmentos.
    ROUND((f_score + m_score) / 2.0, 1)    AS fm_score
  FROM scored
)

SELECT
  user_id,
  recency_days,
  frequency,
  monetary,
  r_score,
  f_score,
  m_score,
  rfm_cell,
  -- Orden de evaluación: de más específico a más general. Un CASE WHEN se
  -- resuelve de arriba a abajo, así que cualquier regla "subset" debe ir
  -- antes de su "superset" o se vuelve inalcanzable.
  CASE
    -- Cannot Lose: top spenders históricos dormidos. Prioridad máxima de CRM.
    -- Va ANTES que At Risk porque (r=1, fm>=4.5) es subset de (r<=2, fm>=3.5).
    WHEN r_score = 1 AND fm_score >= 4.5 THEN 'Cannot Lose'
    -- At Risk: compraban mucho, se fueron. Target #1 para reactivación.
    WHEN r_score <= 2 AND fm_score >= 3.5 THEN 'At Risk'
    -- Champions: compran recientemente, seguido y gastan arriba del promedio
    WHEN r_score >= 4 AND fm_score >= 4.0 THEN 'Champions'
    -- Loyal: gastan bien y siguen activos, aunque no sean los más recientes
    WHEN r_score >= 3 AND fm_score >= 4.0 THEN 'Loyal'
    -- Potential Loyalists: recientes, empezando a gastar más
    WHEN r_score >= 4 AND fm_score BETWEEN 2.5 AND 3.9 THEN 'Potential Loyalists'
    -- New Customers: muy recientes, todavía con baja frequency/monetary
    WHEN r_score = 5 AND fm_score <= 2.0 THEN 'New Customers'
    -- Promising: recientes, una compra, ticket modesto
    WHEN r_score = 4 AND fm_score <= 2.0 THEN 'Promising'
    -- Hibernating: R bajo, valor medio. Campañas de win-back más baratas.
    WHEN r_score <= 2 AND fm_score BETWEEN 2.0 AND 3.4 THEN 'Hibernating'
    -- Lost: bajo en todo. No vale la pena reactivar, mejor no gastar.
    WHEN r_score <= 2 AND fm_score <= 1.9 THEN 'Lost'
    ELSE 'Needs Attention'
  END AS segment
FROM labeled
ORDER BY monetary DESC;
