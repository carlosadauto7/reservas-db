"""Objetos de valor e exceções da camada de domínio."""

from dataclasses import dataclass
from datetime import datetime


class DatabaseRuleError(Exception):
    """Exceção de domínio que encapsula erros de regra/permissão do SGBD."""

    def __init__(self, message: str, sqlstate: str = "ERRO") -> None:
        self.message = message
        self.sqlstate = sqlstate
        super().__init__(f"{message} (SQLSTATE: {sqlstate})")


@dataclass(frozen=True)
class NovaReservaCommand:
    """Dados de entrada para solicitação de uma nova reserva."""

    sala_id: int
    usuario_id: int
    inicio: datetime
    fim: datetime
    finalidade: str
    qtd_participantes: int


@dataclass(frozen=True)
class CancelarReservaCommand:
    """Dados de entrada para cancelamento de uma reserva existente."""

    reserva_id: int
    usuario_id: int
