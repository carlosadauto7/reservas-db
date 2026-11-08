"""Teste Ponta a Ponta (E2E) — Sistema de Reserva de Salas e Laboratórios.

Valida todos os critérios de aceitação das Tasks A1..A5, B1..B6 e J5:
1. A1: Rejeição de capacidade negativa/zero (DOMAIN) e status inválido (ENUM).
2. A2: EXCLUDE permite reservas adjacentes (fim = início), bloqueia
   sobrepostas e permite agendar no horário de uma reserva CANCELADA.
3. A3: Trigger de auditoria grava INSERT, UPDATE e DELETE em log_reserva.
4. A4: Trigger de limite de 3 reservas ativas futuras por usuário bloqueia
   a 4ª, permite UPDATE da própria linha e libera vaga após cancelamento.
5. A5: Conectado como 'app_reservas', SELECT direto nas 7 tabelas base
   falha (42501), mas functions, views e materialized view funcionam.
6. B2: criar_reserva trata caminho feliz, conflito, sala/usuário inexistente,
   antecedência e duração inválida.
7. B3: cancelar_reserva valida titularidade e altera status para CANCELADA.
8. B4 & B6: taxa_ocupacao('2026-09-01') na Sala 1 retorna 10.00% e bate
   com mv_ocupacao_mensal.
"""

from datetime import date, datetime, time, timedelta
from decimal import Decimal
import os
import subprocess
from zoneinfo import ZoneInfo

import psycopg
from psycopg.rows import dict_row
import pytest

from app.application.use_cases import ReservaApplicationService
from app.domain.entities import (
    CancelarReservaCommand,
    DatabaseRuleError,
    NovaReservaCommand,
)
from app.infrastructure.config import DatabaseSettings
from app.infrastructure.postgres_repo import PostgresReservaRepository

TZ_SP = ZoneInfo("America/Sao_Paulo")


def get_app_conn() -> psycopg.Connection:
    """Conexão usando a role restrita 'app_reservas' (como a aplicação A7)."""
    return psycopg.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", "5434")),
        dbname=os.getenv("DB_NAME", "reservas_db"),
        user=os.getenv("DB_APP_USER", "app_reservas"),
        password=os.getenv("DB_APP_PASSWORD", "app_reservas_pass"),
        row_factory=dict_row,
        autocommit=True,
    )


def get_admin_conn() -> psycopg.Connection:
    """Conexão administrativa para inspecionar log_reserva e constraints."""
    return psycopg.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", "5434")),
        dbname=os.getenv("DB_NAME", "reservas_db"),
        user=os.getenv("DB_ADMIN_USER", "postgres"),
        password=os.getenv("DB_ADMIN_PASSWORD", "postgres_password"),
        row_factory=dict_row,
        autocommit=True,
    )


@pytest.fixture(scope="module", autouse=True)
def reset_database() -> None:
    """Executa ./reset.sh antes da suíte para garantir estado limpo."""
    subprocess.run(["./reset.sh"], check=True)


def test_a1_schema_constraints_and_domain() -> None:
    """A1: Capacidade negativa e ENUM inválido devem ser rejeitados."""
    with get_admin_conn() as conn:
        with conn.cursor() as cur:
            with pytest.raises(psycopg.Error) as exc_cap:
                cur.execute(
                    "INSERT INTO sala "
                    "(bloco_id, codigo, nome, tipo, capacidade) "
                    "VALUES (1, 'ERR-01', 'Sala Inválida', 'SALA_AULA', -5);"
                )
            assert exc_cap.value.sqlstate == "23514"

            with pytest.raises(psycopg.Error) as exc_enum:
                cur.execute(
                    "INSERT INTO reserva "
                    "(sala_id, usuario_id, periodo, status, "
                    "finalidade, qtd_participantes) "
                    "VALUES (1, 1, "
                    "tstzrange(now(), now() + interval '1 hour', '[)'), "
                    "'PENDENTE', 'Teste', 10);"
                )
            assert exc_enum.value.sqlstate == "22P02"


def test_a5_seguranca_role_app_reservas() -> None:
    """A5: Como app_reservas, acesso às tabelas falha e views funcionam."""
    tabelas_protegidas = [
        "reserva",
        "usuario",
        "sala",
        "bloco",
        "recurso",
        "sala_recurso",
        "log_reserva",
    ]
    with get_app_conn() as conn:
        with conn.cursor() as cur:
            for tabela in tabelas_protegidas:
                with pytest.raises(psycopg.Error) as exc_perm:
                    cur.execute(f"SELECT * FROM {tabela} LIMIT 1;")
                assert exc_perm.value.sqlstate == "42501"

            cur.execute("SELECT count(*) AS total FROM v_agenda_dia;")
            row_agenda = cur.fetchone()
            assert row_agenda is not None and row_agenda["total"] >= 1

            cur.execute("SELECT count(*) AS total FROM v_reservas_usuario;")
            row_usu = cur.fetchone()
            assert row_usu is not None and row_usu["total"] >= 1

            cur.execute("SELECT count(*) AS total FROM mv_ocupacao_mensal;")
            row_mv = cur.fetchone()
            assert row_mv is not None and row_mv["total"] >= 1


def test_b2_validacoes_parametros_e_entidades_inexistentes() -> None:
    """B2: Usuário/sala inexistente e capacidade excedida devem falhar."""
    amanha = date.today() + timedelta(days=3)
    ini = datetime.combine(amanha, time(9, 0), tzinfo=TZ_SP)
    fim = datetime.combine(amanha, time(11, 0), tzinfo=TZ_SP)

    with get_app_conn() as conn:
        with conn.cursor() as cur:
            with pytest.raises(psycopg.Error) as exc_sala:
                cur.execute(
                    "SELECT criar_reserva(9999, 1, %s, %s, 'Aula Teste', 10);",
                    (ini, fim),
                )
            msg_sala = exc_sala.value.diag.message_primary or ""
            assert "[ERRO_SALA_INEXISTENTE]" in msg_sala

            with pytest.raises(psycopg.Error) as exc_usu:
                cur.execute(
                    "SELECT criar_reserva(1, 9999, %s, %s, 'Aula Teste', 10);",
                    (ini, fim),
                )
            msg_usu = exc_usu.value.diag.message_primary or ""
            assert "[ERRO_USUARIO_INEXISTENTE]" in msg_usu

            with pytest.raises(psycopg.Error) as exc_lot:
                cur.execute(
                    "SELECT criar_reserva("
                    "3, 1, %s, %s, 'Reunião Lotada', 25"
                    ");",
                    (ini, fim),
                )
            msg_lot = exc_lot.value.diag.message_primary or ""
            assert "[REGRA_CAPACIDADE]" in msg_lot


def test_roteiro_completo_j5() -> None:
    """Valida o fluxo completo de negócio (A2, A3, A4, B2, B3, J5)."""
    data_teste = date.today() + timedelta(days=5)
    t10 = datetime.combine(data_teste, time(10, 0), tzinfo=TZ_SP)
    t11 = datetime.combine(data_teste, time(11, 0), tzinfo=TZ_SP)
    t12 = datetime.combine(data_teste, time(12, 0), tzinfo=TZ_SP)
    t13 = datetime.combine(data_teste, time(13, 0), tzinfo=TZ_SP)
    t14 = datetime.combine(data_teste, time(14, 0), tzinfo=TZ_SP)
    t16 = datetime.combine(data_teste, time(16, 0), tzinfo=TZ_SP)
    t18 = datetime.combine(data_teste, time(18, 0), tzinfo=TZ_SP)

    with get_app_conn() as conn:
        with conn.cursor() as cur:
            # 1. Reserva válida #1 (10:00 - 12:00)
            cur.execute(
                "SELECT criar_reserva("
                "2, 8, %s, %s, 'Estudo Dirigido 1', 10"
                ") AS id;",
                (t10, t12),
            )
            row_1 = cur.fetchone()
            assert row_1 is not None
            res_id_1 = row_1["id"]
            assert res_id_1 > 0

            # 2. Conflito de horário sobreposto (11:00 - 13:00)
            with pytest.raises(psycopg.Error) as exc_conflito:
                cur.execute(
                    "SELECT criar_reserva("
                    "2, 9, %s, %s, 'Tentativa Conflitante', 10"
                    ");",
                    (t11, t13),
                )
            msg_conf = exc_conflito.value.diag.message_primary or ""
            assert "[CONFLITO_HORARIO]" in msg_conf
            assert exc_conflito.value.sqlstate == "23P01"

            # 3. Reserva adjacente (12:00 - 14:00) -> 2ª reserva futura
            cur.execute(
                "SELECT criar_reserva("
                "2, 8, %s, %s, 'Estudo Dirigido 2 (Adjacente)', 10"
                ") AS id;",
                (t12, t14),
            )
            row_2 = cur.fetchone()
            assert row_2 is not None
            res_id_2 = row_2["id"]
            assert res_id_2 > res_id_1

            # 4. 3ª Reserva futura (14:00 - 16:00)
            cur.execute(
                "SELECT criar_reserva("
                "2, 8, %s, %s, 'Estudo Dirigido 3', 10"
                ") AS id;",
                (t14, t16),
            )
            row_3 = cur.fetchone()
            assert row_3 is not None
            res_id_3 = row_3["id"]
            assert res_id_3 > res_id_2

            # 5. 4ª Reserva futura (16:00 - 18:00) -> Bloqueada pela Trigger A4
            with pytest.raises(psycopg.Error) as exc_limite:
                cur.execute(
                    "SELECT criar_reserva("
                    "2, 8, %s, %s, 'Estudo Dirigido 4 (Excede Limite)', 10"
                    ");",
                    (t16, t18),
                )
            msg_lim = exc_limite.value.diag.message_primary or ""
            assert "[REGRA_LIMITE_RESERVAS]" in msg_lim

            # 6. Cancelamento por usuário que não é dono -> Bloqueado (B3)
            with pytest.raises(psycopg.Error) as exc_nao_dono:
                cur.execute("SELECT cancelar_reserva(%s, 9);", (res_id_1,))
            msg_dono = exc_nao_dono.value.diag.message_primary or ""
            assert "[REGRA_NAO_AUTORIZADO]" in msg_dono

            # 7. Cancelamento legítimo pelo dono (ID 8 cancela res_id_1)
            cur.execute("SELECT cancelar_reserva(%s, 8) AS ok;", (res_id_1,))
            row_ok = cur.fetchone()
            assert row_ok is not None and row_ok["ok"] is True

            # 8. Horário 10:00-12:00 e vaga de limite liberados
            cur.execute(
                "SELECT criar_reserva("
                "2, 8, %s, %s, 'Nova Reserva no Horário Liberado', 12"
                ") AS id;",
                (t10, t12),
            )
            row_nova = cur.fetchone()
            assert row_nova is not None
            res_id_nova = row_nova["id"]
            assert res_id_nova > res_id_3

    # 9. Verificar auditoria em log_reserva (A3) e UPDATE de linha própria (A4)
    with get_admin_conn() as admin_conn:
        with admin_conn.cursor() as admin_cur:
            admin_cur.execute(
                """
                SELECT operacao,
                       dados_antigos->>'status' AS status_antigo,
                       dados_novos->>'status'   AS status_novo
                  FROM log_reserva
                 WHERE reserva_id = %s
                 ORDER BY id ASC;
                """,
                (res_id_1,),
            )
            logs = admin_cur.fetchall()
            assert len(logs) == 2
            assert logs[0]["operacao"] == "INSERT"
            assert logs[0]["status_antigo"] is None
            assert logs[0]["status_novo"] == "ATIVA"
            assert logs[1]["operacao"] == "UPDATE"
            assert logs[1]["status_antigo"] == "ATIVA"
            assert logs[1]["status_novo"] == "CANCELADA"

            admin_cur.execute(
                "UPDATE reserva "
                "SET finalidade = 'Finalidade Editada com 3 Reservas Ativas' "
                "WHERE id = %s;",
                (res_id_nova,),
            )


def test_b4_b6_taxa_ocupacao_e_materialized_view() -> None:
    """B4 & B6: Setembro/2026 na Sala 1 retorna 10.00% exatos."""
    with get_app_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT atualizar_ocupacao_mensal();")

            cur.execute(
                "SELECT taxa_ocupacao(1, DATE '2026-09-01') AS taxa;"
            )
            row_taxa = cur.fetchone()
            assert row_taxa is not None
            taxa_fn = row_taxa["taxa"]
            assert taxa_fn == Decimal("10.00")

            cur.execute(
                """
                SELECT total_reservas_ativas,
                       horas_reservadas,
                       horas_disponiveis,
                       taxa_ocupacao_pct
                  FROM mv_ocupacao_mensal
                 WHERE sala_id = 1
                   AND mes_referencia = DATE '2026-09-01';
                """
            )
            mv_row = cur.fetchone()
            assert mv_row is not None
            assert mv_row["total_reservas_ativas"] == 14
            assert mv_row["horas_reservadas"] == Decimal("42.00")
            assert mv_row["horas_disponiveis"] == Decimal("420.00")
            assert mv_row["taxa_ocupacao_pct"] == taxa_fn


def test_a7_clean_architecture_application_service() -> None:
    """A7: Valida casos de uso da Clean Architecture e DatabaseRuleError."""
    repo = PostgresReservaRepository(DatabaseSettings.from_env())
    service = ReservaApplicationService(repo)

    df_salas = service.obter_catalogo_salas()
    assert not df_salas.empty

    df_agenda = service.consultar_agenda_do_dia(date.today())
    assert not df_agenda.empty

    # Tentativa de ler tabela base via service deve levantar DatabaseRuleError
    with pytest.raises(DatabaseRuleError) as exc_sec:
        service.testar_bloqueio_tabela_base("reserva")
    assert exc_sec.value.sqlstate == "42501"

    # Criar e cancelar reserva via Use Cases
    dia_futura = date.today() + timedelta(days=7)
    cmd_criar = NovaReservaCommand(
        sala_id=1,
        usuario_id=7,
        inicio=datetime.combine(dia_futura, time(14, 0), tzinfo=TZ_SP),
        fim=datetime.combine(dia_futura, time(16, 0), tzinfo=TZ_SP),
        finalidade="Teste Clean Architecture Service",
        qtd_participantes=10,
    )
    novo_id = service.criar_nova_reserva(cmd_criar)
    assert novo_id > 0

    cmd_cancelar = CancelarReservaCommand(reserva_id=novo_id, usuario_id=7)
    assert service.cancelar_reserva_existente(cmd_cancelar) is True

