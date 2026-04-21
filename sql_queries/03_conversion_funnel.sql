/* =============================================================================
   03_conversion_funnel.sql
   -----------------------------------------------------------------------------
   Funnel de conversión Producto -> Carrito -> Compra, con tasas paso a paso,
   tasa end-to-end y drop-off absoluto.

   Dataset: bigquery-public-data.thelook_ecommerce.events
   Grano  : una fila, snapshot site-wide

   Metodología
   -----------
   Un usuario cuenta en un paso si produjo al menos un evento de ese tipo
   en el log. Es un funnel de "alcance por usuario", NO un funnel
   secuencial a nivel sesión. Para un funnel estricto por sesión habría
   que particionar por session_id y ordenar con sequence_number — se deja
   como extensión, no se mezcla acá porque son métricas distintas.

   Qué mirar en el output
   ----------------------
   - product_to_cart_pct baja = friction en la página de producto o precio.
   - cart_to_purchase_pct baja = problema de checkout, pagos o shipping.
   - end_to_end_conv_pct = la métrica que un director quiere al día siguiente.
============================================================================= */

WITH user_stages AS (
  SELECT
    COUNT(DISTINCT IF(event_type = 'product',  user_id, NULL)) AS product_viewers,
    COUNT(DISTINCT IF(event_type = 'cart',     user_id, NULL)) AS cart_adders,
    COUNT(DISTINCT IF(event_type = 'purchase', user_id, NULL)) AS purchasers
  FROM `bigquery-public-data.thelook_ecommerce.events`
)

SELECT
  product_viewers,
  cart_adders,
  purchasers,
  -- Tasas paso a paso: miden la friction específica de cada stage
  ROUND(SAFE_DIVIDE(cart_adders, product_viewers) * 100, 2) AS product_to_cart_pct,
  ROUND(SAFE_DIVIDE(purchasers,  cart_adders)     * 100, 2) AS cart_to_purchase_pct,
  -- Tasa end-to-end: el número macro que interesa a negocio
  ROUND(SAFE_DIVIDE(purchasers,  product_viewers) * 100, 2) AS end_to_end_conv_pct,
  -- Drop-off absoluto: cuántos usuarios se pierden en cada transición
  (product_viewers - cart_adders)                          AS dropoff_product_to_cart,
  (cart_adders     - purchasers)                           AS dropoff_cart_to_purchase
FROM user_stages;
