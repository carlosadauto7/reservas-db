-- ============================================================================
-- B9. CINCO CONSULTAS ANALÍTICAS
--   1. JOIN (Múltiplas tabelas)
--   2. GROUP BY / HAVING
--   3. Subconsulta (Subquery correlacionada / escalar)
--   4. CTE (Common Table Expression com WITH)
--   5. Window Function (RANK() OVER / DENSE_RANK() OVER)
-- ============================================================================

SET TIME ZONE 'America/Sao_Paulo';

\echo '============================================================================'
\echo 'CONSULTA 1 [JOIN]: Detalhamento das próximas 10 reservas ativas em laboratórios com seus blocos, titulares e quantidade de recursos instalados'
\echo '============================================================================'
SELECT
    r.id                                                                 AS reserva_id,
    b.sigla                                                              AS bloco,
    s.codigo                                                             AS sala,
    s.tipo                                                               AS tipo_sala,
    u.nome                                                               AS responsavel,
    u.tipo                                                               AS perfil,
    to_char(lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') AS inicio,
    to_char(upper(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')            AS fim,
    COUNT(sr.recurso_id)                                                 AS tipos_equipamentos_na_sala
FROM reserva r
INNER JOIN sala s          ON s.id = r.sala_id
INNER JOIN bloco b         ON b.id = s.bloco_id
INNER JOIN usuario u       ON u.id = r.usuario_id
LEFT  JOIN sala_recurso sr ON sr.sala_id = s.id
WHERE r.status = 'ATIVA'
  AND upper(r.periodo) > CURRENT_TIMESTAMP
GROUP BY r.id, b.sigla, s.codigo, s.tipo, u.nome, u.tipo, r.periodo
ORDER BY lower(r.periodo) ASC
LIMIT 10;

\echo '============================================================================'
\echo 'CONSULTA 2 [GROUP BY / HAVING]: Salas com mais de 400 horas reservadas ativas e taxa de cancelamento superior a 15%'
\echo '============================================================================'
SELECT
    s.codigo                                                             AS sala_codigo,
    s.nome                                                               AS sala_nome,
    COUNT(r.id)                                                          AS total_solicitacoes,
    COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')                        AS reservas_ativas,
    COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')                    AS reservas_canceladas,
    ROUND(
        SUM(EXTRACT(EPOCH FROM (upper(r.periodo) - lower(r.periodo))) / 3600.0)
        FILTER (WHERE r.status = 'ATIVA')::NUMERIC,
        1
    )                                                                    AS horas_ativas_totais,
    ROUND(
        (COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')::NUMERIC /
         NULLIF(COUNT(r.id), 0)) * 100.0,
        2
    )                                                                    AS taxa_cancelamento_pct
FROM sala s
JOIN reserva r ON r.sala_id = s.id
GROUP BY s.id, s.codigo, s.nome
HAVING SUM(EXTRACT(EPOCH FROM (upper(r.periodo) - lower(r.periodo))) / 3600.0)
       FILTER (WHERE r.status = 'ATIVA') > 400
   AND (COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')::NUMERIC / NULLIF(COUNT(r.id), 0)) > 0.15
ORDER BY horas_ativas_totais DESC
LIMIT 10;

\echo '============================================================================'
\echo 'CONSULTA 3 [SUBCONSULTA]: Salas cuja quantidade de reservas ativas supera a média de reservas ativas de todas as salas do mesmo bloco'
\echo '============================================================================'
SELECT
    s.codigo      AS sala_codigo,
    s.nome        AS sala_nome,
    b.sigla       AS bloco_sigla,
    (
        SELECT COUNT(*)
        FROM reserva r
        WHERE r.sala_id = s.id
          AND r.status = 'ATIVA'
    )             AS reservas_ativas_sala,
    ROUND(
        (
            SELECT AVG(contagem_bloco.qtd)
            FROM (
                SELECT COUNT(r2.id) AS qtd
                FROM sala s2
                LEFT JOIN reserva r2 ON r2.sala_id = s2.id AND r2.status = 'ATIVA'
                WHERE s2.bloco_id = s.bloco_id
                GROUP BY s2.id
            ) AS contagem_bloco
        ),
        2
    )             AS media_bloco
FROM sala s
JOIN bloco b ON b.id = s.bloco_id
WHERE (
    SELECT COUNT(*)
    FROM reserva r
    WHERE r.sala_id = s.id
      AND r.status = 'ATIVA'
) > (
    SELECT AVG(contagem_bloco.qtd)
    FROM (
        SELECT COUNT(r2.id) AS qtd
        FROM sala s2
        LEFT JOIN reserva r2 ON r2.sala_id = s2.id AND r2.status = 'ATIVA'
        WHERE s2.bloco_id = s.bloco_id
        GROUP BY s2.id
    ) AS contagem_bloco
)
ORDER BY reservas_ativas_sala DESC;

\echo '============================================================================'
\echo 'CONSULTA 4 [CTE]: Eficiência de utilização da capacidade das salas (média de participantes vs capacidade máxima da sala)'
\echo '============================================================================'
WITH metricas_ocupacao_sala AS (
    SELECT
        r.sala_id,
        COUNT(*)                           AS qtd_reservas_ativas,
        ROUND(AVG(r.qtd_participantes), 2) AS media_participantes,
        MAX(r.qtd_participantes)           AS pico_participantes
    FROM reserva r
    WHERE r.status = 'ATIVA'
    GROUP BY r.sala_id
)
SELECT
    s.codigo                                                   AS sala_codigo,
    s.tipo                                                     AS tipo_sala,
    s.capacidade                                               AS capacidade_maxima,
    m.qtd_reservas_ativas,
    m.media_participantes,
    m.pico_participantes,
    ROUND((m.media_participantes / s.capacidade) * 100.0, 2)   AS taxa_aproveitamento_assentos_pct
FROM metricas_ocupacao_sala m
JOIN sala s ON s.id = m.sala_id
ORDER BY taxa_aproveitamento_assentos_pct DESC
LIMIT 10;

\echo '============================================================================'
\echo 'CONSULTA 5 [WINDOW FUNCTION]: Ranking das salas mais disputadas dentro de cada Bloco (RANK e participação percentual no bloco)'
\echo '============================================================================'
SELECT
    b.sigla                                                    AS bloco,
    s.codigo                                                   AS sala_codigo,
    s.tipo                                                     AS tipo_sala,
    COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')              AS reservas_ativas,
    RANK() OVER (
        PARTITION BY b.id
        ORDER BY COUNT(r.id) FILTER (WHERE r.status = 'ATIVA') DESC
    )                                                          AS ranking_no_bloco,
    ROUND(
        (
            COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')::NUMERIC /
            NULLIF(SUM(COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')) OVER (PARTITION BY b.id), 0)
        ) * 100.0,
        2
    )                                                          AS share_no_bloco_pct
FROM sala s
JOIN bloco b ON b.id = s.bloco_id
LEFT JOIN reserva r ON r.sala_id = s.id
GROUP BY b.id, b.sigla, s.id, s.codigo, s.tipo
ORDER BY b.sigla ASC, ranking_no_bloco ASC;
