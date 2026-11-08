# Roteiro de Concorrência no PostgreSQL (Task A6)

Este documento apresenta o roteiro passo a passo para reproduzir o controle de concorrência da constraint `EXCLUDE USING gist (sala_id WITH =, periodo WITH &&) WHERE (status = 'ATIVA')` utilizando **duas sessões `psql` simultâneas**, seguido da saída real capturada no banco.

---

## 1. Como funciona o bloqueio na Constraint `EXCLUDE`

Quando a **Sessão A** inicia uma transação (`BEGIN;`) e insere uma reserva ativa na sala `2` (`A-102`) para o intervalo `[14:00, 16:00)`, o PostgreSQL insere a tupla e registra sua entrada no índice GiST (`ex_reserva_conflito_horario`) associada ao `XID` (Transaction ID) aberto da Sessão A.

Quando a **Sessão B**, em paralelo, tenta inserir uma reserva ativa para a mesma sala `2` em um horário sobreposto `[15:00, 17:00)`:
1. O PostgreSQL verifica o índice GiST e encontra a tupla conflitante inserida pela **Sessão A**, cuja transação ainda está em andamento (`in-progress`).
2. Como o PostgreSQL sob `READ COMMITTED` não pode decidir se a reserva da Sessão A será efetivada ou descartada, a **Sessão B é bloqueada** (`wait_event_type = 'Lock'`, `wait_event = 'transactionid'`).
3. **Desfecho 1 (`COMMIT` na Sessão A)**: Assim que A executa `COMMIT`, a Sessão B é desbloqueada, confirma que a chave conflitante se tornou visível/definitiva, aborta sua inserção com `SQLSTATE 23P01` (`exclusion_violation`) e a function `criar_reserva` captura o erro retornando `[CONFLITO_HORARIO]`.
4. **Desfecho 2 (`ROLLBACK` na Sessão A)**: Assim que A executa `ROLLBACK`, a tupla de A é invalidada; a Sessão B é desbloqueada imediatamente e **conclui seu `INSERT` com sucesso**.

---

## 2. Roteiro Passo a Passo Manual com 2 Terminais `psql`

Primeiro, garanta que o banco está limpo rodando:
```bash
./reset.sh
```

Abra dois terminais lado a lado conectados ao banco:
```bash
PGPASSWORD=postgres_password psql -h 127.0.0.1 -p 5434 -U postgres -d reservas_db
```

### Parte 1: Sessão A faz `COMMIT` $\rightarrow$ Sessão B recebe erro

| Ordem | Terminal / Sessão | Comando SQL | Comportamento Esperado |
| :---: | :--- | :--- | :--- |
| **1** | **Terminal A** | `BEGIN;` | Inicia transação na Sessão A. |
| **2** | **Terminal A** | `SELECT criar_reserva(2, 1, '2026-11-18 14:00-03', '2026-11-18 16:00-03', 'Reserva Sessão A', 15);` | Retorna `id = 22` imediatamente, mas mantém a transação aberta (sem commit). |
| **3** | **Terminal B** | `SELECT criar_reserva(2, 2, '2026-11-18 15:00-03', '2026-11-18 17:00-03', 'Reserva Sessão B', 15);` | **O cursor do Terminal B trava (fica esperando)** porque o intervalo `[15:00, 17:00)` conflita com `[14:00, 16:00)` da transação aberta de A. |
| **4** | **Terminal A** | `COMMIT;` | Confirma a reserva da Sessão A. No mesmo milissegundo, o **Terminal B destrava e exibe `ERROR: [CONFLITO_HORARIO]`**. |

---

### Parte 2: Sessão A faz `ROLLBACK` $\rightarrow$ Sessão B passa com sucesso

| Ordem | Terminal / Sessão | Comando SQL | Comportamento Esperado |
| :---: | :--- | :--- | :--- |
| **1** | **Terminal A** | `BEGIN;` | Inicia nova transação na Sessão A. |
| **2** | **Terminal A** | `SELECT criar_reserva(2, 1, '2026-11-19 14:00-03', '2026-11-19 16:00-03', 'Reserva A (Desistência)', 15);` | Retorna `id = 24` provisório na transação aberta. |
| **3** | **Terminal B** | `SELECT criar_reserva(2, 2, '2026-11-19 15:00-03', '2026-11-19 17:00-03', 'Reserva B (Vai passar)', 15);` | **O cursor do Terminal B trava novamente**, aguardando a decisão da Sessão A. |
| **4** | **Terminal A** | `ROLLBACK;` | Desfaz a reserva da Sessão A. No mesmo milissegundo, o **Terminal B destrava e retorna `criar_reserva = 25` com sucesso!** |

---

## 3. Execução Automatizada e Evidência Real (`pg_stat_activity`)

Você também pode reproduzir os dois cenários automaticamente com medição de tempo e inspeção ao vivo da view de sistema `pg_stat_activity` rodando:

```bash
.venv/bin/python concorrencia/simular_concorrencia.py
```

### Saída Real Capturada da Execução:

```text
==============================================================================
 CENÁRIO: Sessão A faz COMMIT enquanto Sessão B aguarda no mesmo horário
==============================================================================
[+00.03s] [Sessão A] BEGIN; e inserindo reserva na Sala 2 (A-102) das 14:00 às 16:00 (SEM COMMIT)...
[+00.05s] [Sessão A] INSERT executado dentro da transação aberta (id provisório=22). Lock adquirido.
[+00.06s] [Sessão B] Tentando criar_reserva na Sala 2 das 15:00 às 17:00 (conflitante)...
[+00.06s] [Sessão B] ⏳ BLOQUEADA pelo índice GiST (EXCLUDE) aguardando fim da transação da Sessão A...
[+00.47s] [Observador pg_stat_activity] PID 2110 está em state='active', wait_event='Lock:transactionid', bloqueado pelo PID [2109]
[+00.87s] [Sessão A] Executando COMMIT;...
[+00.88s] [Sessão B] ❌ DESBLOQUEADA COM ERRO: [CONFLITO_HORARIO] Conflito de agenda: a sala A-102 já está reservada em parte ou todo o período de 18/11/2026 15:00 às 17:00. (SQLSTATE=23P01)

==============================================================================
 CENÁRIO: Sessão A faz ROLLBACK enquanto Sessão B aguarda no mesmo horário
==============================================================================
[+00.02s] [Sessão A] BEGIN; e inserindo reserva na Sala 2 (A-102) das 14:00 às 16:00 (SEM COMMIT)...
[+00.04s] [Sessão A] INSERT executado dentro da transação aberta (id provisório=24). Lock adquirido.
[+00.05s] [Sessão B] Tentando criar_reserva na Sala 2 das 15:00 às 17:00 (conflitante)...
[+00.05s] [Sessão B] ⏳ BLOQUEADA pelo índice GiST (EXCLUDE) aguardando fim da transação da Sessão A...
[+00.46s] [Observador pg_stat_activity] PID 2120 está em state='active', wait_event='Lock:transactionid', bloqueado pelo PID [2119]
[+00.86s] [Sessão A] Executando ROLLBACK;...
[+00.87s] [Sessão B] ✅ DESBLOQUEADA! Reserva criada com sucesso! ID=25

Ambos os cenários de concorrência (COMMIT -> Erro; ROLLBACK -> Sucesso) validados com êxito!
```
