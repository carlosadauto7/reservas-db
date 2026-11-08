-- ============================================================================
-- A1. SCHEMA BASE — Sistema de Reserva de Salas e Laboratórios
-- ============================================================================
-- Convenções:
--   Nomes em snake_case
--   Constraints nomeadas: pk_*, fk_*, uq_*, ck_*, ex_*
-- ============================================================================

SET client_min_messages TO WARNING;
SET TIME ZONE 'America/Sao_Paulo';

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO PUBLIC;

-- ----------------------------------------------------------------------------
-- 1. TIPOS ENUM E DOMÍNIOS
-- ----------------------------------------------------------------------------

CREATE TYPE status_reserva AS ENUM (
    'ATIVA',
    'CANCELADA'
);

CREATE TYPE tipo_usuario AS ENUM (
    'ALUNO',
    'PROFESSOR',
    'TECNICO',
    'ADMIN'
);

CREATE TYPE tipo_sala AS ENUM (
    'SALA_AULA',
    'LABORATORIO',
    'AUDITORIO',
    'SALA_REUNIAO'
);

-- Domínio para garantir capacidades e quantidades estritamente positivas
CREATE DOMAIN capacidade_positiva AS INTEGER
    CONSTRAINT ck_dominio_capacidade_positiva CHECK (VALUE IS NOT NULL AND VALUE > 0 AND VALUE <= 2000);

-- ----------------------------------------------------------------------------
-- 2. TABELA: bloco (Garante a 3FN separando dados do prédio/bloco da sala)
-- ----------------------------------------------------------------------------
-- Se nome_bloco e localizacao_bloco ficassem dentro de 'sala', haveria
-- dependência transitiva: sala.id -> bloco_sigla -> (nome_bloco, localizacao),
-- violando a 3ª Forma Normal (3FN).
CREATE TABLE bloco (
    id          SERIAL,
    sigla       VARCHAR(10)  NOT NULL,
    nome        VARCHAR(100) NOT NULL,
    localizacao VARCHAR(150) NOT NULL,
    criado_em   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_bloco PRIMARY KEY (id),
    CONSTRAINT uq_bloco_sigla UNIQUE (sigla),
    CONSTRAINT ck_bloco_sigla_nao_vazia CHECK (length(btrim(sigla)) > 0),
    CONSTRAINT ck_bloco_nome_nao_vazio CHECK (length(btrim(nome)) > 0)
);

-- ----------------------------------------------------------------------------
-- 3. TABELA: usuario
-- ----------------------------------------------------------------------------
CREATE TABLE usuario (
    id          SERIAL,
    matricula   VARCHAR(20)  NOT NULL,
    nome        VARCHAR(120) NOT NULL,
    email       VARCHAR(150) NOT NULL,
    tipo        tipo_usuario NOT NULL,
    ativo       BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_em   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_usuario PRIMARY KEY (id),
    CONSTRAINT uq_usuario_matricula UNIQUE (matricula),
    CONSTRAINT uq_usuario_email UNIQUE (email),
    CONSTRAINT ck_usuario_matricula_nao_vazia CHECK (length(btrim(matricula)) >= 3),
    CONSTRAINT ck_usuario_nome_nao_vazio CHECK (length(btrim(nome)) >= 3),
    CONSTRAINT ck_usuario_email_formato CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- ----------------------------------------------------------------------------
-- 4. TABELA: sala
-- ----------------------------------------------------------------------------
-- Justificativa ON DELETE em fk_sala_bloco:
--   RESTRICT: impede a exclusão acidental de um bloco que ainda possui salas
--   cadastradas, exigindo realocação ou remoção consciente antes.
CREATE TABLE sala (
    id          SERIAL,
    bloco_id    INTEGER             NOT NULL,
    codigo      VARCHAR(20)         NOT NULL,
    nome        VARCHAR(120)        NOT NULL,
    tipo        tipo_sala           NOT NULL,
    capacidade  capacidade_positiva NOT NULL,
    andar       INTEGER             NOT NULL DEFAULT 0,
    ativa       BOOLEAN             NOT NULL DEFAULT TRUE,
    criado_em   TIMESTAMPTZ         NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_sala PRIMARY KEY (id),
    CONSTRAINT fk_sala_bloco FOREIGN KEY (bloco_id)
        REFERENCES bloco (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT uq_sala_codigo UNIQUE (codigo),
    CONSTRAINT ck_sala_codigo_nao_vazio CHECK (length(btrim(codigo)) >= 2),
    CONSTRAINT ck_sala_nome_nao_vazio CHECK (length(btrim(nome)) >= 3),
    CONSTRAINT ck_sala_andar_valido CHECK (andar BETWEEN -3 AND 30)
);

-- ----------------------------------------------------------------------------
-- 5. TABELA: recurso
-- ----------------------------------------------------------------------------
CREATE TABLE recurso (
    id          SERIAL,
    nome        VARCHAR(80)  NOT NULL,
    descricao   VARCHAR(250),
    criado_em   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_recurso PRIMARY KEY (id),
    CONSTRAINT uq_recurso_nome UNIQUE (nome),
    CONSTRAINT ck_recurso_nome_nao_vazio CHECK (length(btrim(nome)) >= 2)
);

-- ----------------------------------------------------------------------------
-- 6. TABELA: sala_recurso (Associativa N:N entre sala e recurso)
-- ----------------------------------------------------------------------------
-- Justificativa ON DELETE:
--   fk_sala_recurso_sala -> ON DELETE CASCADE: os vínculos de inventário
--     pertencem intrinsecamente à sala; se uma sala (sem reservas) for removida,
--     sua lista de equipamentos vinculados deve ser apagada junto.
--   fk_sala_recurso_recurso -> ON DELETE RESTRICT: impede apagar do catálogo
--     um tipo de equipamento (ex.: "Projetor 4K") enquanto houver salas que o utilizam.
CREATE TABLE sala_recurso (
    sala_id     INTEGER             NOT NULL,
    recurso_id  INTEGER             NOT NULL,
    quantidade  capacidade_positiva NOT NULL DEFAULT 1,
    observacao  VARCHAR(200),

    CONSTRAINT pk_sala_recurso PRIMARY KEY (sala_id, recurso_id),
    CONSTRAINT fk_sala_recurso_sala FOREIGN KEY (sala_id)
        REFERENCES sala (id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_sala_recurso_recurso FOREIGN KEY (recurso_id)
        REFERENCES recurso (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);

-- ----------------------------------------------------------------------------
-- 7. TABELA: reserva
-- ----------------------------------------------------------------------------
-- Justificativa ON DELETE:
--   fk_reserva_sala -> ON DELETE RESTRICT: preserva o histórico de ocupação e
--     impede que uma sala com reservas registradas seja excluída fisicamente.
--     Para desativar uma sala, utiliza-se a coluna sala.ativa = FALSE.
--   fk_reserva_usuario -> ON DELETE RESTRICT: preserva a rastreabilidade e o
--     histórico de quem reservou cada espaço. Para desligar um usuário,
--     utiliza-se usuario.ativo = FALSE.
CREATE TABLE reserva (
    id                BIGSERIAL,
    sala_id           INTEGER             NOT NULL,
    usuario_id        INTEGER             NOT NULL,
    periodo           TSTZRANGE           NOT NULL,
    status            status_reserva      NOT NULL DEFAULT 'ATIVA',
    finalidade        VARCHAR(250)        NOT NULL,
    qtd_participantes capacidade_positiva NOT NULL DEFAULT 1,
    criado_em         TIMESTAMPTZ         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    atualizado_em     TIMESTAMPTZ         NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_reserva PRIMARY KEY (id),
    CONSTRAINT fk_reserva_sala FOREIGN KEY (sala_id)
        REFERENCES sala (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_reserva_usuario FOREIGN KEY (usuario_id)
        REFERENCES usuario (id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT ck_reserva_periodo_nao_vazio
        CHECK (NOT isempty(periodo) AND lower(periodo) IS NOT NULL AND upper(periodo) IS NOT NULL),
    CONSTRAINT ck_reserva_periodo_semiaberto
        CHECK (lower_inc(periodo) AND NOT upper_inc(periodo)),
    CONSTRAINT ck_reserva_duracao_valida
        CHECK ((upper(periodo) - lower(periodo)) BETWEEN INTERVAL '30 minutes' AND INTERVAL '4 hours'),
    CONSTRAINT ck_reserva_finalidade_nao_vazia
        CHECK (length(btrim(finalidade)) >= 3)
);

-- ----------------------------------------------------------------------------
-- 8. TABELA: log_reserva (Auditoria imutável — A3)
-- ----------------------------------------------------------------------------
-- Justificativa de ausência de FK com CASCADE para reserva:
--   O log de auditoria deve sobreviver mesmo a um eventual DELETE físico na
--   tabela reserva (para justamente auditar a operação DELETE com OLD em JSONB).
CREATE TABLE log_reserva (
    id            BIGSERIAL,
    reserva_id    BIGINT      NOT NULL,
    operacao      VARCHAR(10) NOT NULL,
    usuario_id    INTEGER,
    db_user       VARCHAR(80) NOT NULL DEFAULT SESSION_USER,
    dados_antigos JSONB,
    dados_novos   JSONB,
    registrado_em TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_log_reserva PRIMARY KEY (id),
    CONSTRAINT ck_log_reserva_operacao CHECK (operacao IN ('INSERT', 'UPDATE', 'DELETE'))
);
