-- ============================================================================
-- B8. DOIS ÍNDICES E EXPLAIN ANALYZE (Antes e Depois)
-- ============================================================================
-- Lembrando que a constraint EXCLUDE (A2) já criou um índice GiST em:
--   (sala_id WITH =, periodo WITH &&) WHERE (status = 'ATIVA')
-- Portanto, NÃO duplicamos esse índice! Criamos dois índices B-Tree parciais
-- para padrões de consulta onde o GiST não é aplicável (levando a Seq Scan):
--
--   Índice 1 (Parcial + Expressão em B-Tree):
--     idx_reserva_data_inicio_ativa em (((lower(periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE), lower(periodo))
--     INCLUDE (sala_id, usuario_id, finalidade) WHERE status = 'ATIVA'
--     -> Acelera a consulta da agenda do dia (v_agenda_dia) filtrada por data e ordenada por horário.
--
--   Índice 2 (Parcial Composto B-Tree):
--     idx_reserva_usuario_ativa em (usuario_id, lower(periodo) DESC)
--     WHERE status = 'ATIVA'
--     -> Acelera a consulta das reservas ativas de um usuário (v_reservas_usuario),
--        eliminando tanto o Seq Scan quanto o Sort!
-- ============================================================================

SET TIME ZONE 'America/Sao_Paulo';

DROP INDEX IF EXISTS idx_reserva_sala_data_ativa;
DROP INDEX IF EXISTS idx_reserva_data_inicio_ativa;
DROP INDEX IF EXISTS idx_reserva_usuario_ativa;
ANALYZE reserva;

\echo '============================================================================'
\echo 'CONSULTA 1 (Agenda por Dia ordenada por horário) — ANTES DO ÍNDICE'
\echo '============================================================================'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, sala_id, usuario_id, lower(periodo) AS inicio, finalidade
FROM reserva
WHERE status = 'ATIVA'
  AND (lower(periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE = CURRENT_DATE
ORDER BY lower(periodo);

\echo '============================================================================'
\echo 'CONSULTA 2 (Reservas Ativas de um Usuário) — ANTES DO ÍNDICE'
\echo '============================================================================'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, sala_id, usuario_id, periodo, finalidade
FROM reserva
WHERE usuario_id = 6
  AND status = 'ATIVA'
ORDER BY lower(periodo) DESC;

-- ----------------------------------------------------------------------------
-- CRIAÇÃO DOS DOIS ÍNDICES PARCIAIS B-TREE (B8)
-- ----------------------------------------------------------------------------

-- Índice 1: B-Tree parcial por data da reserva + horário de início
CREATE INDEX idx_reserva_data_inicio_ativa
    ON reserva (
        ((lower(periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE),
        lower(periodo) ASC
    )
    INCLUDE (sala_id, usuario_id, finalidade)
    WHERE status = 'ATIVA';

-- Índice 2: B-Tree parcial para reservas ativas de um usuário ordenadas por início
CREATE INDEX idx_reserva_usuario_ativa
    ON reserva (usuario_id, lower(periodo) DESC)
    WHERE status = 'ATIVA';

ANALYZE reserva;

\echo '============================================================================'
\echo 'CONSULTA 1 (Agenda por Dia ordenada por horário) — DEPOIS DO ÍNDICE'
\echo '============================================================================'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, sala_id, usuario_id, lower(periodo) AS inicio, finalidade
FROM reserva
WHERE status = 'ATIVA'
  AND (lower(periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE = CURRENT_DATE
ORDER BY lower(periodo);

\echo '============================================================================'
\echo 'CONSULTA 2 (Reservas Ativas de um Usuário) — DEPOIS DO ÍNDICE'
\echo '============================================================================'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, sala_id, usuario_id, periodo, finalidade
FROM reserva
WHERE usuario_id = 6
  AND status = 'ATIVA'
ORDER BY lower(periodo) DESC;
