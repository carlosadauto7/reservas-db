-- ============================================================================
-- A3 & A4. TRIGGERS DE AUDITORIA E REGRAS DE NEGÓCIO
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A3. Trigger Function de Auditoria (AFTER INSERT OR UPDATE OR DELETE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_auditoria_reserva()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO log_reserva (
            reserva_id,
            operacao,
            usuario_id,
            db_user,
            dados_antigos,
            dados_novos,
            registrado_em
        ) VALUES (
            NEW.id,
            TG_OP,
            NEW.usuario_id,
            SESSION_USER,
            NULL,
            to_jsonb(NEW),
            CURRENT_TIMESTAMP
        );
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO log_reserva (
            reserva_id,
            operacao,
            usuario_id,
            db_user,
            dados_antigos,
            dados_novos,
            registrado_em
        ) VALUES (
            NEW.id,
            TG_OP,
            NEW.usuario_id,
            SESSION_USER,
            to_jsonb(OLD),
            to_jsonb(NEW),
            CURRENT_TIMESTAMP
        );
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO log_reserva (
            reserva_id,
            operacao,
            usuario_id,
            db_user,
            dados_antigos,
            dados_novos,
            registrado_em
        ) VALUES (
            OLD.id,
            TG_OP,
            OLD.usuario_id,
            SESSION_USER,
            to_jsonb(OLD),
            NULL,
            CURRENT_TIMESTAMP
        );
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_auditoria_reserva
    AFTER INSERT OR UPDATE OR DELETE ON reserva
    FOR EACH ROW
    EXECUTE FUNCTION fn_auditoria_reserva();

-- ----------------------------------------------------------------------------
-- A4. Trigger Function de Regra de Negócio (BEFORE INSERT OR UPDATE)
--   1) Valida se qtd_participantes <= sala.capacidade
--   2) Garante no máximo 3 reservas ATIVAS futuras por usuário,
--      ignorando a própria linha (id <> NEW.id) em caso de UPDATE.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validar_regras_reserva()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacidade      INTEGER;
    v_sala_codigo      VARCHAR(20);
    v_sala_ativa      BOOLEAN;
    v_usuario_ativo   BOOLEAN;
    v_qtd_ativas_fut  INTEGER;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.atualizado_em := CURRENT_TIMESTAMP;
    END IF;

    -- Se a reserva está sendo cancelada (ou já é CANCELADA), não bloqueia por limite/capacidade
    IF NEW.status = 'CANCELADA' THEN
        RETURN NEW;
    END IF;

    -- 1. Verificar capacidade e status da sala
    SELECT s.capacidade, s.codigo, s.ativa
      INTO v_capacidade, v_sala_codigo, v_sala_ativa
      FROM sala s
     WHERE s.id = NEW.sala_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_SALA_INEXISTENTE] A sala informada (ID %) não existe.', NEW.sala_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT v_sala_ativa THEN
        RAISE EXCEPTION '[REGRA_SALA_INATIVA] A sala % (ID %) está inativa para reservas.', v_sala_codigo, NEW.sala_id
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.qtd_participantes > v_capacidade THEN
        RAISE EXCEPTION '[REGRA_CAPACIDADE] Quantidade de participantes (%) excede a capacidade máxima da sala % (% lugares).',
            NEW.qtd_participantes, v_sala_codigo, v_capacidade
            USING ERRCODE = 'P0001';
    END IF;

    -- 2. Verificar se o usuário existe e está ativo
    SELECT u.ativo
      INTO v_usuario_ativo
      FROM usuario u
     WHERE u.id = NEW.usuario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '[ERRO_USUARIO_INEXISTENTE] O usuário informado (ID %) não existe.', NEW.usuario_id
            USING ERRCODE = 'P0002';
    END IF;

    IF NOT v_usuario_ativo THEN
        RAISE EXCEPTION '[REGRA_USUARIO_INATIVO] O usuário (ID %) está inativo e não pode realizar reservas.', NEW.usuario_id
            USING ERRCODE = 'P0001';
    END IF;

    -- 3. Regra principal A4: Máximo de 3 reservas ATIVAS futuras por usuário
    -- Ignora reservas que já terminaram no passado e ignora a própria linha em UPDATE
    IF upper(NEW.periodo) > CURRENT_TIMESTAMP THEN
        SELECT COUNT(*)
          INTO v_qtd_ativas_fut
          FROM reserva r
         WHERE r.usuario_id = NEW.usuario_id
           AND r.status = 'ATIVA'
           AND upper(r.periodo) > CURRENT_TIMESTAMP
           AND (TG_OP = 'INSERT' OR r.id <> NEW.id);

        IF v_qtd_ativas_fut >= 3 THEN
            RAISE EXCEPTION '[REGRA_LIMITE_RESERVAS] Limite atingido: o usuário (ID %) já possui 3 reservas ativas futuras. Cancele uma reserva antes de agendar outra.',
                NEW.usuario_id
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validar_regras_reserva
    BEFORE INSERT OR UPDATE ON reserva
    FOR EACH ROW
    EXECUTE FUNCTION fn_validar_regras_reserva();
