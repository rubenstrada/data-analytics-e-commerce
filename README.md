# E-Commerce Analytics — TheLook (BigQuery)

Proyecto de analítica end-to-end sobre el dataset público `bigquery-public-data.thelook_ecommerce`. Responde un set concreto de preguntas de negocio — cómo evolucionan las ventas, a qué clientes invertir, dónde se pierde el funnel, qué inventario está muerto y qué productos bundlear — con BigQuery Standard SQL.

El repo no busca mostrar "SQL que corre". Busca mostrar criterio: cómo se define un KPI, por qué se elige una segmentación, y cómo se entrega un output que un stakeholder pueda accionar.

## Descripción del proyecto

TheLook es un e-commerce ficticio cuyos datos transaccionales, de inventario y de eventos web están publicados por Google como dataset público en BigQuery. La forma de la data (orders, order_items, users, products, inventory_items, events) es realista para un D2C o marketplace.

Aquí se trata como si fuera un negocio real y se producen seis análisis que un analytics engineer junior debería poder owneear en un equipo real.

## Preguntas de negocio

Cada query responde una pregunta concreta, nivel stakeholder:

1. ¿Cómo evoluciona el revenue mes a mes y el AOV se está expandiendo o contrayendo?
2. ¿Qué tan bien retienen las cohortes nuevas en los meses posteriores a su primera compra?
3. ¿Dónde del funnel (vista de producto → carrito → compra) se está perdiendo más gente?
4. ¿A qué clientes debe priorizar marketing para retención, reactivación o upsell, y con qué lógica?
5. ¿Qué SKUs tienen capital estancado sin venderse y cuáles están por caer en stockout?
6. ¿Qué pares de productos se compran juntos más de lo que el azar explicaría — y por lo tanto son candidatos a cross-sell o bundle?

## Scope analítico

| Análisis | Archivo | Técnica |
|---|---|---|
| KPIs de ventas + crecimiento MoM | `sql_queries/01_sales_kpis.sql` | Agregación con `LAG` sobre ventana temporal |
| Retención por cohorte | `sql_queries/02_cohort_retention.sql` | Cohortes de adquisición, triángulo de retención |
| Funnel de conversión | `sql_queries/03_conversion_funnel.sql` | Conversión paso a paso y drop-off |
| Segmentación RFM | `sql_queries/04_rfm_segmentation.sql` | `NTILE` por quintiles + matriz de segmentos |
| Salud de inventario | `sql_queries/05_inventory_health.sql` | Velocidad de ventas, días de supply, capital estancado |
| Afinidad de producto | `sql_queries/06_product_affinity.sql` | Market basket: support, confidence, lift |

## Decisiones técnicas que importan

Son las decisiones que separan una query de portafolio de una desechable:

- **AOV a nivel orden.** `revenue / órdenes distintas`, no `AVG(sale_price)` sobre line items. El cálculo ingenuo ignora el tamaño del carrito y subestima el ticket. Error clásico de nivel junior.
- **Fecha de referencia dinámica.** Donde se necesita un "hoy", se ancla a `MAX(created_at)` del propio dataset. Nada de fechas hard-coded: el dataset público se actualiza solo y los hardcodes envejecen.
- **RFM por quintiles.** R, F y M se puntúan con `NTILE(5)`. Quintiles son relativos a la base actual de clientes, así que la distribución de segmentos se mantiene estable en el tiempo. Umbrales manuales ("VIP = 3+ órdenes en 30 días") son frágiles y se vuelven mentira el próximo trimestre.
- **Dead stock con doble condición.** Un SKU se marca como dead stock solo si tuvo cero ventas en 90 días *y además* tiene inventario con más de 180 días de antigüedad. Así no se castiga a un SKU recién lanzado.
- **Lift, no co-ocurrencia cruda.** Afinidad se rankea por lift con un piso de support. Rankear por conteo bruto solo surfacea productos populares que coaparecen por casualidad, no afinidades reales.

## Stack

- **Data warehouse:** Google BigQuery (Standard SQL)
- **Fuente:** `bigquery-public-data.thelook_ecommerce` (dataset público)
- **Visualización:** Looker Studio (dashboards no incluidos en este commit; la carpeta `dashboards/` queda como placeholder)
- **Técnicas:** CTEs, window functions (`LAG`, `NTILE`), `SAFE_DIVIDE`, self-joins para basket analysis, anclaje dinámico de fechas

## Estructura del repositorio

```
.
├── README.md
└── sql_queries/
    ├── 01_sales_kpis.sql
    ├── 02_cohort_retention.sql
    ├── 03_conversion_funnel.sql
    ├── 04_rfm_segmentation.sql
    ├── 05_inventory_health.sql
    └── 06_product_affinity.sql
```

La carpeta `dashboards/` no está versionada porque todavía no tiene contenido. Está reservada para un export de Looker Studio (PDF) y screenshots, que no son parte de este commit.

## Cómo reproducirlo

1. Abrir la [consola de BigQuery](https://console.cloud.google.com/bigquery) con cualquier proyecto de Google Cloud (una cuenta sandbox gratuita alcanza — el dataset público no genera costo de storage y las queries procesan pocos bytes).
2. Verificar que `bigquery-public-data.thelook_ecommerce` es accesible desde el proyecto.
3. Copiar cualquier archivo de `sql_queries/` al editor y correrlo tal cual. No hay parámetros que tocar.
4. Para `04_rfm_segmentation.sql`, la fecha de "hoy" se resuelve dinámicamente desde el dataset.
5. Para visualizar, conectar el output (o una vista guardada encima) a Looker Studio.

Costo estimado por query: menos de 1 GB procesado, cabe cómodamente en el tier gratuito mensual de BigQuery.

## Por qué este proyecto importa

Correr SQL contra un dataset público es barato. Entregar outputs que un negocio usaría no lo es. Cada query está escrita con tres cosas en mente:

- **Una decisión específica que soporta** — plan de reposición, segmento de CRM, candidatos a bundle, health check de cohorte.
- **Definiciones de métrica defendibles** — AOV a nivel orden, lift en vez de co-ocurrencia bruta, RFM por quintiles, dead stock con guard de antigüedad.
- **Reproducibilidad** — sin fechas hard-coded, sin asunciones de entorno, todo corre tal cual contra el dataset público.

## Limitaciones y asunciones

- El dataset no expone shipping, impuestos ni descuentos. "Revenue" acá es `sale_price` sumado a nivel línea, o sea merchandise revenue.
- Los items cancelados y devueltos se excluyen de revenue, cohortes y RFM. No son ventas realizadas.
- El funnel de `03_conversion_funnel.sql` es a nivel alcance de usuario, no por sesión. Un funnel session-level tendría que particionar por `session_id` y ordenar con `sequence_number`.
- Los thresholds de `05_inventory_health.sql` (14/30/120 días de supply, 180 días de antigüedad) son defaults razonables. En un caso real se parametrizan por categoría o por lead time del proveedor.

## Extensiones naturales

Si este proyecto creciera, los siguientes pasos lógicos serían:

- Materializar las queries como modelos dbt con tests de row count, non-null y unicidad.
- Agregar un dashboard de Looker Studio por workstream y commitear los PDFs exportados a `dashboards/`.
- Montar un modelo de LTV encima del output de RFM (análisis de supervivencia o un fit BG/NBD + Gamma-Gamma).
- Reemplazar el funnel site-wide por un funnel a nivel sesión usando `session_id` y `sequence_number`.
- Parametrizar los thresholds de inventario por categoría, idealmente como variables dbt.
