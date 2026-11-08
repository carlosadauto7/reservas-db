# Entidades, Regras de Negócio e Convenções do Time (Tasks J1 e J3)

Este documento consolida o levantamento das entidades, atributos, regras de negócio (indicando em qual camada do PostgreSQL cada regra é garantida: **Constraint**, **Trigger** ou **Function**) e as convenções adotadas pela dupla.

---

## 1. Entidades e Atributos (J1 / J2)

| Entidade | Descrição | Chave Primária (PK) | Chaves Estrangeiras (FK) | Atributos Principais |
| :--- | :--- | :--- | :--- | :--- |
| **`bloco`** | Prédios/blocos acadêmicos que abrigam as salas (garante 3FN) | `id` (`pk_bloco`) | — | `sigla` (`UNIQUE`), `nome`, `localizacao`, `criado_em` |
| **`usuario`** | Alunos, professores, técnicos e administradores | `id` (`pk_usuario`) | — | `matricula` (`UNIQUE`), `nome`, `email` (`UNIQUE`), `tipo` (`ENUM tipo_usuario`), `ativo`, `criado_em` |
| **`sala`** | Salas de aula, laboratórios, auditórios e salas de reunião | `id` (`pk_sala`) | `bloco_id` $\rightarrow$ `bloco(id)` (`fk_sala_bloco`) | `codigo` (`UNIQUE`), `nome`, `tipo` (`ENUM tipo_sala`), `capacidade` (`DOMAIN capacidade_positiva`), `andar`, `ativa`, `criado_em` |
| **`recurso`** | Catálogo de equipamentos/recursos disponíveis | `id` (`pk_recurso`) | — | `nome` (`UNIQUE`), `descricao`, `criado_em` |
| **`sala_recurso`** | Tabela associativa N:N indicando quais e quantos recursos cada sala possui | `(sala_id, recurso_id)` (`pk_sala_recurso`) | `sala_id` $\rightarrow$ `sala(id)` (`fk_sala_recurso_sala`)<br>`recurso_id` $\rightarrow$ `recurso(id)` (`fk_sala_recurso_recurso`) | `quantidade` (`DOMAIN capacidade_positiva`), `observacao` |
| **`reserva`** | Agendamentos de uso das salas com intervalo `tstzrange` | `id` (`pk_reserva`) | `sala_id` $\rightarrow$ `sala(id)` (`fk_reserva_sala`)<br>`usuario_id` $\rightarrow$ `usuario(id)` (`fk_reserva_usuario`) | `periodo` (`TSTZRANGE`), `status` (`ENUM status_reserva`), `finalidade`, `qtd_participantes` (`DOMAIN capacidade_positiva`), `criado_em`, `atualizado_em` |
| **`log_reserva`** | Trilha de auditoria imutável das operações em `reserva` | `id` (`pk_log_reserva`) | — *(sem FK CASCADE para sobreviver a DELETE)* | `reserva_id`, `operacao` (`INSERT`/`UPDATE`/`DELETE`), `usuario_id`, `db_user`, `dados_antigos` (`JSONB`), `dados_novos` (`JSONB`), `registrado_em` |

---

## 2. Matriz de Regras de Negócio e Camada de Garantia (J1)

Cada regra de negócio do sistema possui uma camada de aplicação explícita dentro do PostgreSQL (**Constraint**, **Trigger** ou **Function**), escolhida de acordo com a natureza relacional da validação:

| Código | Regra de Negócio | Camada no Banco | Objeto Responsável no PostgreSQL | Justificativa Técnica da Camada |
| :--- | :--- | :--- | :--- | :--- |
| **RN01** | **Capacidade e quantidades positivas**: a capacidade de uma sala, a quantidade de um recurso e o número de participantes devem ser inteiros $> 0$ e $\le 2000$. | **Constraint (DOMAIN)** | `DOMAIN capacidade_positiva` (`ck_dominio_capacidade_positiva`) | Regra de domínio atômico reutilizada em `sala.capacidade`, `sala_recurso.quantidade` e `reserva.qtd_participantes`. |
| **RN02** | **Valores fechados de domínio**: status da reserva (`ATIVA`, `CANCELADA`), perfil de usuário (`ALUNO`, `PROFESSOR`, `TECNICO`, `ADMIN`) e tipo de sala (`SALA_AULA`, `LABORATORIO`, `AUDITORIO`, `SALA_REUNIAO`). | **Constraint (ENUM)** | `status_reserva`, `tipo_usuario`, `tipo_sala` | Tipagem forte nativa do PostgreSQL rejeita valores fora da lista em nível de parser/tipo. |
| **RN03** | **Intervalo temporal semiaberto `[)` e não vazio**: toda reserva deve ter início e fim definidos, com limite inferior inclusivo `[` e superior exclusivo `)`. | **Constraint (CHECK)** | `ck_reserva_periodo_nao_vazio`, `ck_reserva_periodo_semiaberto` | Permite validar na própria linha que `10:00–11:00` e `11:00–12:00` são adjacentes e não se sobrepõem. |
| **RN04** | **Duração mínima e máxima da reserva**: cada reserva deve durar entre **30 minutos** e **4 horas**. | **Constraint (CHECK)** | `ck_reserva_duracao_valida` (e validação prévia em `criar_reserva`) | Depende apenas da coluna `periodo` da própria linha: `(upper(periodo) - lower(periodo)) BETWEEN '30 min' AND '4 hours'`. |
| **RN05** | **Proibição de conflito de horário na mesma sala**: duas reservas `ATIVAS` na mesma sala não podem ter interseção de horário (`periodo WITH &&`); reservas `CANCELADAS` não bloqueiam o horário. | **Constraint (EXCLUDE)** | `ex_reserva_conflito_horario` (`EXCLUDE USING gist (sala_id WITH =, periodo WITH &&) WHERE (status = 'ATIVA')`) | Única forma declarativa e segura contra *race conditions* concorrentes no PostgreSQL usando índice GiST parcial. |
| **RN06** | **Lotação máxima da sala**: `reserva.qtd_participantes` não pode ultrapassar `sala.capacidade` da sala escolhida. | **Trigger (`BEFORE INSERT OR UPDATE`)** | `trg_validar_regras_reserva` $\rightarrow$ `fn_validar_regras_reserva()` | Uma `CHECK` constraint não pode consultar outra tabela (`sala`); a trigger garante a regra mesmo em `INSERT`/`UPDATE` diretos. |
| **RN07** | **Limite de reservas ativas futuras por usuário**: cada usuário pode ter no máximo **3 reservas com `status = 'ATIVA'` futuras** (`upper(periodo) > CURRENT_TIMESTAMP`), ignorando a própria linha em caso de `UPDATE`. | **Trigger (`BEFORE INSERT OR UPDATE`)** | `trg_validar_regras_reserva` $\rightarrow$ `fn_validar_regras_reserva()` | Regra de agregação entre múltiplas linhas da tabela `reserva` (`COUNT(*) < 3`). |
| **RN08** | **Auditoria automática de reservas**: toda criação (`INSERT`), alteração/cancelamento (`UPDATE`) ou remoção (`DELETE`) deve gravar estado anterior (`OLD`) e novo (`NEW`) em JSONB, usuário e timestamp. | **Trigger (`AFTER INSERT OR UPDATE OR DELETE`)** | `trg_auditoria_reserva` $\rightarrow$ `fn_auditoria_reserva()` | Garante rastreabilidade automática independentemente de qual função ou sessão alterou a tabela `reserva`. |
| **RN09** | **Janela de antecedência para novos agendamentos**: novas reservas criadas pela operação não podem iniciar no passado nem com mais de **30 dias de antecedência**. | **Function (`SECURITY DEFINER`)** | `criar_reserva(...)` | Aplicada na camada de serviço do banco (`Function`) para proteger o uso operacional sem impedir a carga histórica de testes/analytics (`05_seed.sql` e `07_seed_10k.sql`). |
| **RN10** | **Cancelamento lógico e titularidade**: reservas nunca são apagadas (`DELETE`), apenas mudam para `CANCELADA`; somente o titular da reserva (ou um `ADMIN`) pode cancelar uma reserva que esteja `ATIVA`. | **Function (`SECURITY DEFINER`)** | `cancelar_reserva(p_reserva_id, p_usuario_id)` | Encapsula o fluxo de negócio seguro (`SELECT ... FOR UPDATE` + verificação de titularidade + `UPDATE status = 'CANCELADA'`). |
| **RN11** | **Encapsulamento e privilégio mínimo**: a aplicação (`app_reservas`) não pode executar `SELECT`, `INSERT`, `UPDATE` ou `DELETE` diretamente nas tabelas base. | **Role / DCL + `SECURITY DEFINER`** | `sql/06_roles.sql` (`REVOKE ALL` nas tabelas, `GRANT SELECT` nas views, `GRANT EXECUTE` nas functions) | Impede que a aplicação contorne as regras ou manipule a tabela `log_reserva`. |

---

## 3. Convenções do Time (J3)

1. **Padrão de Nomenclatura**:
   - Tudo em `snake_case`, no singular para nomes de tabelas (`bloco`, `usuario`, `sala`, `recurso`, `sala_recurso`, `reserva`, `log_reserva`).
   - Prefixos obrigatórios para constraints:
     - `pk_<tabela>` para `PRIMARY KEY`
     - `fk_<tabela>_<referencia>` para `FOREIGN KEY`
     - `uq_<tabela>_<coluna>` para `UNIQUE`
     - `ck_<tabela>_<regra>` para `CHECK`
     - `ex_<tabela>_<regra>` para `EXCLUDE`
   - Prefixos de objetos programáveis:
     - `fn_*` para Trigger Functions
     - `trg_*` para Triggers
     - `v_*` para Views
     - `mv_*` para Materialized Views
     - `idx_*` para Índices B-Tree de desempenho

2. **Padrão de Mensagens de Erro**:
   - Todas as mensagens de negócio emitidas por Functions e Triggers seguem o formato:
     `[<CODIGO_REGRA>] Mensagem clara em português para o usuário final.`
   - Exemplos:
     - `[CONFLITO_HORARIO] Conflito de agenda: a sala A-102 já está reservada em parte ou todo o período...`
     - `[REGRA_LIMITE_RESERVAS] Limite atingido: o usuário (ID 8) já possui 3 reservas ativas futuras...`
     - `[REGRA_CAPACIDADE] Quantidade de participantes (25) excede a capacidade máxima da sala A-201 (12 lugares).`
     - `[REGRA_NAO_AUTORIZADO] Operação negada: o usuário (ID 9) não é o titular da reserva (ID 22).`

3. **Estrutura de Pastas do Repositório**:
   ```text
   reservas-db/
   ├── app/
   │   └── app.py                     # Aplicação Casca em Streamlit (A7)
   ├── concorrencia/
   │   ├── roteiro.md                 # Roteiro passo a passo e logs de concorrência (A6)
   │   └── simular_concorrencia.py    # Script que reproduz os 2 cenários de bloqueio
   ├── docs/
   │   ├── regras.md                  # Entidades, regras por camada e convenções (J1, J3)
   │   ├── parte_A_guardiao.md        # DER, 3FN, integridade, segurança e concorrência (J2, A8)
   │   ├── parte_B_motor.md           # Functions, Views, EXPLAIN ANALYZE e 5 Consultas (B8, B9, B11)
   │   └── roteiro_apresentacao_J4_J5.md # Guia da arguição oral (J4) e demo de 5 min (J5)
   ├── sql/
   │   ├── 01_schema.sql              # ENUMs, DOMAIN, Tabelas e Constraints (A1)
   │   ├── 02_exclude.sql             # Extensão btree_gist e EXCLUDE USING gist (A2)
   │   ├── 03_triggers.sql            # Triggers de auditoria (A3) e regras de negócio (A4)
   │   ├── 04_functions_views.sql     # Functions (B2-B4), Views (B5) e MatView (B6)
   │   ├── 05_seed.sql                # Seed base realista + mês de ocupação conhecida (B1)
   │   ├── 06_roles.sql               # Role app_reservas, REVOKE ALL e GRANTs (A5)
   │   ├── 07_seed_10k.sql            # Povoamento de +10.000 reservas com ON CONFLICT (B7)
   │   ├── 08_indexes_explain.sql     # Dois índices parciais e EXPLAIN ANALYZE antes/depois (B8)
   │   └── 09_analytics.sql           # Cinco consultas analíticas (B9)
   ├── tests/
   │   └── test_e2e.py                # Suíte automatizada de testes ponta a ponta (B10)
   ├── docker-compose.yml             # Container PostgreSQL 16 dedicado (porta 5434)
   ├── reset.sh                       # Script de recriação total do banco (J3, A1, J5)
   └── demo_5min.sh                   # Execução automatizada do roteiro de 5 minutos (J5)
   ```
