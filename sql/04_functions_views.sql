-- ============================================================================
-- B2, B3, B4, B5, B6. FUNCTIONS, VIEWS E MATERIALIZED VIEW
-- ============================================================================

SET client_min_messages TO WARNING;
SET TIME ZONE 'America/Sao_Paulo';

-- ----------------------------------------------------------------------------
-- B2. Function: criar_reserva
--   Valida parâmetros, insere dentro da transação e captura exclusion_violation
--   com EXCEPTION WHEN, convertendo em mensagem de negócio clara.
--   Configurada com SECURITY DEFINER + SET search_path (A5).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION criar_reserva(
    p_sala_id           INTEGER,
    p_usuario_id        INTEGER,
    p_inicio            TIMESTAMPTZ,
    p_fim               TIMESTAMPTZ,
    p_finalidade        VARCHAR,
    p_qtd_participantes INTEGER DEFAULT 1
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reserva_id   BIGINT;
    v_sala_codigo  VARCHAR(20);
    v_sala_ativa   BOOLEAN;
    v_usu_ativo    BOOLEAN;
    v_duracao      INTERVAL;
BEGIN
    -- 1. Validação de parâmetros nulos ou vazios
    IF p_sala_id IS NULL OR p_usuario_id IS NULL OR p_inicio IS NULL OR p_fim IS NULL THEN
        RAISE EXCEPTION '[PARAMETRO_OBRIGATORIO] Sala, usuário, horário de início e horário de término são obrigatórios.'
            USING ERRCODE = '22004';
    END IF;

    IF p_finalidade IS NULL OR length(btrim(p_finalidade)) < 3 THEN
        RAISE EXCEPTION '[REGRA_FINALIDADE] A finalidade da reserva deve conter pelo menos 3 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    IF p_qtd_participantes IS NULL OR p_qtd_participantes <= 0 THEN
        RAISE EXCEPTION '[REGRA_PARTICIPANTES] A quantidade de participantes deve ser maior que zero.'
            USING ERRCODE = '22023';
    END IF;

    -- 2. Verificar existência da sala
    SELECT s.codigo, s.ativa
      INTO v_sala_codigo, v_sala_ativa
      FROM sala s
     WHERE s.id = p_sala_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_SALA_INEXISTENTE] A sala informada (ID %) não existe no cadastro.', p_sala_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT v_sala_ativa THEN
        RAISE EXCEPTION '[REGRA_SALA_INATIVA] A sala % está temporariamente inativa para reservas.', v_sala_codigo
            USING ERRCODE = 'P0001';
    END IF;

    -- 3. Verificar existência do usuário
    SELECT u.ativo
      INTO v_usu_ativo
      FROM usuario u
     WHERE u.id = p_usuario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_USUARIO_INEXISTENTE] O usuário informado (ID %) não existe no cadastro.', p_usuario_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT v_usu_ativo THEN
        RAISE EXCEPTION '[REGRA_USUARIO_INATIVO] O usuário (ID %) está inativo e não pode realizar reservas.', p_usuario_id
            USING ERRCODE = 'P0001';
    END IF;

    -- 4. Validar ordem cronológica e duração (30 min a 4 horas)
    IF p_fim <= p_inicio THEN
        RAISE EXCEPTION '[REGRA_PERIODO_INVALIDO] O horário de término (%) deve ser posterior ao horário de início (%).',
            to_char(p_fim AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
            to_char(p_inicio AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
            USING ERRCODE = '22007';
    END IF;

    v_duracao := p_fim - p_inicio;
    IF v_duracao < INTERVAL '30 minutes' OR v_duracao > INTERVAL '4 hours' THEN
        RAISE EXCEPTION '[REGRA_DURACAO] A duração da reserva deve ser de no mínimo 30 minutos e no máximo 4 horas (solicitado: %).',
            v_duracao
            USING ERRCODE = 'P0001';
    END IF;

    -- 5. Validar antecedência (não permitir reservar no passado nem além de 30 dias)
    IF p_inicio < (CURRENT_TIMESTAMP - INTERVAL '5 minutes') THEN
        RAISE EXCEPTION '[REGRA_ANTECEDENCIA] Não é permitido criar reservas no passado (início informado: %).',
            to_char(p_inicio AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
            USING ERRCODE = 'P0001';
    END IF;

    IF p_inicio > (CURRENT_TIMESTAMP + INTERVAL '30 days') THEN
        RAISE EXCEPTION '[REGRA_ANTECEDENCIA] A antecedência máxima para reservas é de 30 dias.'
            USING ERRCODE = 'P0001';
    END IF;

    -- 6. Inserção protegida com captura de exclusion_violation (A2)
    BEGIN
        INSERT INTO reserva (
            sala_id,
            usuario_id,
            periodo,
            status,
            finalidade,
            qtd_participantes
        ) VALUES (
            p_sala_id,
            p_usuario_id,
            tstzrange(p_inicio, p_fim, '[)'),
            'ATIVA',
            btrim(p_finalidade),
            p_qtd_participantes
        )
        RETURNING id INTO v_reserva_id;

    EXCEPTION
        WHEN exclusion_violation THEN
            RAISE EXCEPTION '[CONFLITO_HORARIO] Conflito de agenda: a sala % já está reservada em parte ou todo o período de % às %.',
                v_sala_codigo,
                to_char(p_inicio AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
                to_char(p_fim AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
                USING ERRCODE = '23P01';
    END;

    RETURN v_reserva_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- B3. Function: cancelar_reserva
--   Muda o status para CANCELADA (sem apagar), validando que a reserva existe,
--   está ativa, e que o usuário solicitante é o dono (ou ADMIN).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancelar_reserva(
    p_reserva_id BIGINT,
    p_usuario_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_dono_id      INTEGER;
    v_status_atual status_reserva;
    v_tipo_usu     tipo_usuario;
BEGIN
    IF p_reserva_id IS NULL OR p_usuario_id IS NULL THEN
        RAISE EXCEPTION '[PARAMETRO_OBRIGATORIO] O ID da reserva e o ID do usuário são obrigatórios para o cancelamento.'
            USING ERRCODE = '22004';
    END IF;

    -- Verificar existência do usuário solicitante
    SELECT u.tipo
      INTO v_tipo_usu
      FROM usuario u
     WHERE u.id = p_usuario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_USUARIO_INEXISTENTE] O usuário solicitante (ID %) não existe.', p_usuario_id
            USING ERRCODE = 'P0002';
    END IF;

    -- Buscar reserva bloqueando a linha para atualização segura (FOR UPDATE)
    SELECT r.usuario_id, r.status
      INTO v_dono_id, v_status_atual
      FROM reserva r
     WHERE r.id = p_reserva_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_RESERVA_INEXISTENTE] A reserva informada (ID %) não foi encontrada.', p_reserva_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_status_atual = 'CANCELADA' THEN
        RAISE EXCEPTION '[REGRA_RESERVA_JA_CANCELADA] A reserva (ID %) já se encontra CANCELADA.', p_reserva_id
            USING ERRCODE = 'P0001';
    END IF;

    -- Validar titularidade (apenas o próprio dono ou um ADMIN pode cancelar)
    IF v_dono_id <> p_usuario_id AND v_tipo_usu <> 'ADMIN' THEN
        RAISE EXCEPTION '[REGRA_NAO_AUTORIZADO] Operação negada: o usuário (ID %) não é o titular da reserva (ID %).',
            p_usuario_id, p_reserva_id
            USING ERRCODE = '42501';
    END IF;

    UPDATE reserva
       SET status = 'CANCELADA',
           atualizado_em = CURRENT_TIMESTAMP
     WHERE id = p_reserva_id;

    RETURN TRUE;
END;
$$;

-- ----------------------------------------------------------------------------
-- B4. Function: taxa_ocupacao(p_sala_id, p_mes)
--   Calcula (horas reservadas ativas no mês ÷ horas disponíveis no mês) * 100.
--   Janela disponível padrão: 14h/dia (08h às 22h) × número de dias no mês.
--   Usa o operador de interseção de ranges (*) para truncar reservas que
--   eventualmente toquem a borda do mês.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION taxa_ocupacao(
    p_sala_id INTEGER,
    p_mes     DATE
)
RETURNS NUMERIC(5,2)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_inicio_mes       TIMESTAMPTZ;
    v_fim_mes          TIMESTAMPTZ;
    v_range_mes        TSTZRANGE;
    v_dias_no_mes      NUMERIC;
    v_horas_disp       NUMERIC;
    v_horas_reservadas NUMERIC;
    v_sala_existe      BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM sala WHERE id = p_sala_id)
      INTO v_sala_existe;

    IF NOT v_sala_existe THEN
        RAISE EXCEPTION '[ERRO_SALA_INEXISTENTE] A sala informada (ID %) não existe.', p_sala_id
            USING ERRCODE = 'P0002';
    END IF;

    v_inicio_mes  := date_trunc('month', p_mes AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
    v_fim_mes     := (date_trunc('month', p_mes AT TIME ZONE 'America/Sao_Paulo') + INTERVAL '1 month') AT TIME ZONE 'America/Sao_Paulo';
    v_range_mes   := tstzrange(v_inicio_mes, v_fim_mes, '[)');

    v_dias_no_mes := EXTRACT(DAY FROM (date_trunc('month', p_mes) + INTERVAL '1 month - 1 day'));
    v_horas_disp  := v_dias_no_mes * 14.0; -- 14h diárias (08:00 às 22:00)

    SELECT COALESCE(
               SUM(
                   EXTRACT(EPOCH FROM (upper(r.periodo * v_range_mes) - lower(r.periodo * v_range_mes))) / 3600.0
               ),
               0.0
           )
      INTO v_horas_reservadas
      FROM reserva r
     WHERE r.sala_id = p_sala_id
       AND r.status = 'ATIVA'
       AND r.periodo && v_range_mes;

    RETURN ROUND((v_horas_reservadas / v_horas_disp) * 100.0, 2);
END;
$$;

-- ----------------------------------------------------------------------------
-- B5. Views: v_agenda_dia e v_reservas_usuario (+ views auxiliares de catálogo)
-- ----------------------------------------------------------------------------

-- View 1 (B5): Agenda do dia ordenada por horário e sala
CREATE OR REPLACE VIEW v_agenda_dia AS
SELECT
    r.id                                                                 AS reserva_id,
    s.id                                                                 AS sala_id,
    s.codigo                                                             AS sala_codigo,
    s.nome                                                               AS sala_nome,
    s.tipo                                                               AS tipo_sala,
    b.sigla                                                              AS bloco_sigla,
    (lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE            AS data_reserva,
    to_char(lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') AS hora_inicio,
    to_char(upper(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') AS hora_fim,
    lower(r.periodo)                                                     AS inicio_em,
    upper(r.periodo)                                                     AS fim_em,
    u.id                                                                 AS usuario_id,
    u.nome                                                               AS usuario_nome,
    u.tipo                                                               AS tipo_usuario,
    r.finalidade                                                         AS finalidade,
    r.qtd_participantes                                                  AS qtd_participantes,
    s.capacidade                                                         AS capacidade_sala,
    r.status                                                             AS status
FROM reserva r
JOIN sala s    ON s.id = r.sala_id
JOIN bloco b   ON b.id = s.bloco_id
JOIN usuario u ON u.id = r.usuario_id
WHERE r.status = 'ATIVA'
ORDER BY lower(r.periodo) ASC, s.codigo ASC;

-- View 2 (B5): Reservas ativas futuras por usuário
CREATE OR REPLACE VIEW v_reservas_usuario AS
SELECT
    r.id                                                                 AS reserva_id,
    u.id                                                                 AS usuario_id,
    u.matricula                                                          AS matricula,
    u.nome                                                               AS usuario_nome,
    u.tipo                                                               AS tipo_usuario,
    s.id                                                                 AS sala_id,
    s.codigo                                                             AS sala_codigo,
    s.nome                                                               AS sala_nome,
    b.sigla                                                              AS bloco_sigla,
    (lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE            AS data_reserva,
    to_char(lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') AS hora_inicio,
    to_char(upper(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') AS hora_fim,
    lower(r.periodo)                                                     AS inicio_em,
    upper(r.periodo)                                                     AS fim_em,
    r.finalidade                                                         AS finalidade,
    r.qtd_participantes                                                  AS qtd_participantes,
    r.status                                                             AS status
FROM reserva r
JOIN usuario u ON u.id = r.usuario_id
JOIN sala s    ON s.id = r.sala_id
JOIN bloco b   ON b.id = s.bloco_id
WHERE r.status = 'ATIVA'
  AND upper(r.periodo) > CURRENT_TIMESTAMP
ORDER BY lower(r.periodo) ASC, s.codigo ASC;

-- Views auxiliares de catálogo (para a aplicação A7 consultar sem acesso às tabelas base)
CREATE OR REPLACE VIEW v_catalogo_salas AS
SELECT
    s.id          AS sala_id,
    s.codigo      AS codigo,
    s.nome        AS nome,
    s.tipo        AS tipo,
    s.capacidade  AS capacidade,
    s.andar       AS andar,
    b.sigla       AS bloco_sigla,
    b.nome        AS bloco_nome,
    COALESCE(
        string_agg(rec.nome || ' (' || sr.quantidade || 'x)', ', ' ORDER BY rec.nome),
        'Sem recursos extras'
    )             AS recursos_instalados
FROM sala s
JOIN bloco b ON b.id = s.bloco_id
LEFT JOIN sala_recurso sr ON sr.sala_id = s.id
LEFT JOIN recurso rec     ON rec.id = sr.recurso_id
WHERE s.ativa = TRUE
GROUP BY s.id, s.codigo, s.nome, s.tipo, s.capacidade, s.andar, b.sigla, b.nome
ORDER BY s.codigo;

CREATE OR REPLACE VIEW v_catalogo_usuarios AS
SELECT
    u.id        AS usuario_id,
    u.matricula AS matricula,
    u.nome      AS nome,
    u.email     AS email,
    u.tipo      AS tipo
FROM usuario u
WHERE u.ativo = TRUE
ORDER BY u.nome;

-- ----------------------------------------------------------------------------
-- B6. Materialized View: mv_ocupacao_mensal
--   Inclui índice único (sala_id, mes_referencia) para permitir
--   REFRESH MATERIALIZED VIEW CONCURRENTLY e bate exatamente com taxa_ocupacao.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_ocupacao_mensal AS
WITH meses AS (
    SELECT DISTINCT
        date_trunc('month', lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE AS mes_referencia
    FROM reserva r
    UNION
    SELECT date_trunc('month', CURRENT_DATE)::DATE AS mes_referencia
)
SELECT
    s.id                                                     AS sala_id,
    s.codigo                                                 AS sala_codigo,
    s.nome                                                   AS sala_nome,
    s.tipo                                                   AS tipo_sala,
    b.sigla                                                  AS bloco_sigla,
    m.mes_referencia                                         AS mes_referencia,
    to_char(m.mes_referencia, 'YYYY-MM')                     AS ano_mes,
    COUNT(r.id) FILTER (
        WHERE r.status = 'ATIVA'
          AND r.periodo && tstzrange(
              (m.mes_referencia::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
              ((m.mes_referencia + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
              '[)'
          )
    )                                                        AS total_reservas_ativas,
    ROUND(
        COALESCE(
            SUM(
                EXTRACT(EPOCH FROM (
                    upper(r.periodo * tstzrange(
                        (m.mes_referencia::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                        ((m.mes_referencia + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                        '[)'
                    )) -
                    lower(r.periodo * tstzrange(
                        (m.mes_referencia::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                        ((m.mes_referencia + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                        '[)'
                    ))
                )) / 3600.0
            ) FILTER (
                WHERE r.status = 'ATIVA'
                  AND r.periodo && tstzrange(
                      (m.mes_referencia::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                      ((m.mes_referencia + INTERVAL '1 month')::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo'),
                      '[)'
                  )
            ),
            0.0
        )::NUMERIC,
        2
    )                                                        AS horas_reservadas,
    (EXTRACT(DAY FROM (m.mes_referencia + INTERVAL '1 month - 1 day')) * 14.0)::NUMERIC(6,2) AS horas_disponiveis,
    taxa_ocupacao(s.id, m.mes_referencia)                    AS taxa_ocupacao_pct,
    CURRENT_TIMESTAMP                                        AS atualizado_em
FROM sala s
JOIN bloco b ON b.id = s.bloco_id
CROSS JOIN meses m
LEFT JOIN reserva r ON r.sala_id = s.id
GROUP BY s.id, s.codigo, s.nome, s.tipo, b.sigla, m.mes_referencia
WITH DATA;

-- Índice ÚNICO obrigatório para permitir REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX uq_mv_ocupacao_mensal_sala_mes
    ON mv_ocupacao_mensal (sala_id, mes_referencia);

-- Function auxiliar SECURITY DEFINER para atualizar a Materialized View concorrentemente
CREATE OR REPLACE FUNCTION atualizar_ocupacao_mensal()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ocupacao_mensal;
END;
$$;
