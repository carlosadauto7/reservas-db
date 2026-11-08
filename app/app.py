"""Composition Root da Aplicação Casca (Task A7 — Clean Architecture).

Conecta as camadas:
1. Infrastructure (DatabaseSettings + PostgresReservaRepository)
2. Application (ReservaApplicationService)
3. Presentation (StreamlitDashboard)
"""

from pathlib import Path
import sys

ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from app.application.use_cases import ReservaApplicationService  # noqa: E402
from app.infrastructure.config import DatabaseSettings  # noqa: E402
from app.infrastructure.postgres_repo import (  # noqa: E402
    PostgresReservaRepository,
)
from app.presentation.views import StreamlitDashboard  # noqa: E402


def build_dashboard() -> StreamlitDashboard:
    """Instancia e injeta as dependências seguindo Clean Architecture."""
    settings = DatabaseSettings.from_env()
    repository = PostgresReservaRepository(settings)
    service = ReservaApplicationService(repository)
    return StreamlitDashboard(service)


def main() -> None:
    """Ponto de entrada principal da aplicação Streamlit."""
    dashboard = build_dashboard()
    dashboard.render()


if __name__ == "__main__":
    main()
