/* =============================================================================
   05_inventory_health.sql
   -----------------------------------------------------------------------------
   Diagnóstico de salud de inventario a nivel producto: velocidad de ventas,
   días de supply, detección de dead stock y capital estancado.

   Dataset : bigquery-public-data.thelook_ecommerce
   Grano   : una fila por product_id
   Tablas  : inventory_items (una fila por unidad), order_items, products

   Qué mejora esta versión vs. la anterior
   ---------------------------------------
   La versión previa etiquetaba stock como "sano / riesgoso / exceso"
   usando una ventana de 30 días hardcodeada. Eso no le dice a operaciones
   NI CUÁNDO reordenar NI CUÁNTO capital está estancado — que es exactamente
   lo que se necesita para decidir.

   Esta versión:
     1. Calcula VELOCIDAD DE VENTAS sobre una ventana móvil de 90 días.
        Suaviza estacionalidad semanal y evita que una semana floja
        gatille un falso "dead stock".
     2. Traduce stock a DÍAS DE SUPPLY = unidades_on_hand / velocidad_diaria.
        Este es el número que ops realmente usa para planificar reposición,
        no el conteo de unidades.
     3. Marca DEAD STOCK con doble condición: "cero ventas en 90 días" Y
        "inventario con más de 180 días de antigüedad". Así un SKU recién
        lanzado no se clasifica erróneamente como muerto.
     4. Estima CAPITAL ESTANCADO (unidades * costo unitario). El decisor
        ordena por dólares, no por unidades.

   Thresholds dinámicos (percentiles del catálogo)
   ------------------------------------------------
   Los cortes fijos anteriores (14 / 30 / 120 días de supply) dejaban 57
   SKUs en Healthy sobre ~29k porque la mediana de daily_velocity en este
   dataset sintético es muy baja. En lugar de hardcodear, se calculan
   APPROX_QUANTILES sobre la distribución de days_of_supply del propio
   catálogo: p10, p25, p75. Los buckets son RELATIVOS al catálogo actual,
   así que la distribución de estados queda estable aunque cambie la
   velocidad global de ventas. Dead Stock mantiene criterio absoluto (cero
   ventas en 90d Y antigüedad > 180d) porque no tiene sentido relativizarlo.
============================================================================= */

WITH reference AS (
  SELECT MAX(DATE(created_at)) AS as_of_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
),

-- Velocidad de ventas sobre los últimos 90 días (unidades por día)
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

-- Pre-cálculo de days_of_supply para derivar percentiles del catálogo
pre_dos AS (
  SELECT
    ii.product_id,
    COUNT(*)           AS units_on_hand,
    MIN(DATE(ii.created_at)) AS oldest_unit_date,
    COALESCE(s.daily_velocity, 0) AS daily_velocity,
    SAFE_DIVIDE(COUNT(*), s.daily_velocity) AS days_of_supply
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items` ii
  LEFT JOIN sales_90d s USING (product_id)
  WHERE ii.sold_at IS NULL
  GROUP BY ii.product_id, s.daily_velocity
),

-- Percentiles dinámicos sobre la distribución de days_of_supply del catálogo
-- (solo SKUs que tienen velocidad > 0, para no contaminar con zeros infinitos)
thresholds AS (
  SELECT
    APPROX_QUANTILES(days_of_supply, 100)[OFFSET(10)] AS p10,
    APPROX_QUANTILES(days_of_supply, 100)[OFFSET(25)] AS p25,
    APPROX_QUANTILES(days_of_supply, 100)[OFFSET(75)] AS p75
  FROM pre_dos
  WHERE days_of_supply IS NOT NULL
),

-- Inventario on-hand: cada fila de inventory_items es UNA unidad física
on_hand AS (
  SELECT
    ii.product_id,
    ANY_VALUE(ii.product_name)     AS product_name,
    ANY_VALUE(ii.product_category) AS product_category,
    ANY_VALUE(ii.product_brand)    AS product_brand,
    COUNT(*)                       AS units_on_hand,
    ROUND(AVG(ii.cost), 2)         AS unit_cost,
    ROUND(SUM(ii.cost), 2)         AS tied_up_capital,
    -- Antigüedad de la unidad más vieja on-hand: indicador de aging risk
    MIN(DATE(ii.created_at))       AS oldest_unit_date
  FROM `bigquery-public-data.thelook_ecommerce.inventory_items` ii
  WHERE ii.sold_at IS NULL
  GROUP BY ii.product_id
)

SELECT
  oh.product_id,
  oh.product_name,
  oh.product_category,
  oh.product_brand,
  oh.units_on_hand,
  oh.unit_cost,
  oh.tied_up_capital,
  COALESCE(s.daily_velocity, 0)                                  AS daily_velocity,
  s.last_sale_date,
  DATE_DIFF(r.as_of_date, oh.oldest_unit_date, DAY)              AS oldest_unit_age_days,
  DATE_DIFF(r.as_of_date, s.last_sale_date, DAY)                 AS days_since_last_sale,
  -- Días de supply: cuánto dura el stock actual al ritmo actual de venta.
  -- NULL si velocidad es cero para evitar división por cero.
  ROUND(SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity), 1)      AS days_of_supply,
  CASE
    -- Dead Stock: 0 ventas en 90d Y el inventario ya está maduro (>180d).
    -- Criterio absoluto: no tiene sentido relativizarlo al catálogo.
    WHEN COALESCE(s.daily_velocity, 0) = 0
         AND DATE_DIFF(r.as_of_date, oh.oldest_unit_date, DAY) > 180
      THEN 'Dead Stock'
    -- Overstock: por encima del p75 de days_of_supply del catálogo
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) > th.p75
      THEN 'Overstock'
    -- Reorder Now: por debajo del p10 (cola baja de la distribución)
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) < th.p10
      THEN 'Reorder Now'
    -- At Risk: entre p10 y p25
    WHEN SAFE_DIVIDE(oh.units_on_hand, s.daily_velocity) BETWEEN th.p10 AND th.p25
      THEN 'At Risk'
    -- Healthy: entre p25 y p75
    ELSE 'Healthy'
  END AS inventory_status
FROM on_hand oh
LEFT JOIN sales_90d s USING (product_id)
CROSS JOIN reference r
CROSS JOIN thresholds th
-- Orden por capital estancado: para el CFO, el ranking que importa
ORDER BY oh.tied_up_capital DESC;
