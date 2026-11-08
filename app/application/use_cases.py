"""Serviço de aplicação que orquestra chamadas à porta de persistência.

Em conformidade com a Task A7, nenhuma validação de negócio é feita em
Python; todos os comandos são repassados diretamente ao PostgreSQL.
"""

from datetime import date

import pandas as pd

from app.domain.entities import CancelarReservaCommand, NovaReservaCommand
from app.domain.repositories import ReservaRepositoryPort


class ReservaApplicationService:
    """Casos de uso da aplicação casca desacoplados de infraestrutura."""

    def __init__(self, repository: ReservaRepositoryPort) -> None:
        self._repo = repository

    def obter_catalogo_salas(self) -> pd.DataFrame:
        """Obtém a lista de salas disponíveis na view de catálogo."""
        return self._repo.listar_catalogo_salas()

    def obter_catalogo_usuarios(self) -> pd.DataFrame:
        """Obtém a lista de usuários ativos na view de catálogo."""
        return self._repo.listar_catalogo_usuarios()

    def consultar_agenda_do_dia(
        self,
        data_reserva: date,
        sala_id: int | None = None,
    ) -> pd.DataFrame:
        """Caso de Uso 1 (A7): Consulta a agenda do dia via v_agenda_dia."""
        return self._repo.consultar_agenda_dia(data_reserva, sala_id)

    def criar_nova_reserva(self, command: NovaReservaCommand) -> int:
        """Caso de Uso 2 (A7): Solicita criação de reserva via function."""
        return self._repo.criar_reserva(command)

    def listar_reservas_futuras(self) -> pd.DataFrame:
        """Lista as reservas ativas futuras via v_reservas_usuario."""
        return self._repo.listar_reservas_ativas_futuras()

    def cancelar_reserva_existente(
        self,
        command: CancelarReservaCommand,
    ) -> bool:
        """Caso de Uso 3 (A7): Solicita cancelamento via function."""
        return self._repo.cancelar_reserva(command)

    def listar_meses_relatorio(self) -> list[str]:
        """Retorna os meses disponíveis na materialized view."""
        return self._repo.listar_meses_ocupacao()

    def consultar_relatorio_mensal(self, ano_mes: str) -> pd.DataFrame:
        """Caso de Uso 4 (A7): Consulta ocupação mensal na MatView."""
        return self._repo.consultar_ocupacao_mensal(ano_mes)

    def atualizar_relatorio_mensal(self) -> None:
        """Dispara o REFRESH CONCURRENTLY da Materialized View."""
        self._repo.atualizar_ocupacao_mensal()

    def testar_bloqueio_tabela_base(self, nome_tabela: str) -> pd.DataFrame:
        """Caso de Uso 5 (A5/J5): Tenta ler tabela base como app_reservas."""
        return self._repo.testar_acesso_direto_tabela(nome_tabela)
