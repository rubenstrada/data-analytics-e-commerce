/* =============================================================================
   02_cohort_retention.sql
   -----------------------------------------------------------------------------
   Retención por cohorte de adquisición mensual.

   Dataset : bigquery-public-data.thelook_ecommerce.order_items
   Grano   : (cohort_month, months_since_acquisition)
   Métrica : retention_rate = usuarios_activos_en_mes / tamaño_cohorte

   Cómo se lee el output
   ---------------------
   - months_since_acquisition = 0 es el mes de adquisición (siempre 100%).
   - La fila 1 de cada cohorte es la retención a mes 1 (tasa de primera
     recompra). Es el número que un growth team vigila semanalmente.
   - Se excluyen órdenes Cancelled y Returned: una compra reembolsada no
     demuestra retención real.

   Trampa a evitar
   ---------------
   Las cohortes más recientes se ven "malas" solo porque todavía no han
   sido observadas lo suficiente. Al graficar el triángulo de retención
   siempre recortar las cohortes incompletas para no sacar conclusiones
   falsas.

   Por qué order_items y no orders
   --------------------------------
   Las queries Q1, Q4 y Q5 trabajan a nivel línea (order_items), filtrando
   Cancelled/Returned sobre esa tabla. Leer cohortes desde orders con el
   mismo filtro no es equivalente: una orden puede quedar en status
   Cancelled a nivel header aunque alguna línea haya sido shipped, y el
   denominador de la cohorte se mueve. Alinear la fuente a order_items
   evita que el dashboard cuadre con dos definiciones distintas de revenue
   y hace que el tamaño de cohorte sea consistente con el count de clientes
   activos de Q1.
============================================================================= */

WITH first_purchase AS (
  SELECT
    user_id,
    DATE_TRUNC(DATE(MIN(created_at)), MONTH) AS cohort_month
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled', 'Returned')
  GROUP BY user_id
),

activity AS (
  -- Usuarios activos por cohorte en cada mes posterior a su adquisición
  SELECT
    fp.cohort_month,
    DATE_DIFF(
      DATE_TRUNC(DATE(oi.created_at), MONTH),
      fp.cohort_month,
      MONTH
    ) AS months_since_acquisition,
    COUNT(DISTINCT oi.user_id) AS active_users
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN first_purchase fp USING (user_id)
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY cohort_month, months_since_acquisition
),

cohort_size AS (
  SELECT
    cohort_month,
    COUNT(*) AS cohort_users
  FROM first_purchase
  GROUP BY cohort_month
)

SELECT
  a.cohort_month,
  c.cohort_users,
  a.months_since_acquisition,
  a.active_users,
  ROUND(SAFE_DIVIDE(a.active_users, c.cohort_users) * 100, 2) AS retention_rate_pct
FROM activity a
JOIN cohort_size c USING (cohort_month)
ORDER BY a.cohort_month DESC, a.months_since_acquisition;
