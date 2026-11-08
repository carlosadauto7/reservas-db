-- ============================================================================
-- A5. ROLE E PERMISSÕES (Segurança em nível de SGBD)
-- ============================================================================
-- Cria a role 'app_reservas', revoga acesso direto a todas as tabelas e
-- sequências, e concede apenas:
--   - SELECT nas views e materialized view
--   - EXECUTE nas functions de negócio (que rodam como SECURITY DEFINER)
-- ============================================================================

SET client_min_messages TO WARNING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_reservas') THEN
        CREATE ROLE app_reservas WITH LOGIN PASSWORD 'app_reservas_pass';
    ELSE
        ALTER ROLE app_reservas WITH LOGIN PASSWORD 'app_reservas_pass';
    END IF;
END
$$;

-- Permitir conexão ao banco e uso do schema public
GRANT CONNECT ON DATABASE reservas_db TO app_reservas;
GRANT USAGE ON SCHEMA public TO app_reservas;

-- Revogar TODAS as permissões em tabelas e sequências do schema public
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM app_reservas;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM app_reservas;

-- Garantir explicitamente que as 7 tabelas base estão bloqueadas para app_reservas
REVOKE ALL ON TABLE bloco, usuario, sala, recurso, sala_recurso, reserva, log_reserva FROM app_reservas;

-- Conceder SELECT exclusivamente nas Views e Materialized View
GRANT SELECT ON
    v_agenda_dia,
    v_reservas_usuario,
    v_catalogo_salas,
    v_catalogo_usuarios,
    mv_ocupacao_mensal
TO app_reservas;

-- Conceder EXECUTE nas Functions de negócio
GRANT EXECUTE ON FUNCTION criar_reserva(INTEGER, INTEGER, TIMESTAMPTZ, TIMESTAMPTZ, VARCHAR, INTEGER) TO app_reservas;
GRANT EXECUTE ON FUNCTION cancelar_reserva(BIGINT, INTEGER) TO app_reservas;
GRANT EXECUTE ON FUNCTION taxa_ocupacao(INTEGER, DATE) TO app_reservas;
GRANT EXECUTE ON FUNCTION atualizar_ocupacao_mensal() TO app_reservas;
