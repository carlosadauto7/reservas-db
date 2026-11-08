"""Script reproduzível de demonstração de Concorrência (Task A6).

Simula duas sessões concorrentes no PostgreSQL (Sessão A e Sessão B) mais
uma sessão observadora que inspeciona pg_stat_activity enquanto a Sessão B
está bloqueada esperando a decisão da Sessão A (COMMIT ou ROLLBACK).
"""

from datetime import date, datetime, time as dtime, timedelta
import os
import threading
import time
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
from psycopg.rows import dict_row

TZ_SP = ZoneInfo("America/Sao_Paulo")


def connect_db(autocommit: bool = False) -> psycopg.Connection:
    """Abre uma conexão com o banco PostgreSQL do projeto."""
    return psycopg.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", "5434")),
        dbname=os.getenv("DB_NAME", "reservas_db"),
        user=os.getenv("DB_ADMIN_USER", "postgres"),
        password=os.getenv("DB_ADMIN_PASSWORD", "postgres_password"),
        row_factory=dict_row,
        autocommit=autocommit,
    )


def run_cenario(tipo_desfecho: str, dia_offset: int) -> dict[str, Any]:
    """Executa um cenário concorrente entre Sessão A e Sessão B."""
    print("=" * 78)
    print(
        f" CENÁRIO: Sessão A faz {tipo_desfecho} enquanto Sessão B "
        "aguarda no mesmo horário"
    )
    print("=" * 78)

    data_alvo = date.today() + timedelta(days=dia_offset)
    dt_ini_a = datetime.combine(data_alvo, dtime(14, 0), tzinfo=TZ_SP)
    dt_fim_a = datetime.combine(data_alvo, dtime(16, 0), tzinfo=TZ_SP)
    dt_ini_b = datetime.combine(data_alvo, dtime(15, 0), tzinfo=TZ_SP)
    dt_fim_b = datetime.combine(data_alvo, dtime(17, 0), tzinfo=TZ_SP)

    t0 = time.monotonic()

    def elapsed_str() -> str:
        return f"[+{time.monotonic() - t0:05.2f}s]"

    conn_a = connect_db(autocommit=False)
    cur_a = conn_a.cursor()

    print(
        f"{elapsed_str()} [Sessão A] BEGIN; e inserindo reserva na Sala 2 "
        "(A-102) das 14:00 às 16:00 (SEM COMMIT)..."
    )
    cur_a.execute(
        "SELECT criar_reserva(%s, %s, %s, %s, %s, %s) AS id;",
        (2, 1, dt_ini_a, dt_fim_a, f"Reserva Sessão A ({tipo_desfecho})", 15),
    )
    row_a = cur_a.fetchone()
    id_a = row_a["id"] if row_a else None
    print(
        f"{elapsed_str()} [Sessão A] INSERT executado dentro da transação "
        f"aberta (id provisório={id_a}). Lock adquirido."
    )

    resultado_b: dict[str, Any] = {}

    def worker_sessao_b() -> None:
        conn_b = connect_db(autocommit=True)
        cur_b = conn_b.cursor()
        print(
            f"{elapsed_str()} [Sessão B] Tentando criar_reserva na Sala 2 "
            "das 15:00 às 17:00 (conflitante)..."
        )
        print(
            f"{elapsed_str()} [Sessão B] ⏳ BLOQUEADA pelo índice GiST "
            "(EXCLUDE) aguardando fim da transação da Sessão A..."
        )
        try:
            cur_b.execute(
                "SELECT criar_reserva(%s, %s, %s, %s, %s, %s) AS id;",
                (
                    2,
                    2,
                    dt_ini_b,
                    dt_fim_b,
                    f"Reserva Sessão B (após {tipo_desfecho})",
                    15,
                ),
            )
            res = cur_b.fetchone()
            resultado_b["status"] = "SUCESSO"
            resultado_b["id"] = res["id"] if res else None
            print(
                f"{elapsed_str()} [Sessão B] ✅ DESBLOQUEADA! "
                f"Reserva criada com sucesso! ID={resultado_b['id']}"
            )
        except psycopg.Error as exc:
            resultado_b["status"] = "ERRO"
            resultado_b["erro"] = (
                exc.diag.message_primary if exc.diag else str(exc)
            )
            print(
                f"{elapsed_str()} [Sessão B] ❌ DESBLOQUEADA COM ERRO: "
                f"{resultado_b['erro']} (SQLSTATE={exc.sqlstate})"
            )
        finally:
            conn_b.close()

    thread_b = threading.Thread(target=worker_sessao_b)
    thread_b.start()

    time.sleep(0.4)

    with connect_db(autocommit=True) as conn_obs:
        with conn_obs.cursor() as cur_obs:
            cur_obs.execute(
                """
                SELECT pid,
                       state,
                       wait_event_type,
                       wait_event,
                       pg_blocking_pids(pid) AS bloqueado_por_pids
                  FROM pg_stat_activity
                 WHERE datname = current_database()
                   AND wait_event_type = 'Lock';
                """
            )
            bloqueios = cur_obs.fetchall()
            for item in bloqueios:
                print(
                    f"{elapsed_str()} [Observador pg_stat_activity] "
                    f"PID {item['pid']} está em state='{item['state']}', "
                    f"wait_event='{item['wait_event_type']}:"
                    f"{item['wait_event']}', "
                    f"bloqueado pelo PID {item['bloqueado_por_pids']}"
                )

    time.sleep(0.4)

    if tipo_desfecho == "COMMIT":
        print(f"{elapsed_str()} [Sessão A] Executando COMMIT;...")
        conn_a.commit()
    else:
        print(f"{elapsed_str()} [Sessão A] Executando ROLLBACK;...")
        conn_a.rollback()

    thread_b.join()
    conn_a.close()
    print()
    return resultado_b


def main() -> None:
    """Executa e valida os dois cenários de concorrência."""
    res_commit = run_cenario("COMMIT", dia_offset=10)
    assert res_commit["status"] == "ERRO", (
        "Sessão B deveria falhar após COMMIT da Sessão A!"
    )

    res_rollback = run_cenario("ROLLBACK", dia_offset=11)
    assert res_rollback["status"] == "SUCESSO", (
        "Sessão B deveria passar após ROLLBACK da Sessão A!"
    )
    print(
        "Ambos os cenários de concorrência (COMMIT -> Erro; "
        "ROLLBACK -> Sucesso) validados com êxito!"
    )


if __name__ == "__main__":
    main()
