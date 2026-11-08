"""Configurações imutáveis de conexão com o banco de dados."""

from dataclasses import dataclass
import os


@dataclass(frozen=True)
class DatabaseSettings:
    """Parâmetros de conexão da role restrita 'app_reservas'."""

    host: str
    port: int
    dbname: str
    user: str
    password: str

    @classmethod
    def from_env(cls) -> "DatabaseSettings":
        """Carrega as configurações a partir das variáveis de ambiente."""
        return cls(
            host=os.getenv("DB_HOST", "127.0.0.1"),
            port=int(os.getenv("DB_PORT", "5434")),
            dbname=os.getenv("DB_NAME", "reservas_db"),
            user=os.getenv("DB_APP_USER", "app_reservas"),
            password=os.getenv("DB_APP_PASSWORD", "app_reservas_pass"),
        )
