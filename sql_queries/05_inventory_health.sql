-- Análisis de Rotación de Inventario y Stock Muerto
WITH product_sales AS (
  SELECT 
    product_id, 
    COUNT(*) as units_sold_30d
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE created_at >= '2023-12-01' -- Simulando los últimos 30 días del dataset
  GROUP BY 1
),
inventory_status AS (
  SELECT 
    product_id,
    product_name,
    product_category,
    COUNT(*) as current_stock,
    ROUND(AVG(cost), 2) as unit_cost
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items`
  WHERE sold_at IS NULL
  GROUP BY 1, 2, 3
)
SELECT 
  i.*,
  COALESCE(s.units_sold_30d, 0) as sales_last_month,
  CASE 
    WHEN COALESCE(s.units_sold_30d, 0) = 0 THEN 'Stock Muerto (Sin ventas)'
    WHEN i.current_stock / s.units_sold_30d < 1 THEN 'Riesgo de Quiebre (Stockout)'
    WHEN i.current_stock / s.units_sold_30d > 3 THEN 'Exceso de Inventario'
    ELSE 'Stock Saludable'
  END AS inventory_status_label
FROM inventory_status i
LEFT JOIN product_sales s ON i.product_id = s.product_id
ORDER BY current_stock DESC;