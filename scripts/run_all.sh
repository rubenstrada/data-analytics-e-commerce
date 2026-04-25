#!/usr/bin/env bash
# Corre las 6 queries del repo contra BigQuery y deja los resultados en out/.
# No escribe en ningun dataset; solo lee bigquery-public-data.thelook_ecommerce.
#
# Requisitos previos:
#   - gcloud SDK instalado y autenticado (gcloud auth login)
#   - Un proyecto de facturacion activo (gcloud config set project <PROJECT>)
#
# Uso:
#   bash scripts/run_all.sh                    # corre todas las queries
#   bash scripts/run_all.sh sql_queries/04_rfm_segmentation.sql   # solo una
#
# Salida: CSV por query en out/<nombre>.csv. Se sobreescribe en cada corrida.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"
mkdir -p "${OUT_DIR}"

if ! command -v bq >/dev/null 2>&1; then
  echo "error: bq CLI no encontrado. Instala google-cloud-sdk y corre 'gcloud auth login' antes." >&2
  exit 1
fi

run_query () {
  local sql_path="$1"
  local name
  name="$(basename "${sql_path}" .sql)"
  local out_path="${OUT_DIR}/${name}.csv"

  echo ">>> ${name}"

  # 06_product_affinity.sql usa DECLARE, asi que hay que correrla como script
  # (bq query --use_legacy_sql=false --format=csv no soporta DECLARE en un job comun).
  if grep -q "^DECLARE" "${sql_path}"; then
    bq query \
      --use_legacy_sql=false \
      --max_rows=1000000 \
      --format=csv \
      --nouse_cache \
      --script_statement_timeout_ms=600000 \
      < "${sql_path}" > "${out_path}"
  else
    bq query \
      --use_legacy_sql=false \
      --max_rows=1000000 \
      --format=csv \
      --nouse_cache \
      < "${sql_path}" > "${out_path}"
  fi

  local rows
  rows=$(($(wc -l < "${out_path}") - 1))
  echo "    filas: ${rows} -> ${out_path}"
}

if [ $# -gt 0 ]; then
  run_query "$1"
  exit 0
fi

for sql in "${REPO_ROOT}"/sql_queries/*.sql; do
  run_query "${sql}"
done

echo
echo "Listo. CSVs en ${OUT_DIR}."
