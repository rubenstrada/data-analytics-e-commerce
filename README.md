# E-Commerce Data Analytics Dashboard 🛒📊

Este repositorio contiene un proyecto analítico de extremo a extremo (End-to-End) utilizando el dataset público `thelook_ecommerce` alojado en Google BigQuery. El objetivo es extraer insights accionables sobre el comportamiento del consumidor, la salud de las ventas y el rendimiento del inventario, visualizados a través de un tablero interactivo.

## 🛠️ Stack Tecnológico
* **Data Warehouse:** Google BigQuery (SQL Estándar)
* **Visualización & BI:** Looker Studio
* **Técnicas Aplicadas:** CTEs (Common Table Expressions), Window Functions, Agregaciones Complejas, Análisis de Cohortes.

## 📈 KPIs y Métricas Analizadas
El análisis se divide en tres pilares estratégicos de negocio:

1.  **Rendimiento de Ventas (Sales Health):**
    * Ingresos Totales (Revenue) y Valor Promedio de Pedido (AOV).
    * Identificación de los productos y categorías con mayor margen de ganancia.
2.  **Retención de Clientes (Cohort Analysis):**
    * Cálculo de la tasa de retención mensual.
    * Comportamiento de recompra de los usuarios a lo largo del tiempo.
3.  **Embudo de Conversión (Funnel Analysis):**
    * Rastreo del viaje del usuario: desde la vista del producto, adición al carrito, hasta la compra final.
    * Identificación de los principales puntos de abandono (Drop-off rates).

## 📂 Estructura del Repositorio
* `/sql_queries`: Contiene los scripts SQL optimizados utilizados para extraer y transformar los datos directamente desde BigQuery.
* `/dashboards`: Incluye capturas de pantalla y el documento PDF exportado del tablero interactivo desarrollado en Looker Studio para la toma de decisiones.

---
*Desarrollado para traducir datos crudos en decisiones estratégicas de negocio.*
