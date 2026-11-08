"""Adapter concreto PostgreSQL que implementa ReservaRepositoryPort."""

from collections.abc import Sequence
from datetime import date
from typing import Any

import pandas as pd
import psycopg
from psycopg import sql as pgsql
from psycopg.rows import dict_row

from app.domain.entities import (
    CancelarReservaCommand,
    DatabaseRuleError,
    NovaReservaCommand,
)
from app.infrastructure.config import DatabaseSettings


class PostgresReservaRepository:
    """Repositório PostgreSQL conectado com a role restrita 'app_reservas'."""

    def __init__(self, settings: DatabaseSettings) -> None:
        self._settings = settings

    def _connect(self) -> psycopg.Connection:
        """Abre uma conexão configurada com autocommit e dict_row."""
        try:
            return psycopg.connect(
                host=self._settings.host,
                port=self._settings.port,
                dbname=self._settings.dbname,
                user=self._settings.user,
                password=self._settings.password,
                row_factory=dict_row,
                autocommit=True,
            )
        except psycopg.Error as exc:
            raise self._translate_error(exc) from exc

    @staticmethod
    def _translate_error(erro: psycopg.Error) -> DatabaseRuleError:
        """Converte psycopg.Error em DatabaseRuleError sem stack trace."""
        sqlstate = erro.sqlstate or "ERRO"
        if erro.diag and erro.diag.message_primary:
            return DatabaseRuleError(erro.diag.message_primary, sqlstate)
        primeira_linha = str(erro).splitlines()[0]
        return DatabaseRuleError(primeira_linha, sqlstate)

    def _fetch_df(
        self,
        query: str | pgsql.Composed,
        params: Sequence[Any] = (),
    ) -> pd.DataFrame:
        """Executa um SELECT parametrizado e retorna um DataFrame."""
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(query, params)
                    rows = cur.fetchall()
                    return pd.DataFrame(rows)
        except psycopg.Error as exc:
            raise self._translate_error(exc) from exc

    def listar_catalogo_salas(self) -> pd.DataFrame:
        """Retorna o catálogo de salas ativas via v_catalogo_salas."""
        return self._fetch_df(
            "SELECT sala_id, codigo, nome, tipo, capacidade, bloco_sigla "
            "FROM v_catalogo_salas;"
        )

    def listar_catalogo_usuarios(self) -> pd.DataFrame:
        """Retorna os usuários ativos via v_catalogo_usuarios."""
        return self._fetch_df(
            "SELECT usuario_id, matricula, nome, tipo "
            "FROM v_catalogo_usuarios LIMIT 50;"
        )

    def consultar_agenda_dia(
        self,
        data_reserva: date,
        sala_id: int | None = None,
    ) -> pd.DataFrame:
        """Consulta a view v_agenda_dia filtrando por data e sala opcional."""
        sql_base = """
            SELECT reserva_id AS "ID",
                   bloco_sigla AS "Bloco",
                   sala_codigo AS "Sala",
                   sala_nome AS "Nome da Sala",
                   hora_inicio AS "Início",
                   hora_fim AS "Fim",
                   usuario_nome AS "Responsável",
                   tipo_usuario AS "Perfil",
                   finalidade AS "Finalidade",
                   qtd_participantes || '/' || capacidade_sala AS "Lotação"
              FROM v_agenda_dia
             WHERE data_reserva = %s
        """
        if sala_id is None:
            query = sql_base + " ORDER BY hora_inicio, sala_codigo;"
            return self._fetch_df(query, (data_reserva,))

        query = (
            sql_base + " AND sala_id = %s ORDER BY hora_inicio, sala_codigo;"
        )
        return self._fetch_df(query, (data_reserva, sala_id))

    def listar_reservas_ativas_futuras(self) -> pd.DataFrame:
        """Consulta a view v_reservas_usuario."""
        return self._fetch_df(
            """
            SELECT reserva_id AS "ID Reserva",
                   usuario_id AS "ID Usuário",
                   usuario_nome AS "Titular",
                   tipo_usuario AS "Perfil",
                   sala_codigo AS "Sala",
                   data_reserva AS "Data",
                   hora_inicio AS "Início",
                   hora_fim AS "Fim",
                   finalidade AS "Finalidade",
                   qtd_participantes AS "Participantes"
              FROM v_reservas_usuario
             ORDER BY data_reserva, hora_inicio
             LIMIT 100;
            """
        )

    def criar_reserva(self, command: NovaReservaCommand) -> int:
        """Chama a function criar_reserva no PostgreSQL."""
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT criar_reserva("
                        "%s, %s, %s, %s, %s, %s"
                        ") AS novo_id;",
                        (
                            command.sala_id,
                            command.usuario_id,
                            command.inicio,
                            command.fim,
                            command.finalidade,
                            command.qtd_participantes,
                        ),
                    )
                    row = cur.fetchone()
                    return int(row["novo_id"]) if row else 0
        except psycopg.Error as exc:
            raise self._translate_error(exc) from exc

    def cancelar_reserva(self, command: CancelarReservaCommand) -> bool:
        """Chama a function cancelar_reserva no PostgreSQL."""
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT cancelar_reserva(%s, %s) AS ok;",
                        (command.reserva_id, command.usuario_id),
                    )
                    row = cur.fetchone()
                    return bool(row["ok"]) if row else False
        except psycopg.Error as exc:
            raise self._translate_error(exc) from exc

    def listar_meses_ocupacao(self) -> list[str]:
        """Lista os meses disponíveis em mv_ocupacao_mensal."""
        df = self._fetch_df(
            "SELECT DISTINCT ano_mes, mes_referencia "
            "FROM mv_ocupacao_mensal ORDER BY ano_mes DESC;"
        )
        if df.empty:
            return ["2026-09"]
        return df["ano_mes"].tolist()

    def consultar_ocupacao_mensal(self, ano_mes: str) -> pd.DataFrame:
        """Consulta a materialized view mv_ocupacao_mensal."""
        return self._fetch_df(
            """
            SELECT sala_codigo AS "Código",
                   sala_nome AS "Sala / Laboratório",
                   tipo_sala AS "Tipo",
                   bloco_sigla AS "Bloco",
                   ano_mes AS "Mês",
                   total_reservas_ativas AS "Reservas Ativas",
                   horas_reservadas AS "Horas Reservadas",
                   horas_disponiveis AS "Horas Disponíveis (14h/dia)",
                   taxa_ocupacao_pct || '%' AS "Taxa de Ocupação (%)"
              FROM mv_ocupacao_mensal
             WHERE ano_mes = %s
             ORDER BY taxa_ocupacao_pct DESC, sala_codigo ASC;
            """,
            (ano_mes,),
        )

    def atualizar_ocupacao_mensal(self) -> None:
        """Chama a function atualizar_ocupacao_mensal() no PostgreSQL."""
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT atualizar_ocupacao_mensal();")
        except psycopg.Error as exc:
            raise self._translate_error(exc) from exc

    def testar_acesso_direto_tabela(self, nome_tabela: str) -> pd.DataFrame:
        """Tenta executar SELECT direto em uma tabela base protegida."""
        query = pgsql.SQL("SELECT * FROM {} LIMIT 5;").format(
            pgsql.Identifier(nome_tabela)
        )
        return self._fetch_df(query)
