# Notebooks

## `07_validation.ipynb`

Valida dos afirmaciones del README con métodos no paramétricos:

1. **AOV del último mes cerrado** — bootstrap con 1000 réplicas sobre los order totals del mes cerrado más reciente (ancla dinámica `DATE_SUB(DATE_TRUNC(MAX(created_at), MONTH), INTERVAL 1 MONTH)`, no hardcoded). Devuelve media puntual, IC 95% percentil y SE empírico.
2. **Diferencia de retención M1 entre primer y último cohorte maduros** — test z de dos proporciones (pooled SE para el estadístico, SE desapareado para el IC Wald 95%). Excluye cohortes cuyo mes M1 todavía no cerró al momento de correr la notebook.

Salidas al final: el heatmap de retención con el triángulo superior enmascarado y celdas inmaduras en NaN, exportado a `../dashboards/validation_retention_heatmap.png` para que el README lo renderice.

### Cómo correrla

```bash
# 1. Autenticarse contra BigQuery
gcloud auth application-default login

# 2. Instalar dependencias
pip install -r ../requirements.txt

# 3. Ejecutar end-to-end y bakear outputs
jupyter nbconvert --to notebook --execute 07_validation.ipynb --inplace
```

El notebook lee de `bigquery-public-data.thelook_ecommerce` usando las credenciales por defecto del SDK (`google.cloud.bigquery.Client()` sin argumentos). No hay secretos versionados.

### Qué NO hace

- No re-calcula las 6 preguntas del README — eso vive en `sql_queries/`.
- No agrega cohortes nuevos ni cambia la ventana histórica: si el dataset público avanza, la notebook re-ancla sola.
- No publica en ningún lado; el único side effect es regenerar el PNG del heatmap.

### Por qué bootstrap y z-test

El AOV tiene cola derecha pesada por órdenes grandes, así que un IC paramétrico normal subestimaría la incertidumbre. Bootstrap no asume forma. El z-test de dos proporciones es lo estándar para comparar retenciones M1 entre dos cohortes — la única decisión no trivial fue usar pooled SE para el estadístico (H0 asume p1 = p2) y unpooled para el IC (H1 no impone igualdad), que es la receta clásica.
