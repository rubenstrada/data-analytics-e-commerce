SELECT
  FORMAT_DATE('%Y-%m', created_at) AS mes,
  COUNT(DISTINCT order_id) AS total_pedidos,
  ROUND(SUM(sale_price), 2) AS ingresos_totales,
  ROUND(AVG(sale_price), 2) AS ticket_promedio_venta
FROM `bigquery-public-data.thelook_ecommerce.order_items`
WHERE status NOT IN ('Cancelled', 'Returned')
GROUP BY 1 ORDER BY 1 DESC;