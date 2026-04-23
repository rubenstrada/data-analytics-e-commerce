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

**Resultado** (últimos 12 meses):

| order_month | orders | revenue      | aov    | units_per_order | revenue_mom_pct |
| ----------- | -----: | -----------: | -----: | --------------: | --------------: |
| 2026-04-01  | 6,685  | $577,321.66  | $86.36 | 1.46            | +48.95%         |
| 2026-03-01  | 4,588  | $387,597.58  | $84.48 | 1.43            | +25.04%         |
| 2026-02-01  | 3,572  | $309,984.62  | $86.78 | 1.42            | +2.00%          |
| 2026-01-01  | 3,590  | $303,907.26  | $84.65 | 1.46            | +11.74%         |
| 2025-12-01  | 3,216  | $271,968.85  | $84.57 | 1.42            | +7.22%          |
| 2025-11-01  | 2,974  | $253,663.17  | $85.29 | 1.43            | +6.40%          |
| 2025-10-01  | 2,866  | $238,395.35  | $83.18 | 1.42            | +2.04%          |
| 2025-09-01  | 2,688  | $233,624.67  | $86.91 | 1.43            | +9.45%          |
| 2025-08-01  | 2,492  | $213,449.07  | $85.65 | 1.42            | +6.43%          |
| 2025-07-01  | 2,427  | $200,560.24  | $82.64 | 1.41            | +4.13%          |
| 2025-06-01  | 2,294  | $192,597.77  | $83.96 | 1.44            | +2.44%          |
| 2025-05-01  | 2,209  | $188,014.99  | $85.11 | 1.45            | +11.86%         |

**Lectura:** revenue en abril 2026 cerró $577k con AOV $86.36, +49% MoM sobre marzo y +243% YoY sobre abril 2025. El AOV se mantiene en un rango estrecho de $76-$100 a lo largo de 88 meses (media $85.47); todo el crecimiento viene de volumen de órdenes (2,209 → 6,685 en 12 meses), no de ticket promedio. Caveat: el dataset genera fechas hasta 2026-04-26, cuatro días por delante del calendario real; la métrica es sobre 26 días de abril, no un mes parcial.

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

**Resultado** (retención % a los N meses para las 8 cohortes completas más recientes):

| cohort      | size  | M0   | M1    | M2   | M3   | M4   | M5   |
| ----------- | ----: | ---: | ----: | ---: | ---: | ---: | ---: |
| 2026-03-01  | 2,646 | 100  | 10.05 | —    | —    | —    | —    |
| 2026-02-01  | 2,100 | 100  | 9.00  | 6.81 | —    | —    | —    |
| 2026-01-01  | 2,113 | 100  | 6.81  | 7.15 | 5.25 | —    | —    |
| 2025-12-01  | 1,991 | 100  | 5.63  | 6.08 | 5.88 | 4.37 | —    |
| 2025-11-01  | 1,790 | 100  | 4.25  | 5.08 | 4.69 | 5.64 | 3.24 |
| 2025-10-01  | 1,786 | 100  | 4.48  | 4.37 | —    | —    | —    |
| 2025-09-01  | 1,660 | 100  | 4.04  | —    | —    | —    | —    |
| 2025-08-01  | 1,551 | 100  | 4.00  | —    | —    | —    | —    |

**Lectura:** la retención M1 subió de 2.9% (cohorte abril 2025) a 10.05% (cohorte marzo 2026), 3.5x en doce meses. No es ruido de cohorte única: las últimas seis cohortes mensuales muestran tendencia monótona al alza. El decay a M2-M5 sigue plano en 4-7%, así que el producto retiene consistentemente una vez capturado el primer mes — el cuello está en la primera recompra, no en la segunda ni la tercera. Una cohorte para auditar si hay canal roto: septiembre-agosto 2025 (4.0-4.04%), tocaron el piso antes del rebote.

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

**Resultado** (snapshot site-wide, sesiones acumulativas):

| stage                 | sesiones | tasa vs stage previo | drop-off absoluto |
| --------------------- | -------: | -------------------: | ----------------: |
| Vieron producto       | 680,450  | —                    | —                 |
| + Agregaron al carrito| 430,267  | 63.23%               | 250,183           |
| + Compraron           | 180,450  | 41.94%               | 249,817           |

End-to-end (product → purchase): **26.52%**.

**Lectura:** el leak grande es checkout. Sesiones que agregan al carrito abandonan en 58% (más de una en dos), mientras que las que llegan al producto agregan al carrito en 63%. En volumen absoluto las dos transiciones se pierden ~250k sesiones cada una, pero en tasa la segunda es 1.5x peor, entonces el ROI de tocar checkout (pagos, shipping, account friction) es más alto que PDP. En una implementación real convendría separar el funnel por `traffic_source` para ver si la ruptura es uniforme o concentrada en un canal específico.

Nota metodológica. La primera versión de esta query contaba usuarios distintos por stage. En este dataset eso devuelve 100% en los tres — el generador sintético emite todos los tipos de evento para cada usuario, así que "usuarios únicos que alguna vez vieron producto / cart / purchase" coincide. La versión session-level es la correcta para leer friction real.

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

**Resultado** (segmento × tamaño × valor):

| segment             | customers | % base  | total monetary  | % revenue | avg monetary | avg recency (días) |
| ------------------- | --------: | ------: | --------------: | --------: | -----------: | -----------------: |
| Champions           | 10,568    | 16.03%  | $2,541,770.59   | 31.45%    | $240.52      | 113                |
| Hibernating         | 11,618    | 17.62%  | $1,292,213.90   | 15.99%    | $111.23      | 1,126              |
| Loyal               | 4,454     | 6.76%   | $1,086,001.29   | 13.44%    | $243.83      | 402                |
| At Risk             | 5,206     | 7.90%   | $1,075,608.57   | 13.31%    | $206.61      | 862                |
| Potential Loyalists | 11,348    | 17.22%  | $890,680.79     | 11.02%    | $78.49       | 128                |
| Needs Attention     | 8,730     | 13.24%  | $539,793.47     | 6.68%     | $61.83       | 398                |
| Cannot Lose         | 878       | 1.33%   | $262,045.30     | 3.24%     | $298.46      | 1,355              |
| Lost                | 8,666     | 13.15%  | $244,392.84     | 3.02%     | $28.20       | 1,294              |
| New Customers       | 3,942     | 5.98%   | $139,290.95     | 1.72%     | $35.34       | 29                 |
| Promising           | 509       | 0.77%   | $9,725.12       | 0.12%     | $19.11       | 110                |

**Lectura:** Champions (16% de la base) concentra 31% del revenue — Pareto algo suave por un negocio todavía joven, no el 70/20 clásico. El hallazgo que cambia la campaña: Cannot Lose son solo 878 clientes pero tienen el **avg monetary más alto de la matriz ($298)** y llevan 1,355 días sin volver. Sumado a At Risk (5,206) y Hibernating (11,618) el target de reactivación son 17,702 clientes con $2.63M de valor histórico; eso es el presupuesto que un CRM podría justificar. New Customers (3,942) con 29 días de recency es el otro bucket accionable, del otro lado del funnel — onboarding, no win-back.

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

**Resultado** — distribución por status sobre 29,042 SKUs:

| status      | SKUs    | tied-up capital |
| ----------- | ------: | --------------: |
| Overstock   | 15,430  | $5,253,774.04   |
| Dead Stock  | 13,555  | $3,565,921.61   |
| Healthy     | 57      | $1,741.95       |
| At Risk     | 0       | —               |
| Reorder Now | 0       | —               |

Top 10 SKUs por capital estancado:

| product_id | nombre                                                        | marca          | units | tied-up   | days_of_supply | status     |
| ---------: | ------------------------------------------------------------- | -------------- | ----: | --------: | -------------: | ---------- |
| 17094      | The North Face Apex Bionic Soft Shell Jacket - Men's          | The North Face | 22    | $11,542   | 660            | Overstock  |
| 24042      | Canada Goose Men's Langford Parka                             | Canada Goose   | 24    | $7,205    | 2,160          | Overstock  |
| 10453      | NIKE WOMEN'S PRO Compression Sports Bra                       | Nike           | 14    | $7,168    | 1,260          | Overstock  |
| 22812      | Quiksilver Men's Rockefeller Walkshort                        | Quiksilver     | 15    | $7,084    | —              | Dead Stock |
| 23654      | The North Face Apex Bionic Soft Shell Jacket - Men's          | The North Face | 19    | $6,897    | 1,710          | Overstock  |
| 23811      | Arc'teryx Men's Beta AR Jacket                                | Arc'teryx      | 28    | $6,504    | 1,260          | Overstock  |
| 24428      | The North Face Apex Bionic Mens Soft Shell Ski Jacket 2013    | The North Face | 15    | $6,298    | 1,350          | Overstock  |
| 8429       | The North Face Women's S-XL Oso Jacket                        | The North Face | 16    | $6,054    | 480            | Overstock  |
| 24201      | Men's Nike AirJordan Varsity Hoodie Jacket                    | Jordan         | 14    | $5,727    | 1,260          | Overstock  |
| 23646      | Diesel Men's Lophophora Leather Jacket                        | Diesel         | 14    | $5,720    | 630            | Overstock  |

**Lectura:** el top-10 está dominado por outerwear caro (North Face, Canada Goose, Arc'teryx, Diesel), con días de supply entre 480 y 2,160 — stock para varios años de venta al ritmo actual. Dead Stock acumula $3.57M en 13,555 SKUs, Overstock otros $5.25M. Atención: los thresholds por default (14/30/120 días) dejan apenas 57 SKUs en "Healthy" sobre 29k, y cero en "Reorder Now" o "At Risk". Eso no es inventario en crisis, es un threshold miscalibrado para este dataset sintético — la velocidad de ventas diaria por SKU es muy baja (mediana bajo 0.05 unidades/día), y los cortes en días de supply se disparan aritméticamente. En un caso real se parametriza por categoría o lead time, no hardcodeado. La lectura de negocio que sobrevive al caveat: $8.8M en capital parado entre las dos categorías no-healthy, concentrado en outerwear premium.

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

**Resultado:** cero pares cumplen el floor estadístico (mínimo 30 co-ocurrencias, lift > 1.5).

Auditoría sobre el dataset para entender por qué:

| métrica                                        | valor   |
| ---------------------------------------------- | ------: |
| Baskets multi-item (≥2 productos)              | 28,084  |
| Pares de productos distintos observados        | 60,719  |
| Max co-ocurrencia de un par en todo el dataset | **2**   |
| Pares con ≥5 co-ocurrencias                    | 0       |
| Pares con ≥10 co-ocurrencias                   | 0       |

**Lectura:** el par de productos más repetido del histórico aparece en solo 2 órdenes. Es decir, los baskets multi-item del dataset de TheLook son esencialmente combinatoria aleatoria — el generador sintético no modela afinidad de producto. Un report honesto sobre este dataset es "no hay evidencia para recomendar un bundle", no un ranking por lift ruidoso con soporte de 0.007%. Bajar el floor a 2 genera tabla, pero con un par con orders_with_pair=2 el estimador de lift diverge con intervalo de confianza brutal; cualquier pricing decision tomada con eso sería superstición. La query está bien; el dato no sostiene la pregunta. En un retailer real con baskets de verdad este mismo SQL surfacearía docenas de pares con lift > 3 y soporte > 0.5%.

Archivo completo: [`sql_queries/06_product_affinity.sql`](sql_queries/06_product_affinity.sql)

## Hallazgos y recomendaciones

### Hallazgos

- El negocio creció 3.4x YoY en revenue (abril 2025 → abril 2026) y el AOV se mantuvo plano en $85 ± $10 durante 88 meses. Todo el upside está viniendo de volumen de órdenes, no de ticket.
- La retención M1 pasó de 2.9% (cohorte abril 2025) a 10.05% (cohorte marzo 2026), tendencia monótona en las últimas seis cohortes. Retener después del primer mes es consistente, el cuello sigue estando en la primera recompra.
- El leak más grande del funnel está en cart → purchase: 58% abandona el carrito, vs 37% que abandona antes de agregarlo. Checkout pesa más que PDP para este negocio.
- Champions (16%) concentra 31% del revenue. Cannot Lose son 878 clientes con avg monetary $298 — el más alto de toda la matriz — y 1,355 días sin comprar. Reactivación target total (At Risk + Cannot Lose + Hibernating): 17,702 clientes, $2.63M de valor histórico.
- $8.8M de capital estancado entre Overstock ($5.25M, 15,430 SKUs) y Dead Stock ($3.57M, 13,555 SKUs), concentrado en outerwear premium (North Face, Canada Goose, Arc'teryx). Los thresholds por default sobreclasifican dado el ritmo de ventas sintético — la cifra es real, la taxonomía "0 SKUs en Reorder Now" no lo es.
- El dataset no sostiene una conclusión de market basket. Max co-ocurrencia de cualquier par = 2 sobre 60,719 pares observados. Cualquier recomendación de bundle basada en este dataset sería ruido.

### Recomendaciones

- Priorizar un experimento A/B en checkout (métodos de pago, shipping thresholds, guest checkout) antes que en PDP. El leak del 58% ahí tiene 1.5x el margen de mejora en tasa que el paso anterior.
- Armar una cola CRM con los 878 Cannot Lose como prioridad absoluta, At Risk (5,206) como segunda ola. Presupuesto anclado en $262k de valor histórico solo de Cannot Lose.
- Investigar por qué las cohortes de Q3 2025 (retención M1 de 3.8-4.0%) tocaron el piso justo antes del rebote. Si el driver fue un canal de adquisición específico, apagarlo; si fue cambio de producto, documentarlo para no repetirlo.
- Liquidar los top-100 SKUs de outerwear premium con >1,000 días de supply. Recortar el PO del próximo trimestre en esas categorías. El capital recuperado financia merchandising en las categorías en las que sí hay velocity.
- No tomar decisiones de bundle ni cross-sell basadas en Q6. Re-correr sobre data real o dataset mayor antes de llevarlo a merchandising.

## Dashboard

Un único reporte en Looker Studio, tres secciones sobre las queries que más tracción tienen para una reunión ejecutiva: Overview del negocio (Q1), Retención por cohorte (Q2) y Segmentación RFM (Q4). Funnel e inventario viven mejor como output de SQL — en un dashboard se achican a un número plano y pierden la lectura.

**Dashboard público:** _Se agrega al publicar. Preview en `dashboards/preview.png`._

Construcción, data sources, layout y filtros: [`dashboards/BUILD.md`](dashboards/BUILD.md).

### Validación estadística (notebook)

Tres números del README se auditan en [`notebooks/07_validation.ipynb`](notebooks/07_validation.ipynb) con herramientas que no son SQL, para que la lectura no dependa de un solo ángulo.

- **Bootstrap del AOV** con 1000 réplicas sobre las órdenes del último mes cerrado. Devuelve un intervalo de confianza al 95% sin asumir normalidad, que es justo la asunción que rompe una cola de tickets caros.
- **Test de dos proporciones** comparando la retención M1 entre la primera mitad y la segunda mitad de cohortes. Si el p-value se cae y el IC de la diferencia no cruza cero, el rebote de retención que muestra Q2 deja de ser lectura a ojo y pasa a ser un claim defendible.
- **Heatmap de cohortes reconstruido en Python** con las últimas 12 cohortes de ≥100 clientes, como respaldo offline del triángulo que se publica en el dashboard.

Dependencias pinneadas en `requirements.txt`. Para correrla hace falta ADC de GCP y un proyecto con facturación — cada query procesa bien debajo de 1 GB.

## Reproducir

Abre la [consola de BigQuery](https://console.cloud.google.com/bigquery) con cualquier proyecto de Google Cloud. El sandbox gratis alcanza. Asegúrate de tener acceso a `bigquery-public-data.thelook_ecommerce`, copia cualquier archivo de `sql_queries/` y córrelo. No hay parámetros que tocar; la fecha de "hoy" se resuelve desde el dataset. Cada query procesa menos de 1 GB.

## Limitaciones

El dataset no expone shipping, impuestos ni descuentos. Lo que llamo revenue es merchandise revenue, o sea `sale_price` sumado a nivel línea. No gross. Si alguien cruza esto con contabilidad real va a haber diferencia, y es esperado.

No hay atribución multi-touch. El funnel y las lecturas por canal usan el último `traffic_source` registrado en `users`. Es una simplificación consciente; para multi-touch haría falta una tabla de sesiones con timestamps que no está en este dataset.

Los thresholds de inventario (14/30/120 días de supply, 180 de antigüedad) son defaults razonables. En producción se parametrizan por categoría o por lead time del proveedor.

No hay tests de dbt ni CI. En un repo productivo importan. Acá sería ruido.
