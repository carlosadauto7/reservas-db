#!/usr/bin/env bash
# ============================================================================
# reset.sh — Script de recriação limpa do banco (Tasks J3, A1, B1, J5)
# Uso:
#   ./reset.sh          -> Roda 01 a 06 (Schema, Exclude, Triggers, Functions/Views, Seed Base e Roles)
#   ./reset.sh --10k    -> Roda também 07_seed_10k.sql e 08_indexes_explain.sql
#   ./reset.sh --full   -> Roda 01 a 09 (inclui as 5 consultas analíticas B9)
# ============================================================================

set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5434}"
DB_NAME="${DB_NAME:-reservas_db}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
export PGPASSWORD="${DB_ADMIN_PASSWORD:-postgres_password}"

PSQL_CMD=(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1)

echo "============================================================"
echo " Iniciando reset do banco '${DB_NAME}' em ${DB_HOST}:${DB_PORT}"
echo "============================================================"

for script in \
    "sql/01_schema.sql" \
    "sql/02_exclude.sql" \
    "sql/03_triggers.sql" \
    "sql/04_functions_views.sql" \
    "sql/05_seed.sql" \
    "sql/06_roles.sql"
do
    echo "-> Executando ${script} ..."
    "${PSQL_CMD[@]}" -q -f "$script"
done

if [[ "${1:-}" == "--10k" || "${1:-}" == "--full" ]]; then
    echo "-> Executando sql/07_seed_10k.sql (Povoamento de 10.000+ reservas) ..."
    "${PSQL_CMD[@]}" -q -f "sql/07_seed_10k.sql"

    echo "-> Executando sql/08_indexes_explain.sql (Índices e EXPLAIN ANALYZE) ..."
    "${PSQL_CMD[@]}" -f "sql/08_indexes_explain.sql" > "sql/explain_output.txt"
    echo "   (Saída do EXPLAIN ANALYZE salva em sql/explain_output.txt)"
fi

if [[ "${1:-}" == "--full" ]]; then
    echo "-> Executando sql/09_analytics.sql (5 Consultas Analíticas) ..."
    "${PSQL_CMD[@]}" -f "sql/09_analytics.sql" > "sql/analytics_output.txt"
    echo "   (Saída das consultas analíticas salva em sql/analytics_output.txt)"
fi

TOTAL_RESERVAS=$("${PSQL_CMD[@]}" -t -A -c "SELECT count(*) FROM reserva;")
echo "============================================================"
echo " Reset concluído com sucesso! Total de reservas: ${TOTAL_RESERVAS}"
echo "============================================================"
