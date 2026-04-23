/* =============================================================================
   03_conversion_funnel.sql
   -----------------------------------------------------------------------------
   Funnel de conversión Producto -> Carrito -> Compra a nivel SESIÓN, con tasas
   paso a paso, tasa end-to-end y drop-off absoluto.

   Dataset: bigquery-public-data.thelook_ecommerce.events
   Grano  : una fila, snapshot site-wide

   Metodología
   -----------
   Una sesión cuenta en un paso si produjo al menos un evento de ese tipo
   durante la misma sesión. Las transiciones se evalúan de forma
   acumulativa: una sesión llega a "cart" solo si también vio producto, y
   llega a "purchase" solo si además sumó al carrito.

   Por qué session-level y no user-level
   -------------------------------------
   El user-level ("cuántos usuarios distintos hicieron X alguna vez")
   responde otra pregunta (alcance por usuario en toda la historia) y
   encima, sobre este dataset en particular, da 100% en los tres stages
   porque el generador sintético produce eventos de todos los tipos para
   cada usuario. El funnel session-level captura friction real: qué
   fracción de las sesiones que vieron producto terminaron comprando en
   esa misma visita.

   Qué mirar en el output
   ----------------------
   - product_to_cart_pct baja = friction en la página de producto o precio.
   - cart_to_purchase_pct baja = problema de checkout, pagos o shipping.
   - end_to_end_conv_pct = la métrica que un director quiere al día siguiente.
============================================================================= */

WITH session_stages AS (
  -- Una fila por sesión con flags de qué stages tocó
  SELECT
    session_id,
    MAX(IF(event_type = 'product',  1, 0)) AS saw_product,
    MAX(IF(event_type = 'cart',     1, 0)) AS added_cart,
    MAX(IF(event_type = 'purchase', 1, 0)) AS purchased
  FROM `bigquery-public-data.thelook_ecommerce.events`
  GROUP BY session_id
),

funnel_totals AS (
  -- Conteo acumulativo: cada stage exige haber pasado por los anteriores
  SELECT
    COUNTIF(saw_product = 1)                                           AS sessions_product,
    COUNTIF(saw_product = 1 AND added_cart = 1)                        AS sessions_cart,
    COUNTIF(saw_product = 1 AND added_cart = 1 AND purchased = 1)      AS sessions_purchase
  FROM session_stages
)

SELECT
  sessions_product,
  sessions_cart,
  sessions_purchase,
  -- Tasas paso a paso: miden la friction específica de cada stage
  ROUND(SAFE_DIVIDE(sessions_cart,     sessions_product) * 100, 2) AS product_to_cart_pct,
  ROUND(SAFE_DIVIDE(sessions_purchase, sessions_cart)    * 100, 2) AS cart_to_purchase_pct,
  -- Tasa end-to-end: el número macro que interesa a negocio
  ROUND(SAFE_DIVIDE(sessions_purchase, sessions_product) * 100, 2) AS end_to_end_conv_pct,
  -- Drop-off absoluto: cuántas sesiones se pierden en cada transición
  (sessions_product - sessions_cart)     AS dropoff_product_to_cart,
  (sessions_cart    - sessions_purchase) AS dropoff_cart_to_purchase
FROM funnel_totals;
