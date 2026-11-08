# Guia da Defesa Oral (J4) e Roteiro da Demonstração de 5 Minutos (J5)

---

## Parte 1 — Ensaio da Oral: As 5 Perguntas Cruzadas (Task J4)

No Dia 10, cada integrante explica a parte do outro sem olhar o código e responde às 5 perguntas abaixo:

### 1. Como funciona o `EXCLUDE USING gist` e por que reservas adjacentes (10h–11h e 11h–12h) ou canceladas não conflitam?
- **Resposta**:
  A constraint `EXCLUDE USING gist (sala_id WITH =, periodo WITH &&) WHERE (status = 'ATIVA')` cria um índice GiST parcial que impede que duas linhas distintas satisfaçam simultaneamente a igualdade de sala (`sala_id =`) **e** a interseção temporal (`periodo &&`).
  - **Adjacentes passam**: porque usamos o tipo `tstzrange` com limites semiabertos `[)` (garantido pela `CHECK` constraint `lower_inc(periodo) AND NOT upper_inc(periodo)`). Na reserva das `10:00` às `11:00`, o instante `11:00` é aberto/exclusivo, enquanto na reserva das `11:00` às `12:00` o instante `11:00` é fechado/inclusivo. Logo, a interseção `[10:00, 11:00) && [11:00, 12:00)` é vazia (`FALSE`).
  - **Canceladas não bloqueiam**: porque a cláusula `WHERE (status = 'ATIVA')` torna o índice GiST parcial. Assim que uma reserva muda para `'CANCELADA'`, ela sai do índice e libera o horário.

### 2. O que acontece no banco quando duas sessões tentam reservar o mesmo horário simultaneamente (concorrência)?
- **Resposta**:
  - A **Sessão A** executa `BEGIN` e faz o `INSERT` da reserva. A linha entra na tabela e sua entrada no índice GiST fica vinculada ao `XID` (Transaction ID) em aberto da Sessão A.
  - Quando a **Sessão B** tenta inserir um horário sobreposto na mesma sala antes de A finalizar, o PostgreSQL detecta a colisão no índice GiST com uma transação não confirmada e coloca a **Sessão B em espera de lock (`wait_event = Lock:transactionid`)**.
  - Se a Sessão A fizer **`COMMIT`**, a Sessão B é desbloqueada imediatamente e recebe o erro `23P01` (`exclusion_violation`), capturado pela function `criar_reserva` e convertido na mensagem `[CONFLITO_HORARIO]`.
  - Se a Sessão A fizer **`ROLLBACK`**, a tupla de A é descartada e a Sessão B é desbloqueada e **conclui sua inserção com sucesso**.

### 3. Por que usamos `SECURITY DEFINER` nas functions e por que `SET search_path` é obrigatório junto com ele?
- **Resposta**:
  - A role da aplicação (`app_reservas`) sofreu `REVOKE ALL` em todas as tabelas base (`reserva`, `usuario`, `sala`, `log_reserva`), não podendo ler nem escrever diretamente nelas.
  - Ao declarar `criar_reserva` e `cancelar_reserva` como `SECURITY DEFINER`, elas executam com as permissões do dono da função (`postgres`), permitindo gravar na tabela `reserva` **unicamente através das regras de negócio codificadas na função e nas triggers**.
  - O `SET search_path = public, pg_temp` na assinatura da função é indispensável para segurança: sem ele, um usuário conectado poderia alterar o `search_path` da sessão para apontar para um schema malicioso (`pg_temp`), fazendo a função `SECURITY DEFINER` executar objetos falsos com privilégio de superusuário (ataque de *search_path hijacking*).

### 4. O que é um Índice Parcial, onde o utilizamos no projeto e qual vantagem ele trouxe no `EXPLAIN ANALYZE`?
- **Resposta**:
  - Um **índice parcial** é um índice criado com uma cláusula `WHERE`, indexando apenas o subconjunto de linhas que satisfaz a condição.
  - Usamos índices parciais tanto na constraint `EXCLUDE` (`WHERE status = 'ATIVA'`) quanto nos dois índices B-Tree de desempenho (`idx_reserva_data_inicio_ativa` e `idx_reserva_usuario_ativa`, ambos com `WHERE status = 'ATIVA'`).
  - **Vantagens**: reduz o tamanho físico do índice em disco/memória, evita custo de manutenção do índice para reservas `'CANCELADA'` e acelerou a consulta da agenda do dia de **12,29 ms (`Seq Scan`, 307 buffers)** para **0,19 ms (`Bitmap Index Scan`, 3 buffers)** — mais de **60x de ganho**.

### 5. Por que o nosso modelo está na 3ª Forma Normal (3FN) e qual seria um exemplo concreto de violação da 3FN neste domínio?
- **Resposta**:
  - Uma tabela está na **3FN** quando está na 2FN e nenhum atributo não-chave depende transitivamente da chave primária através de outro atributo não-chave ($PK \rightarrow Y \rightarrow Z$).
  - **Exemplo de violação evitada**: se colocássemos `bloco_sigla`, `bloco_nome` e `bloco_localizacao` dentro da tabela `sala`, teríamos `sala.id -> bloco_sigla -> bloco_nome`. Atualizar o nome de um bloco exigiria alterar várias salas (anomalia de atualização), e excluir a última sala de um bloco apagaria a existência do bloco (anomalia de exclusão). Por isso separamos a entidade `bloco` e referenciamos apenas `bloco_id` em `sala`.

---

## Parte 2 — Roteiro da Demonstração de 5 Minutos (Task J5)

Sequência fixa exigida:
**`reset.sh` $\rightarrow$ 1. Reserva Válida $\rightarrow$ 2. Conflito $\rightarrow$ 3. Limite $\rightarrow$ 4. Cancelamento $\rightarrow$ 5. Acesso Negado**

Você pode demonstrar pela interface gráfica (**Streamlit**: `.venv/bin/streamlit run app/app.py`) ou pelo script automatizado de terminal:

```bash
./demo_5min.sh
```

| Passo | Tempo | Ação na Demo | Resultado Esperado |
| :---: | :---: | :--- | :--- |
| **0** | `0:00–0:30` | Rodar `./reset.sh` | Banco recriado do zero sem erros (schema, exclude, triggers, functions, views, seed e role `app_reservas`). |
| **1** | `0:30–1:30` | **Reserva Válida**: Aluno Gabriel (`ID 8`) reserva Sala `A-102` (`ID 2`) das `10:00` às `12:00` | Sucesso! Retorna o novo ID da reserva e aparece na view `v_agenda_dia` e `v_reservas_usuario`. |
| **2** | `1:30–2:30` | **Conflito de Horário**: Tentar reservar a mesma Sala `A-102` (`ID 2`) das `11:00` às `13:00` | Bloqueado pela constraint `EXCLUDE` e tratado por `criar_reserva`: `[CONFLITO_HORARIO] Conflito de agenda: a sala A-102 já está reservada... (SQLSTATE: 23P01)`. |
| **3** | `2:30–3:30` | **Limite de Reservas (Trigger A4)**: Gabriel (`ID 8`) faz a 2ª (`12:00–14:00`, adjacente!) e a 3ª (`14:00–16:00`) reservas futuras. Ao tentar a **4ª reserva futura** (`16:00–18:00`) | A 2ª (adjacente) e a 3ª passam; a **4ª é bloqueada pela Trigger A4**: `[REGRA_LIMITE_RESERVAS] Limite atingido: o usuário (ID 8) já possui 3 reservas ativas futuras...`. |
| **4** | `3:30–4:30` | **Cancelamento**: Tentar cancelar com usuário não-dono (`ID 9`) $\rightarrow$ falha! Em seguida, Gabriel (`ID 8`) cancela sua reserva das `10:00–12:00` e faz nova reserva no horário liberado | O status muda para `CANCELADA` (registrado em `log_reserva`), libera o horário `10:00–12:00` e libera a 3ª vaga futura do usuário! |
| **5** | `4:30–5:00` | **Acesso Negado (Role A5)**: Conectado como `app_reservas`, tentar `SELECT * FROM reserva;` ou `SELECT * FROM log_reserva;` | Bloqueado pelo SGBD: `permissão negada para a tabela reserva (SQLSTATE: 42501)`. |
