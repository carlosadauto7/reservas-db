#!/usr/bin/env bash
# ============================================================================
# demo_5min.sh — Roteiro Fixo da Demonstração de 5 Minutos (Task J5)
# Sequência: reset.sh -> 1. Reserva Válida -> 2. Conflito -> 3. Limite
#            -> 4. Cancelamento -> 5. Acesso Negado (conectado como app_reservas)
# ============================================================================

set -euo pipefail

./reset.sh

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5434}"
DB_NAME="${DB_NAME:-reservas_db}"
export PGPASSWORD="app_reservas_pass"

PSQL_APP=(psql -h "$DB_HOST" -p "$DB_PORT" -U "app_reservas" -d "$DB_NAME")

echo ""
echo "============================================================================"
echo " PASSO 1: RESERVA VÁLIDA (Conectado como app_reservas)"
echo " Aluno Gabriel (ID 8) reserva a Sala A-102 (ID 2) para amanhã das 10:00 às 12:00"
echo "============================================================================"
"${PSQL_APP[@]}" -c "
SELECT criar_reserva(
    2, 8,
    ((CURRENT_DATE + 2) + TIME '10:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '12:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Reserva Válida #1',
    15
) AS id_reserva_criada;
"

echo "============================================================================"
echo " PASSO 2: CONFLITO DE HORÁRIO (EXCLUDE USING gist)"
echo " Outro usuário (ID 9) tenta reservar a mesma Sala A-102 das 11:00 às 13:00"
echo "============================================================================"
"${PSQL_APP[@]}" -c "
SELECT criar_reserva(
    2, 9,
    ((CURRENT_DATE + 2) + TIME '11:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '13:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Tentativa Sobreposta (Deve Falhar)',
    15
);
" || true

echo ""
echo "============================================================================"
echo " PASSO 3: LIMITE DE 3 RESERVAS ATIVAS FUTURAS POR USUÁRIO (Trigger A4)"
echo " Gabriel (ID 8) cria a 2ª (12:00-14:00, adjacente!) e a 3ª (14:00-16:00),"
echo " e em seguida tenta criar a 4ª reserva futura (16:00-18:00 -> Deve Falhar!)"
echo "============================================================================"
"${PSQL_APP[@]}" -c "
SELECT criar_reserva(
    2, 8,
    ((CURRENT_DATE + 2) + TIME '12:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '14:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Reserva #2 (Adjacente 12h-14h)',
    15
) AS id_reserva_2;

SELECT criar_reserva(
    2, 8,
    ((CURRENT_DATE + 2) + TIME '14:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '16:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Reserva #3 (14h-16h)',
    15
) AS id_reserva_3;
"

echo "-> Tentando a 4ª reserva ativa futura para o mesmo usuário (ID 8):"
"${PSQL_APP[@]}" -c "
SELECT criar_reserva(
    2, 8,
    ((CURRENT_DATE + 2) + TIME '16:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '18:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Reserva #4 (Deve ser bloqueada pela Trigger A4)',
    15
);
" || true

echo ""
echo "============================================================================"
echo " PASSO 4: CANCELAMENTO E LIBERAÇÃO DE VAGA/HORÁRIO (Function B3 + Trigger A3)"
echo " 4a) Usuário não-titular (ID 9) tenta cancelar a reserva 22 de Gabriel -> Falha!"
echo " 4b) Gabriel (ID 8) cancela sua própria reserva 22 -> Sucesso e libera vaga!"
echo "============================================================================"
"${PSQL_APP[@]}" -c "SELECT cancelar_reserva(22, 9);" || true
"${PSQL_APP[@]}" -c "SELECT cancelar_reserva(22, 8) AS cancelamento_confirmado;"

echo "-> Nova reserva no horário recém-liberado (10:00 às 12:00) agora passa:"
"${PSQL_APP[@]}" -c "
SELECT criar_reserva(
    2, 8,
    ((CURRENT_DATE + 2) + TIME '10:00') AT TIME ZONE 'America/Sao_Paulo',
    ((CURRENT_DATE + 2) + TIME '12:00') AT TIME ZONE 'America/Sao_Paulo',
    'Demo J5 — Reagendamento após Cancelamento',
    15
) AS id_reagendamento;
"

echo "============================================================================"
echo " PASSO 5: ACESSO NEGADO ÀS TABELAS BASE (Role app_reservas — Task A5)"
echo " Tentando SELECT * FROM reserva e SELECT * FROM log_reserva como app_reservas"
echo "============================================================================"
"${PSQL_APP[@]}" -c "SELECT * FROM reserva LIMIT 1;" || true
"${PSQL_APP[@]}" -c "SELECT * FROM log_reserva LIMIT 1;" || true

echo ""
echo "-> Mas a consulta às Views permitidas (v_reservas_usuario) funciona normalmente:"
"${PSQL_APP[@]}" -c "
SELECT reserva_id, usuario_nome, sala_codigo, data_reserva, hora_inicio, hora_fim, finalidade
FROM v_reservas_usuario
WHERE usuario_id = 8;
"
