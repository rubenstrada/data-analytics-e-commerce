# E-Commerce Analytics — TheLook (BigQuery)

En e-commerce, el número que termina en un deck rara vez es el número con el que decidirías algo. El AOV se calcula mal y te deja prometiendo un ticket que no existe. La retención se reporta agregada y no deja ver cuál cohorte está rota. El funnel se presenta sin distinguir canal y manda al equipo equivocado a resolver un problema que no es suyo. Son errores que cuestan credibilidad frente a dirección, y se repiten tanto que ya tienen patrón.

Este repo son seis queries sobre `bigquery-public-data.thelook_ecommerce`, escritas como las querría ver antes de entregarle un dashboard a alguien.

## Contexto del proyecto

TheLook es un e-commerce ficticio del equipo de Looker, publicado por Google como dataset público en BigQuery. Su forma (orders, order_items, users, products, inventory_items, events) es realista para un D2C o marketplace mid-market.

En este repo lo tratamos como un negocio real: hay dirección comercial que necesita entender su crecimiento, un equipo de CRM que quiere segmentar clientes con algún criterio, operaciones peleando con inventario que no se mueve, y merchandising buscando pares para cross-sell. El ejercicio es producir desde SQL las seis respuestas que ese equipo necesita para decidir la semana siguiente.

## La base de datos

El dataset tiene seis tablas relevantes. El grano importa y lo pongo explícito en cada una — confundirlo es el origen de más de la mitad de los errores de agregación en analítica de e-commerce.

### `orders`
Una fila por orden. Trae `order_id`, `user_id`, `status` (Complete, Cancelled, Returned, Processing, Shipped), y timestamps (`created_at`, `shipped_at`, `delivered_at`, `returned_at`). Es la tabla de encabezado de la compra.

### `order_items`
Una fila por **línea** de producto vendido, no por orden. Este es el hecho central. Cada fila tiene `order_id`, `user_id`, `product_id`, `inventory_item_id`, `sale_price`, `status`. Si en una orden hay tres productos distintos, hay tres filas en esta tabla.

### `users`
Una fila por cliente. Trae `id`, `created_at`, país, ciudad, y `traffic_source` (el canal de adquisición registrado).

### `products`
Catálogo. Trae `id`, `name`, `category`, `brand`, `retail_price`, `cost`. Se usa para que los outputs sean legibles por negocio y no tablas de IDs.

### `inventory_items`
Una fila por **unidad física** recibida. Trae `created_at` (cuándo llegó al almacén) y `sold_at` (cuándo se vendió, o NULL si sigue on-hand). Esta es la tabla que permite calcular dead stock y días de supply.

### `events`
Una fila por interacción web: `user_id`, `session_id`, `event_type` (home, department, product, cart, purchase), `sequence_number` dentro de la sesión, `traffic_source`. Es la fuente del funnel.

```
                 ┌─────────────┐
                 │   users     │
                 └──────┬──────┘
                        │ id
          ┌─────────────┼──────────────┐
          │             │              │
   ┌──────▼──────┐      │       ┌──────▼──────┐
   │   orders    │      │       │   events    │
   └──────┬──────┘      │       └─────────────┘
          │             │
   ┌──────▼─────────────▼──────┐
   │       order_items         │
   └──────┬─────────────┬──────┘
          │             │
   ┌──────▼──────┐   ┌──▼──────────────┐
   │  products   │◄──┤ inventory_items │
   └─────────────┘   └─────────────────┘
```

## El brief

Imagina que el lunes bajó este mensaje de dirección comercial.

> Equipo, para el review del viernes necesito seis cosas resueltas. Las bajo ordenadas:
>
> 1. ¿Estamos creciendo mes a mes? ¿El AOV aguanta o se nos está achicando el ticket?
> 2. ¿Cómo retienen las cohortes nuevas? No quiero un promedio, quiero ver el decay mes a mes.
> 3. ¿Dónde del funnel se cae la mayoría de la gente? Producto, carrito o checkout.
> 4. Necesito pasarle a marketing una segmentación de clientes que sirva para retención, reactivación y upsell. Sin listas duras que se rompan en tres meses.
> 5. ¿Qué SKUs están comiendo capital sin moverse? ¿Cuáles se van a quedar en cero?
> 6. ¿Qué se compra con qué? Quiero dos o tres pares con evidencia suficiente para armar un bundle.

Cada una de las seis preguntas se resuelve con un archivo SQL. Abajo van embebidos la query, el resultado (placeholder hasta que se corra contra el snapshot actual) y la lectura.

## Análisis y resultados

### Q1. ¿Estamos creciendo y el AOV aguanta?

Revenue, órdenes, AOV y crecimiento MoM. La decisión que vale acá: AOV se calcula `revenue / órdenes distintas`, no como `AVG(sale_price)` sobre líneas. Ese segundo cálculo promedia el precio de cada ítem e ignora el tamaño del carrito; subestima el ticket real en 15–25% en un retailer típico y es el error más repetido en repos con este dataset.

```sql
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
  ROUND(revenue, 2)                                    AS revenue,
  ROUND(SAFE_DIVIDE(revenue, orders), 2)               AS aov,
  ROUND(SAFE_DIVIDE(units_sold, orders), 2)            AS units_per_order,
  ROUND(
    SAFE_DIVIDE(
      revenue - LAG(revenue) OVER (ORDER BY order_month),
      LAG(revenue) OVER (ORDER BY order_month)
    ) * 100, 2
  )                                                     AS revenue_mom_pct
FROM monthly
ORDER BY order_month DESC;
```

**Resultado:** _[PLACEHOLDER: screenshot de la tabla de resultados — `dashboards/q1_result.png`]_

**Lectura:** _[PLACEHOLDER: mes de mayor revenue, AOV del último mes, y si los últimos tres MoM cambiaron de signo respecto a los tres anteriores. Si cambiaron, vale un ticket; si no, se documenta y se sigue.]_

Archivo completo: [`sql_queries/01_sales_kpis.sql`](sql_queries/01_sales_kpis.sql)

### Q2. ¿Cómo retienen las cohortes y dónde se fugan?

Triángulo de retención por cohorte de adquisición mensual. La pregunta "¿bajó la retención?" casi siempre es la pregunta equivocada porque el agregado mezcla cohortes y esconde el problema real. La retención se calcula contra el tamaño de la cohorte, no contra la base activa del mes (ese denominador se mueve solo y contamina el número).

```sql
WITH first_purchase AS (
  SELECT
    user_id,
    DATE_TRUNC(DATE(MIN(created_at)), MONTH) AS cohort_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status NOT IN ('Cancelled', 'Returned')
  GROUP BY user_id
),

activity AS (
  SELECT
    fp.cohort_month,
    DATE_DIFF(
      DATE_TRUNC(DATE(o.created_at), MONTH),
      fp.cohort_month,
      MONTH
    ) AS months_since_acquisition,
    COUNT(DISTINCT o.user_id) AS active_users
  FROM `bigquery-public-data.thelook_ecommerce.orders` o
  JOIN first_purchase fp USING (user_id)
  WHERE o.status NOT IN ('Cancelled', 'Returned')
  GROUP BY cohort_month, months_since_acquisition
),

cohort_size AS (
  SELECT cohort_month, COUNT(*) AS cohort_users
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
```

**Resultado:** _[PLACEHOLDER: triángulo de retención renderizado en Looker Studio — `dashboards/q2_cohort.png`]_

**Lectura:** _[PLACEHOLDER: retención promedio a M1 (primera recompra), forma del decay de M1 a M3, y cohortes con caída anómala si las hay. Una caída aislada en una cohorte específica casi siempre apunta a un canal de adquisición malo, no a un problema de producto.]_

Nota. Las cohortes de los últimos meses se van a ver peor en el triángulo porque no han tenido tiempo de retener. Al graficar conviene recortarlas; en la tabla cruda se dejan, para que cualquiera que audite la query vea los datos completos.

Archivo completo: [`sql_queries/02_cohort_retention.sql`](sql_queries/02_cohort_retention.sql)

### Q3. ¿Dónde del funnel se pierde la gente?

Funnel de alcance por usuario: producto → carrito → compra. Un usuario cuenta en un paso si produjo al menos un evento de ese tipo en el log. Es una definición deliberada, no accidental: el funnel session-level responde otra pregunta (friction intra-sesión) y mezclar ambos en el mismo dashboard es cómo arrancan las discusiones improductivas entre product y growth.

```sql
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
  ROUND(SAFE_DIVIDE(cart_adders, product_viewers) * 100, 2) AS product_to_cart_pct,
  ROUND(SAFE_DIVIDE(purchasers,  cart_adders)     * 100, 2) AS cart_to_purchase_pct,
  ROUND(SAFE_DIVIDE(purchasers,  product_viewers) * 100, 2) AS end_to_end_conv_pct,
  (product_viewers - cart_adders)                          AS dropoff_product_to_cart,
  (cart_adders     - purchasers)                           AS dropoff_cart_to_purchase
FROM user_stages;
```

**Resultado:** _[PLACEHOLDER: visualización del funnel con los tres conteos y las dos tasas — `dashboards/q3_funnel.png`]_

**Lectura:** _[PLACEHOLDER: cuál de las dos transiciones (producto→carrito o carrito→compra) es el leak más grande. Si es producto→carrito, la atención se va a PDP (precio, fotos, stock visibility). Si es carrito→compra, casi siempre es checkout (métodos de pago, shipping, friction de cuenta).]_

Archivo completo: [`sql_queries/03_conversion_funnel.sql`](sql_queries/03_conversion_funnel.sql)

### Q4. ¿A qué clientes hablarle, y con qué mensaje?

Segmentación RFM con scoring por quintiles (`NTILE(5)`) en lugar de thresholds manuales. "VIP = 3 órdenes en 30 días" es más fácil de explicar en una reunión, pero se rompe con estacionalidad y con cambios de catálogo, y tres meses después los segmentos describen a gente que ya no existe. Los quintiles son relativos a la base actual, así que la matriz aguanta sin re-tunear.

```sql
WITH reference AS (
  SELECT MAX(DATE(created_at)) AS as_of_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status NOT IN ('Cancelled', 'Returned')
),

customer_rfm AS (
  SELECT
    oi.user_id,
    DATE_DIFF(r.as_of_date, DATE(MAX(oi.created_at)), DAY) AS recency_days,
    COUNT(DISTINCT oi.order_id)                            AS frequency,
    ROUND(SUM(oi.sale_price), 2)                           AS monetary
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  CROSS JOIN reference r
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY oi.user_id, r.as_of_date
),

scored AS (
  SELECT
    *,
    NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
    NTILE(5) OVER (ORDER BY frequency    ASC)  AS f_score,
    NTILE(5) OVER (ORDER BY monetary     ASC)  AS m_score
  FROM customer_rfm
)

SELECT
  user_id, recency_days, frequency, monetary,
  r_score, f_score, m_score,
  ROUND((f_score + m_score) / 2.0, 1) AS fm_score,
  CASE
    WHEN r_score >= 4 AND (f_score + m_score) / 2.0 >= 4.0 THEN 'Champions'
    WHEN r_score >= 3 AND (f_score + m_score) / 2.0 >= 4.0 THEN 'Loyal'
    WHEN r_score >= 4 AND (f_score + m_score) / 2.0 BETWEEN 2.5 AND 3.9 THEN 'Potential Loyalists'
    WHEN r_score = 5  AND (f_score + m_score) / 2.0 <= 2.0 THEN 'New Customers'
    WHEN r_score = 4  AND (f_score + m_score) / 2.0 <= 2.0 THEN 'Promising'
    WHEN r_score <= 2 AND (f_score + m_score) / 2.0 >= 3.5 THEN 'At Risk'
    WHEN r_score = 1  AND (f_score + m_score) / 2.0 >= 4.5 THEN 'Cannot Lose'
    WHEN r_score <= 2 AND (f_score + m_score) / 2.0 BETWEEN 2.0 AND 3.4 THEN 'Hibernating'
    WHEN r_score <= 2 AND (f_score + m_score) / 2.0 <= 1.9 THEN 'Lost'
    ELSE 'Needs Attention'
  END AS segment
FROM scored
ORDER BY monetary DESC;
```

**Resultado:** _[PLACEHOLDER: matriz RFM con conteo de clientes y revenue por segmento — `dashboards/q4_rfm.png`]_

**Lectura:** _[PLACEHOLDER: % de clientes en Champions y revenue concentrado ahí (el patrón Pareto típico es 20–25% de clientes cargando 60–70% del revenue), y tamaño combinado de At Risk + Cannot Lose — ese es el target real de reactivación. Si Cannot Lose está vacío, el negocio no tiene vida suficiente para tener high-spenders dormidos, y eso es información tanto como el número mismo.]_

Archivo completo: [`sql_queries/04_rfm_segmentation.sql`](sql_queries/04_rfm_segmentation.sql)

### Q5. ¿Qué SKUs están comiendo capital y cuáles se van a quedar en cero?

Salud de inventario: velocidad de ventas sobre ventana de 90 días, días de supply, capital estancado, y una clasificación accionable. Dos decisiones que valen la pena marcar. Primera: la métrica que usa operaciones no es "unidades on hand" sino días de supply (unidades / velocidad diaria); eso es lo que contesta cuándo reordenar. Segunda: dead stock pide doble condición, cero ventas en 90 días **y** la unidad más vieja on-hand con más de 180 días, porque sin la segunda un SKU recién lanzado queda marcado como muerto y el reporte pierde credibilidad con compras en dos semanas.

```sql
WITH reference AS (
  SELECT MAX(DATE(created_at)) AS as_of_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

sales_90d AS (
  SELECT
    oi.product_id,
    COUNT(*) / 90.0 AS daily_velocity,
    MAX(DATE(oi.created_at)) AS last_sale_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  CROSS JOIN reference r
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
    AND DATE(oi.created_at) BETWEEN DATE_SUB(r.as_of_date, INTERVAL 90 DAY)
                                AND r.as_of_date
  GROUP BY oi.product_id
),

on_hand AS (
  SELECT
    ii.product_id,
    ANY_VALUE(ii.product_name) AS product_name,
    COUNT(*) AS units_on_hand,
    ROUND(SUM(ii.cost), 2) AS tied_up_capital,
    MIN(DATE(ii.created_at)) AS oldest_unit_date
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items` ii
  WHERE ii.sold_at IS NULL
  GROUP BY ii.product_id
)

SELECT
  oh.product_id,
  oh.product_name,
  oh.units_on_hand,
  oh.tied_up_capital,
  COALESCE(s.daily_velocity, 0) AS daily_velocity,
  ROUND(SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity), 1) AS days_of_supply,
  DATE_DIFF(r.as_of_date, oh.oldest_unit_date, DAY) AS oldest_unit_age_days,
  CASE
    WHEN COALESCE(s.daily_velocity, 0) = 0
         AND DATE_DIFF(r.as_of_date, oh.oldest_unit_date, DAY) > 180
      THEN 'Dead Stock'
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) > 120 THEN 'Overstock'
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) < 14  THEN 'Reorder Now'
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) BETWEEN 14 AND 30 THEN 'At Risk'
    ELSE 'Healthy'
  END AS inventory_status
FROM on_hand oh
LEFT JOIN sales_90d s USING (product_id)
CROSS JOIN reference r
ORDER BY oh.tied_up_capital DESC;
```

**Resultado:** _[PLACEHOLDER: top-20 SKUs por capital estancado + distribución de status — `dashboards/q5_inventory.png`]_

**Lectura:** _[PLACEHOLDER: top-10 SKUs en capital estancado, número de SKUs en Reorder Now (acción inmediata), y total tied-up en Dead Stock. Ese último número es la factura de oportunidad que justifica una liquidación.]_

Archivo completo: [`sql_queries/05_inventory_health.sql`](sql_queries/05_inventory_health.sql)

### Q6. ¿Qué se compra con qué?

Market basket. Pares de productos rankeados por lift, no por co-ocurrencia cruda. Rankear por conteo te devuelve los productos más populares del catálogo, que es literalmente lo opuesto de lo que preguntaste. Lift corrige por la frecuencia marginal de cada producto y surfacea afinidad real. Piso de support para descartar coincidencias estadísticas, y solo baskets con dos o más ítems en el denominador.

```sql
DECLARE min_pair_orders INT64 DEFAULT 30;

WITH valid_baskets AS (
  SELECT oi.order_id, oi.product_id
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY oi.order_id, oi.product_id
),

multi_item_baskets AS (
  SELECT vb.order_id, vb.product_id
  FROM valid_baskets vb
  JOIN (
    SELECT order_id, COUNT(DISTINCT product_id) AS basket_size
    FROM valid_baskets GROUP BY order_id
  ) bs USING (order_id)
  WHERE bs.basket_size > 1
),

totals AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders FROM multi_item_baskets
),

product_freq AS (
  SELECT product_id, COUNT(DISTINCT order_id) AS orders_with_product
  FROM multi_item_baskets GROUP BY product_id
),

pair_counts AS (
  SELECT
    a.product_id AS product_a,
    b.product_id AS product_b,
    COUNT(DISTINCT a.order_id) AS orders_with_pair
  FROM multi_item_baskets a
  JOIN multi_item_baskets b
    ON a.order_id = b.order_id AND a.product_id < b.product_id
  GROUP BY product_a, product_b
  HAVING COUNT(DISTINCT a.order_id) >= min_pair_orders
)

SELECT
  s.product_a,
  prod_a.name AS product_a_name,
  s.product_b,
  prod_b.name AS product_b_name,
  s.orders_with_pair,
  ROUND(SAFE_DIVIDE(s.orders_with_pair, t.total_orders) * 100, 4) AS support_pct,
  ROUND(SAFE_DIVIDE(s.orders_with_pair, pa.orders_with_product) * 100, 2) AS confidence_a_to_b_pct,
  ROUND(
    SAFE_DIVIDE(
      SAFE_DIVIDE(s.orders_with_pair, t.total_orders),
      SAFE_DIVIDE(pa.orders_with_product, t.total_orders)
      * SAFE_DIVIDE(pb.orders_with_product, t.total_orders)
    ), 2
  ) AS lift
FROM pair_counts s
CROSS JOIN totals t
JOIN product_freq pa ON s.product_a = pa.product_id
JOIN product_freq pb ON s.product_b = pb.product_id
JOIN `bigquery-public-data.thelook_ecommerce.products` prod_a ON s.product_a = prod_a.id
JOIN `bigquery-public-data.thelook_ecommerce.products` prod_b ON s.product_b = prod_b.id
WHERE SAFE_DIVIDE(
        SAFE_DIVIDE(s.orders_with_pair, t.total_orders),
        SAFE_DIVIDE(pa.orders_with_product, t.total_orders)
        * SAFE_DIVIDE(pb.orders_with_product, t.total_orders)
      ) > 1.5
ORDER BY lift DESC
LIMIT 50;
```

**Resultado:** _[PLACEHOLDER: tabla con top-10 pares por lift, con nombres de producto — `dashboards/q6_affinity.png`]_

**Lectura:** _[PLACEHOLDER: 3–5 pares con lift > 3.0 y volumen suficiente para defender un bundle real. El resto es conversación de reunión, no input de pricing.]_

Archivo completo: [`sql_queries/06_product_affinity.sql`](sql_queries/06_product_affinity.sql)

## Hallazgos y recomendaciones

### Hallazgos

_[PLACEHOLDER: se completa al correr las queries contra el snapshot actual. Formato esperado:]_

- El AOV actual es de _USD X.XX_; el MoM de los últimos tres meses es _(positivo/negativo/mixto)_, lo que apunta a _(explicación breve)_.
- La retención M1 promedio está en _X.X%_, con un decay a M3 de _X.X%_. _(Cohortes anómalas, si las hay.)_
- El leak más grande del funnel está entre _(producto→carrito / carrito→compra)_, con un drop-off de _X%_.
- _X%_ de la base son Champions y concentran _X%_ del revenue. At Risk + Cannot Lose suman _X_ clientes, con un valor histórico combinado de _USD X_.
- _X_ SKUs están en Dead Stock acumulando _USD X_ de capital estancado. _X_ SKUs están en Reorder Now.
- Tres pares con lift defendible surgieron: _(par 1, par 2, par 3)_.

### Recomendaciones

_[PLACEHOLDER: se completa a partir de los hallazgos. Formato esperado:]_

- Priorizar un experimento de _(PDP / checkout)_ dado el leak principal del funnel.
- Armar una campaña de reactivación sobre At Risk + Cannot Lose, presupuestada a partir del valor histórico combinado.
- Liquidar los SKUs en Dead Stock con >180 días on-hand. El capital recuperado financia reposición de los SKUs en Reorder Now.
- Probar _(par con mayor lift)_ como bundle en PDP por 30 días. Medir uplift en AOV de las órdenes que incluyen el par.

## Dashboards

Cinco vistas en Looker Studio sobre los outputs de las queries. Cada una apunta a un consumidor distinto (dirección, growth, CRO, CRM, ops + merchandising). No son cinco copias filtradas de la misma pantalla.

**Dashboard público:** _[PLACEHOLDER: URL de Looker Studio]_

- `dashboards/01_overview.png` — revenue, órdenes, AOV, MoM
- `dashboards/02_cohort_retention.png` — triángulo de cohortes
- `dashboards/03_conversion_funnel.png` — drop-off por etapa
- `dashboards/04_rfm_segmentation.png` — matriz de segmentos
- `dashboards/05_inventory_affinity.png` — inventario + pares con mayor lift

## Reproducir

Abre la [consola de BigQuery](https://console.cloud.google.com/bigquery) con cualquier proyecto de Google Cloud. El sandbox gratis alcanza. Asegúrate de tener acceso a `bigquery-public-data.thelook_ecommerce`, copia cualquier archivo de `sql_queries/` y córrelo. No hay parámetros que tocar; la fecha de "hoy" se resuelve desde el dataset. Cada query procesa menos de 1 GB.

## Limitaciones

El dataset no expone shipping, impuestos ni descuentos. Lo que llamo revenue es merchandise revenue, o sea `sale_price` sumado a nivel línea. No gross. Si alguien cruza esto con contabilidad real va a haber diferencia, y es esperado.

No hay atribución multi-touch. El funnel y las lecturas por canal usan el último `traffic_source` registrado en `users`. Es una simplificación consciente; para multi-touch haría falta una tabla de sesiones con timestamps que no está en este dataset.

Los thresholds de inventario (14/30/120 días de supply, 180 de antigüedad) son defaults razonables. En producción se parametrizan por categoría o por lead time del proveedor.

No hay tests de dbt ni CI. En un repo productivo importan. Acá sería ruido.
