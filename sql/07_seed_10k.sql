-- ============================================================================
-- B7. POVOAMENTO DE 10 MIL RESERVAS
-- ============================================================================
-- Usa generate_series + random() com horários em slots fixos por sala
-- e ON CONFLICT DO NOTHING para que a constraint EXCLUDE (A2) ignore colisões
-- sem travar a carga em massa.
-- Gera reservas variadas: ATIVAS e CANCELADAS, PASSADAS e FUTURAS,
-- mantendo todas as triggers (A3 e A4) ativas!
-- ============================================================================

SET client_min_messages TO WARNING;
SET TIME ZONE 'America/Sao_Paulo';

SELECT setseed(0.42);

-- 1. Expandir catálogo de salas (mais 12 salas = 20 salas ao todo) para comportar a grade
INSERT INTO sala (bloco_id, codigo, nome, tipo, capacidade, andar, ativa)
SELECT
    ((g % 3) + 1),
    'B-' || (100 + g),
    'Sala Multiuso ' || (100 + g),
    (ARRAY['SALA_AULA', 'LABORATORIO', 'SALA_REUNIAO']::tipo_sala[])[(g % 3) + 1],
    30,
    (g % 3) + 1,
    TRUE
FROM generate_series(1, 12) AS g
ON CONFLICT (codigo) DO NOTHING;

-- 2. Expandir base de usuários (mais 400 usuários) para distribuir reservas futuras e passadas
INSERT INTO usuario (matricula, nome, email, tipo, ativo)
SELECT
    'USR-' || lpad(g::TEXT, 4, '0'),
    'Usuário Acadêmico ' || g,
    'usuario' || g || '@academico.universidade.edu.br',
    CASE WHEN g % 10 = 0 THEN 'PROFESSOR'::tipo_usuario
         WHEN g % 25 = 0 THEN 'TECNICO'::tipo_usuario
         ELSE 'ALUNO'::tipo_usuario
    END,
    TRUE
FROM generate_series(1, 400) AS g
ON CONFLICT (matricula) DO NOTHING;

-- 3. Inserir ~10.200 reservas passadas (últimos 320 dias) usando generate_series + random()
--    e ON CONFLICT DO NOTHING (exercitando o EXCLUDE de A2 nas colisões aleatórias)
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes)
SELECT
    sala_sorteada,
    usuario_sorteado,
    tstzrange(
        (dia_sorteado + hora_inicio) AT TIME ZONE 'America/Sao_Paulo',
        (dia_sorteado + hora_inicio + INTERVAL '2 hours') AT TIME ZONE 'America/Sao_Paulo',
        '[)'
    ) AS periodo,
    CASE WHEN random() < 0.82 THEN 'ATIVA'::status_reserva
         ELSE 'CANCELADA'::status_reserva
    END AS status,
    (ARRAY[
        'Aula Regular de Graduação',
        'Monitoria de Banco de Dados',
        ' Prática de Laboratório de Redes',
        'Reunião de Iniciação Científica',
        'Grupo de Estudos de Algoritmos',
        'Defesa de TCC / Seminário',
        'Oficina de Programação Python/SQL'
    ])[floor(random() * 7 + 1)::INT] || ' #' || serie_id AS finalidade,
    floor(random() * 10 + 2)::INT AS qtd_participantes
FROM (
    SELECT
        g AS serie_id,
        floor(random() * 20 + 1)::INT AS sala_sorteada,
        floor(random() * 400 + 1)::INT AS usuario_sorteado,
        (CURRENT_DATE - floor(random() * 320 + 1)::INT) AS dia_sorteado,
        (ARRAY[
            TIME '08:00',
            TIME '10:00',
            TIME '12:00',
            TIME '14:00',
            TIME '16:00',
            TIME '18:00',
            TIME '20:00'
        ])[floor(random() * 7 + 1)::INT] AS hora_inicio
    FROM generate_series(1, 16500) AS g
) AS candidatos
ON CONFLICT DO NOTHING;

-- 4. Complemento determinístico em grade caso o sorteio com colisões fique abaixo de 10.100
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes)
SELECT
    ((g - 1) % 20) + 1 AS sala_id,
    ((g - 1) % 350) + 20 AS usuario_id,
    tstzrange(
        ((CURRENT_DATE - 330 - ((g - 1) / 140)) + (ARRAY[
            TIME '08:00', TIME '10:00', TIME '12:00', TIME '14:00',
            TIME '16:00', TIME '18:00', TIME '20:00'
        ])[(((g - 1) / 20) % 7) + 1]) AT TIME ZONE 'America/Sao_Paulo',
        ((CURRENT_DATE - 330 - ((g - 1) / 140)) + (ARRAY[
            TIME '08:00', TIME '10:00', TIME '12:00', TIME '14:00',
            TIME '16:00', TIME '18:00', TIME '20:00'
        ])[(((g - 1) / 20) % 7) + 1] + INTERVAL '2 hours') AT TIME ZONE 'America/Sao_Paulo',
        '[)'
    ) AS periodo,
    CASE WHEN g % 5 = 0 THEN 'CANCELADA'::status_reserva ELSE 'ATIVA'::status_reserva END,
    'Sessão Acadêmica Histórica #' || g,
    8
FROM generate_series(1, 3500) AS g
ON CONFLICT DO NOTHING;

-- 5. Inserir ~350 reservas FUTURAS (próximos 25 dias), respeitando <= 2 ativas futuras por usuário
--    (mantendo a Trigger A4 de limite de 3 reservas ativas futuras 100% respeitada)
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes)
SELECT
    ((g % 19) + 2) AS sala_id,
    (g + 15)       AS usuario_id, -- Cada g usa um usuario_id distinto (16..365) -> máx 1 futura por usuário
    tstzrange(
        ((CURRENT_DATE + ((g % 25) + 1)) + (ARRAY[
            TIME '08:00', TIME '10:00', TIME '12:00', TIME '14:00',
            TIME '16:00', TIME '18:00', TIME '20:00'
        ])[(g % 7) + 1]) AT TIME ZONE 'America/Sao_Paulo',
        ((CURRENT_DATE + ((g % 25) + 1)) + (ARRAY[
            TIME '08:00', TIME '10:00', TIME '12:00', TIME '14:00',
            TIME '16:00', TIME '18:00', TIME '20:00'
        ])[(g % 7) + 1] + INTERVAL '2 hours') AT TIME ZONE 'America/Sao_Paulo',
        '[)'
    ) AS periodo,
    CASE WHEN g % 6 = 0 THEN 'CANCELADA'::status_reserva ELSE 'ATIVA'::status_reserva END,
    'Atividade Futura Agendada #' || g,
    10
FROM generate_series(1, 350) AS g
ON CONFLICT DO NOTHING;

-- Atualizar estatísticas do otimizador e a Materialized View
ANALYZE reserva;
ANALYZE log_reserva;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ocupacao_mensal;
