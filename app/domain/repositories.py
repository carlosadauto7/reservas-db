"""Interfaces (Ports) de acesso a dados da camada de domínio."""

from datetime import date
from typing import Protocol

import pandas as pd

from app.domain.entities import CancelarReservaCommand, NovaReservaCommand


class ReservaRepositoryPort(Protocol):
    """Contrato (Port) para comunicação com o banco PostgreSQL."""

    def listar_catalogo_salas(self) -> pd.DataFrame:
        """Retorna o catálogo de salas ativas via view v_catalogo_salas."""

    def listar_catalogo_usuarios(self) -> pd.DataFrame:
        """Retorna os usuários ativos via view v_catalogo_usuarios."""

    def consultar_agenda_dia(
        self,
        data_reserva: date,
        sala_id: int | None = None,
    ) -> pd.DataFrame:
        """Consulta a agenda do dia via view v_agenda_dia."""

    def listar_reservas_ativas_futuras(self) -> pd.DataFrame:
        """Lista as reservas ativas futuras via view v_reservas_usuario."""

    def criar_reserva(self, command: NovaReservaCommand) -> int:
        """Executa a function criar_reserva no PostgreSQL."""

    def cancelar_reserva(self, command: CancelarReservaCommand) -> bool:
        """Executa a function cancelar_reserva no PostgreSQL."""

    def listar_meses_ocupacao(self) -> list[str]:
        """Lista os meses disponíveis em mv_ocupacao_mensal."""

    def consultar_ocupacao_mensal(self, ano_mes: str) -> pd.DataFrame:
        """Consulta o relatório mensal na mv_ocupacao_mensal."""

    def atualizar_ocupacao_mensal(self) -> None:
        """Executa REFRESH MATERIALIZED VIEW CONCURRENTLY via function."""

    def testar_acesso_direto_tabela(self, nome_tabela: str) -> pd.DataFrame:
        """Tenta ler diretamente uma tabela protegida para provar bloqueio."""
