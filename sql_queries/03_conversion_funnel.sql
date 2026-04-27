/* =============================================================================
   03_conversion_funnel.sql
   -----------------------------------------------------------------------------
   Funnel de conversión Producto -> Carrito -> Compra a nivel SESIÓN, con tasas
   paso a paso, tasa end-to-end y drop-off absoluto.

   Dataset: bigquery-public-data.thelook_ecommerce.events
   Grano  : una fila, snapshot site-wide

   Metodología
   -----------
   Una sesión cuenta en un paso si emitió al menos un evento de ese tipo
   en el orden correcto según sequence_number: cart debe ocurrir después
   de product, y purchase después de cart. Se toma el primer sequence_number
   de cada tipo por sesión; la transición es válida solo si el número
   siguiente es estrictamente mayor. Esto es acumulativo en sentido
   temporal, no solo coexistencia de eventos en la misma sesión.

   La versión anterior usaba MAX(IF(...)) por sesión y contaba coexistencia
   sin importar el orden. Eso clasificaba como "llegó al carrito" a sesiones
   donde el evento cart apareció antes que product (posible en logs
   sintéticos con sequence_number desordenado).

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

WITH first_seq AS (
  -- Primera ocurrencia de cada tipo de evento por sesión (sequence_number más bajo)
  SELECT
    session_id,
    MIN(IF(event_type = 'product',  sequence_number, NULL)) AS seq_product,
    MIN(IF(event_type = 'cart',     sequence_number, NULL)) AS seq_cart,
    MIN(IF(event_type = 'purchase', sequence_number, NULL)) AS seq_purchase
  FROM `bigquery-public-data.thelook_ecommerce.events`
  GROUP BY session_id
),

funnel_totals AS (
  -- Acumulativo temporal: cart debe seguir a product; purchase debe seguir a cart
  SELECT
    COUNTIF(seq_product IS NOT NULL) AS sessions_product,
    COUNTIF(seq_product IS NOT NULL AND seq_cart > seq_product) AS sessions_cart,
    COUNTIF(seq_product IS NOT NULL AND seq_cart > seq_product
            AND seq_purchase > seq_cart) AS sessions_purchase
  FROM first_seq
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
