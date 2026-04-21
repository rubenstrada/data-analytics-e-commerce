/* =============================================================================
   01_sales_kpis.sql
   -----------------------------------------------------------------------------
   KPIs mensuales de salud de ventas: revenue, órdenes, AOV, unidades y
   crecimiento MoM.

   Dataset  : bigquery-public-data.thelook_ecommerce
   Grano    : una fila por mes calendario de creación de la orden
   Exclusión: items Cancelled y Returned fuera del cálculo de revenue
              (no son ventas realizadas; incluirlos infla los KPIs)

   Nota de criterio sobre AOV
   --------------------------
   AOV se calcula a nivel ORDEN:
       revenue / órdenes distintas
   NO como AVG(sale_price). Este último promedia el precio de cada línea y
   ignora el tamaño del carrito, así que subestima sistemáticamente el
   ticket. Es el error más común a nivel junior y vale la pena dejarlo
   explícito.

   Sobre "revenue"
   ---------------
   El dataset público no expone shipping, impuestos ni descuentos, así que
   lo que acá se llama "revenue" es merchandise revenue (suma de sale_price
   a nivel línea de ítem).
============================================================================= */

WITH monthly AS (
  SELECT
    DATE_TRUNC(DATE(created_at), MONTH) AS order_month,
    COUNT(DISTINCT order_id)            AS orders,
    COUNT(DISTINCT user_id)             AS active_customers,
    COUNT(*)                            AS units_sold,
    SUM(sale_price)                     AS revenue
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled', 'Returned')
  GROUP BY order_month
)

SELECT
  order_month,
  orders,
  active_customers,
  units_sold,
  ROUND(revenue, 2)                                           AS revenue,
  -- AOV correcto: total facturado / número de órdenes únicas
  ROUND(SAFE_DIVIDE(revenue, orders), 2)                      AS aov,
  ROUND(SAFE_DIVIDE(units_sold, orders), 2)                   AS units_per_order,
  -- Crecimiento MoM del revenue; LAG trae el mes anterior para comparar
  ROUND(
    SAFE_DIVIDE(
      revenue - LAG(revenue) OVER (ORDER BY order_month),
      LAG(revenue) OVER (ORDER BY order_month)
    ) * 100, 2
  )                                                           AS revenue_mom_pct
FROM monthly
ORDER BY order_month DESC;
