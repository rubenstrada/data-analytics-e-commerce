/* =============================================================================
   06_product_affinity.sql
   -----------------------------------------------------------------------------
   Afinidad de productos (market basket) con las métricas estándar: Support,
   Confidence y Lift. Devuelve los pares de productos que se compran juntos
   mucho más de lo que el azar predeciría — la base para cross-sell, bundles
   y la sección "frequently bought together".

   Dataset : bigquery-public-data.thelook_ecommerce
   Grano   : una fila por par no ordenado (A < B)

   Métricas
   --------
   - support(A,B)       = P(A y B) = órdenes con {A,B} / total de órdenes
   - confidence(A→B)    = P(B | A) = órdenes con {A,B} / órdenes con A
   - lift(A,B)          = P(A y B) / (P(A) * P(B))
                          > 1 : asociación positiva (se compran juntos más
                                que al azar) — acá está el valor.
                          = 1 : independencia.
                          < 1 : asociación negativa.

   Por qué lift manda sobre la co-ocurrencia cruda
   -----------------------------------------------
   Los productos populares coaparecen en baskets solo por ser populares.
   Rankear por CONTEO surfacea esos falsos positivos. Rankear por LIFT
   surfacea afinidad real. Además se filtra por un piso de support para
   matar el ruido de pares raros con muestra insuficiente.

   Perillas que tocarías en un caso real
   -------------------------------------
   - min_pair_orders: subirlo filtra pares con poca señal.
   - lift > 1.5: umbral típico para "asociación relevante"; se puede
     mover a 2.0 si querés más conservador.
   - Solo baskets multi-item (basket_size > 1): los single-item orders no
     pueden formar pares, así que se excluyen del denominador para que
     support no se diluya artificialmente.
============================================================================= */

DECLARE min_pair_orders INT64 DEFAULT 30;  -- piso de co-ocurrencia

WITH valid_baskets AS (
  -- Solo ventas realizadas (sin cancelled/returned)
  SELECT
    oi.order_id,
    oi.product_id
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY oi.order_id, oi.product_id
),

basket_sizes AS (
  SELECT order_id, COUNT(DISTINCT product_id) AS basket_size
  FROM valid_baskets
  GROUP BY order_id
),

multi_item_baskets AS (
  -- Solo baskets con 2+ productos distintos (los de 1 no aportan al análisis)
  SELECT vb.order_id, vb.product_id
  FROM valid_baskets vb
  JOIN basket_sizes bs USING (order_id)
  WHERE bs.basket_size > 1
),

totals AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders
  FROM multi_item_baskets
),

product_freq AS (
  -- Frecuencia individual de cada producto (denominador de confidence)
  SELECT product_id, COUNT(DISTINCT order_id) AS orders_with_product
  FROM multi_item_baskets
  GROUP BY product_id
),

pair_counts AS (
  -- Self-join del basket consigo mismo; condición a<b para pares no ordenados
  SELECT
    a.product_id AS product_a,
    b.product_id AS product_b,
    COUNT(DISTINCT a.order_id) AS orders_with_pair
  FROM multi_item_baskets a
  JOIN multi_item_baskets b
    ON a.order_id = b.order_id
   AND a.product_id < b.product_id
  GROUP BY product_a, product_b
  HAVING COUNT(DISTINCT a.order_id) >= min_pair_orders
),

scored_pairs AS (
  SELECT
    p.product_a,
    p.product_b,
    p.orders_with_pair,
    pa.orders_with_product AS orders_with_a,
    pb.orders_with_product AS orders_with_b,
    t.total_orders,
    -- Support
    SAFE_DIVIDE(p.orders_with_pair, t.total_orders) AS support,
    -- Confidence en ambas direcciones (la métrica es asimétrica)
    SAFE_DIVIDE(p.orders_with_pair, pa.orders_with_product) AS confidence_a_to_b,
    SAFE_DIVIDE(p.orders_with_pair, pb.orders_with_product) AS confidence_b_to_a,
    -- Lift
    SAFE_DIVIDE(
      SAFE_DIVIDE(p.orders_with_pair, t.total_orders),
      SAFE_DIVIDE(pa.orders_with_product, t.total_orders)
      * SAFE_DIVIDE(pb.orders_with_product, t.total_orders)
    ) AS lift
  FROM pair_counts p
  CROSS JOIN totals t
  JOIN product_freq pa ON p.product_a = pa.product_id
  JOIN product_freq pb ON p.product_b = pb.product_id
)

-- Join con products para que el output sea legible por negocio, no solo IDs
SELECT
  s.product_a,
  prod_a.name       AS product_a_name,
  prod_a.category   AS product_a_category,
  s.product_b,
  prod_b.name       AS product_b_name,
  prod_b.category   AS product_b_category,
  s.orders_with_pair,
  ROUND(s.support           * 100, 4) AS support_pct,
  ROUND(s.confidence_a_to_b * 100, 2) AS confidence_a_to_b_pct,
  ROUND(s.confidence_b_to_a * 100, 2) AS confidence_b_to_a_pct,
  ROUND(s.lift, 2)                    AS lift
FROM scored_pairs s
JOIN `bigquery-public-data.thelook_ecommerce.products` prod_a
  ON s.product_a = prod_a.id
JOIN `bigquery-public-data.thelook_ecommerce.products` prod_b
  ON s.product_b = prod_b.id
WHERE s.lift > 1.5              -- dejamos solo asociaciones positivas fuertes
ORDER BY s.lift DESC, s.orders_with_pair DESC
LIMIT 50;
