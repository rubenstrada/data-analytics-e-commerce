-- Análisis de Cross-selling (Productos comprados juntos)
WITH order_items AS (
  SELECT order_id, product_id 
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
)
SELECT 
  a.product_id AS product_a, 
  b.product_id AS product_b, 
  COUNT(*) AS times_bought_together
FROM order_items a
JOIN order_items b ON a.order_id = b.order_id AND a.product_id < b.product_id
GROUP BY 1, 2
ORDER BY times_bought_together DESC
LIMIT 10;