SELECT
  COUNT(DISTINCT IF(event_type = 'product', user_id, NULL)) AS vistas_producto,
  COUNT(DISTINCT IF(event_type = 'cart', user_id, NULL)) AS agregados_al_carrito,
  COUNT(DISTINCT IF(event_type = 'purchase', user_id, NULL)) AS compras_finalizadas
FROM `bigquery-public-data.thelook_ecommerce.events`
WHERE event_type IN ('product', 'cart', 'purchase');