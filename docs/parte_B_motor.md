# Documentação Parte B — "Motor" (Lógica, Dados, Índices e Consultas Analíticas)

**Tasks cobertas:** B1, B2, B3, B4, B5, B6, B7, B8, B9, B10 e B11.

---

## 1. Programação no Banco: Functions, Views e Materialized View (B2 a B6)

### 1.1. Function `criar_reserva` (B2)
- **Assinatura**: `criar_reserva(p_sala_id INT, p_usuario_id INT, p_inicio TIMESTAMPTZ, p_fim TIMESTAMPTZ, p_finalidade VARCHAR, p_qtd_participantes INT) RETURNS BIGINT`
- **Responsabilidades**:
  1. Valida parâmetros obrigatórios, existência e status ativo de `sala` e `usuario`.
  2. Valida que `p_fim > p_inicio`, que a duração está entre `30 minutes` e `4 hours`, e que a antecedência está dentro da janela operacional (não está no passado e não ultrapassa 30 dias no futuro).
  3. Constrói o intervalo semiaberto `tstzrange(p_inicio, p_fim, '[)')` e executa o `INSERT INTO reserva` dentro de um bloco `BEGIN ... EXCEPTION WHEN exclusion_violation THEN ... END;`, convertendo o erro `SQLSTATE 23P01` da constraint `EXCLUDE` em uma mensagem clara de negócio (`[CONFLITO_HORARIO] Conflito de agenda: a sala ... já está reservada...`).

### 1.2. Function `cancelar_reserva` (B3)
- **Assinatura**: `cancelar_reserva(p_reserva_id BIGINT, p_usuario_id INT) RETURNS BOOLEAN`
- **Responsabilidades**:
  1. Bloqueia a linha da reserva com `SELECT ... FOR UPDATE` para evitar condições de corrida entre cancelamentos simultâneos.
  2. Verifica se a reserva existe e se seu status é `'ATIVA'`.
  3. Verifica titularidade: exige que `p_usuario_id` seja o dono da reserva (`reserva.usuario_id`) ou tenha perfil `'ADMIN'` (`[REGRA_NAO_AUTORIZADO]`).
  4. Realiza a exclusão lógica (`UPDATE reserva SET status = 'CANCELADA'`), liberando imediatamente o horário no índice parcial do `EXCLUDE` e disparando a trigger de auditoria (`A3`).

### 1.3. Function `taxa_ocupacao(p_sala_id, p_mes)` (B4)
- **Assinatura**: `taxa_ocupacao(p_sala_id INT, p_mes DATE) RETURNS NUMERIC(5,2)`
- **Fórmula**:
  $$\text{Taxa de Ocupação (\%)} = \text{ROUND}\left(\frac{\text{Horas Reservadas Ativas no Mês}}{\text{Dias no Mês} \times 14\text{h}} \times 100,\; 2\right)$$
- **Detalhe técnico**: Utiliza o operador nativo de interseção de ranges do PostgreSQL (`r.periodo * v_range_mes`) para truncar com precisão matemática qualquer reserva que eventualmente toque a fronteira do mês, somando apenas o tempo efetivamente contido dentro do mês consultado e filtrando `r.status = 'ATIVA'`.
- **Caso de validação montado à mão (`05_seed.sql`)**:
  Na Sala `1` (`A-101`), em `2026-09-01` (Setembro tem 30 dias $\times 14\text{h} = 420\text{h}$ disponíveis), inserimos **14 reservas ativas de 3h** ($42\text{h}$) e **1 reserva cancelada de 3h**. A função ignora a cancelada e retorna exatamente **`10.00`** ($42 / 420 = 10,00\%$).

### 1.4. Views e Materialized View (B5 e B6)
- **`v_agenda_dia`**: Exibe as reservas `ATIVAS` com dados da sala, bloco, horários formatados (`HH24:MI`), titular, finalidade e lotação, ordenadas por `lower(periodo), sala_codigo`.
- **`v_reservas_usuario`**: Lista apenas as reservas `ATIVAS` e **futuras** (`upper(periodo) > CURRENT_TIMESTAMP`) ordenadas cronologicamente.
- **`mv_ocupacao_mensal`**: Visão materializada que consolida por `(sala_id, mes_referencia)` o total de reservas ativas, as horas reservadas, as horas disponíveis e a `taxa_ocupacao(s.id, m.mes_referencia)`. Possui o índice único `uq_mv_ocupacao_mensal_sala_mes ON mv_ocupacao_mensal (sala_id, mes_referencia)`, permitindo atualização sem bloqueio de leitura via `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ocupacao_mensal`.

---

## 2. Povoamento de +10.000 Reservas (`sql/07_seed_10k.sql` — B7)

Para superar a marca de 10.000 reservas variadas sem desabilitar nenhuma trigger nem travar em colisões de horário:
1. Utilizamos `generate_series` combinado com `random()` sorteando salas (1 a 20), usuários (1 a 400), dias nos últimos 330 dias e nos próximos 25 dias, e slots fixos de 2 horas (`08:00`, `10:00`, `12:00`, `14:00`, `16:00`, `18:00`, `20:00`).
2. Aplicamos `ON CONFLICT DO NOTHING` na instrução `INSERT INTO reserva ... SELECT ...`, fazendo com que qualquer colisão de horário na mesma sala seja absorvida pela constraint `EXCLUDE` (`ex_reserva_conflito_horario`) sem abortar a carga em lote.
3. Resultado após `./reset.sh --full`: **18.459 reservas** gravadas (entre ativas e canceladas, passadas e futuras), todas devidamente auditadas em `log_reserva`.

---

## 3. Dois Índices Parciais e Análise de `EXPLAIN ANALYZE` (B8)

A constraint `EXCLUDE` da Task A2 já cria automaticamente um índice **GiST parcial** na tabela `reserva`:
`ex_reserva_conflito_horario EXCLUDE USING gist (sala_id WITH =, periodo WITH &&) WHERE (status = 'ATIVA')`.

Para **não duplicar** esse índice, escolhemos duas consultas frequentes da aplicação que **não conseguem usar o índice GiST** (sofrendo `Seq Scan` nas 18.459 linhas):

1. **Índice 1 (`idx_reserva_data_inicio_ativa`)**: Índice B-Tree parcial por expressão de data + horário de início com colunas incluídas (`INCLUDE`), voltado para a consulta da **Agenda do Dia**:
   ```sql
   CREATE INDEX idx_reserva_data_inicio_ativa
       ON reserva (
           ((lower(periodo) AT TIME ZONE 'America/Sao_Paulo')::DATE),
           lower(periodo) ASC
       )
       INCLUDE (sala_id, usuario_id, finalidade)
       WHERE status = 'ATIVA';
   ```
2. **Índice 2 (`idx_reserva_usuario_ativa`)**: Índice B-Tree parcial composto para a consulta de **Reservas Ativas de um Usuário**:
   ```sql
   CREATE INDEX idx_reserva_usuario_ativa
       ON reserva (usuario_id, lower(periodo) DESC)
       WHERE status = 'ATIVA';
   ```

### 3.1. Comparativo Antes $\times$ Depois (`EXPLAIN (ANALYZE, BUFFERS)`)

| Consulta | Plano Antes do Índice | Buffers Lidos (Antes) | Tempo (Antes) | Plano Depois do Índice | Buffers Lidos (Depois) | Tempo (Depois) | Ganho |
| :--- | :--- | :---: | :---: | :--- | :---: | :---: | :---: |
| **Consulta 1: Agenda por Dia** | `Seq Scan on reserva` (removeu 18.456 linhas via filtro) | `307` blocos | **12,296 ms** | `Bitmap Index Scan on idx_reserva_data_inicio_ativa` | `3` blocos | **0,190 ms** | **64,7x mais rápida** (99% menos páginas lidas) |
| **Consulta 2: Reservas Ativas do Usuário** | `Seq Scan on reserva` (removeu 18.439 linhas via filtro) | `307` blocos | **4,202 ms** | `Bitmap Index Scan on idx_reserva_usuario_ativa` | `21` blocos | **0,391 ms** | **10,7x mais rápida** (93% menos páginas lidas) |

### 3.2. Planos Reais Capturados (`sql/explain_output.txt`)

#### Consulta 1 — ANTES do Índice (`Seq Scan` — 12.296 ms)
```text
 Sort  (cost=770.96..771.14 rows=74 width=61) (actual time=12.209..12.222 rows=3 loops=1)
   Sort Key: (lower(periodo))
   Sort Method: quicksort  Memory: 25kB
   Buffers: shared hit=307
   ->  Seq Scan on reserva  (cost=0.00..768.66 rows=74 width=61) (actual time=0.036..12.173 rows=3 loops=1)
         Filter: ((status = 'ATIVA'::status_reserva) AND (((lower(periodo) AT TIME ZONE 'America/Sao_Paulo'::text))::date = CURRENT_DATE))
         Rows Removed by Filter: 18456
         Buffers: shared hit=307
 Execution Time: 12.296 ms
```

#### Consulta 1 — DEPOIS do Índice (`Bitmap Index Scan` — 0.190 ms)
```text
 Sort  (cost=183.29..183.48 rows=74 width=61) (actual time=0.071..0.104 rows=3 loops=1)
   Sort Key: (lower(periodo))
   Sort Method: quicksort  Memory: 25kB
   Buffers: shared hit=1 read=2
   ->  Bitmap Heap Scan on reserva  (cost=4.86..181.00 rows=74 width=61) (actual time=0.035..0.066 rows=3 loops=1)
         Recheck Cond: ((((lower(periodo) AT TIME ZONE 'America/Sao_Paulo'::text))::date = CURRENT_DATE) AND (status = 'ATIVA'::status_reserva))
         Heap Blocks: exact=1
         Buffers: shared hit=1 read=2
         ->  Bitmap Index Scan on idx_reserva_data_inicio_ativa  (cost=0.00..4.84 rows=74 width=0) (actual time=0.023..0.025 rows=3 loops=1)
               Index Cond: (((lower(periodo) AT TIME ZONE 'America/Sao_Paulo'::text))::date = CURRENT_DATE)
               Buffers: shared read=2
 Execution Time: 0.190 ms
```

#### Consulta 2 — ANTES do Índice (`Seq Scan` — 4.202 ms)
```text
 Sort  (cost=584.83..584.92 rows=34 width=83) (actual time=4.043..4.085 rows=20 loops=1)
   Sort Key: (lower(periodo)) DESC
   Sort Method: quicksort  Memory: 27kB
   Buffers: shared hit=307
   ->  Seq Scan on reserva  (cost=0.00..583.97 rows=34 width=83) (actual time=0.020..3.941 rows=20 loops=1)
         Filter: ((usuario_id = 6) AND (status = 'ATIVA'::status_reserva))
         Rows Removed by Filter: 18439
         Buffers: shared hit=307
 Execution Time: 4.202 ms
```

#### Consulta 2 — DEPOIS do Índice (`Bitmap Index Scan` — 0.391 ms)
```text
 Sort  (cost=105.55..105.64 rows=34 width=83) (actual time=0.218..0.265 rows=20 loops=1)
   Sort Key: (lower(periodo)) DESC
   Sort Method: quicksort  Memory: 27kB
   Buffers: shared hit=19 read=2
   ->  Bitmap Heap Scan on reserva  (cost=4.55..104.69 rows=34 width=83) (actual time=0.052..0.130 rows=20 loops=1)
         Recheck Cond: ((usuario_id = 6) AND (status = 'ATIVA'::status_reserva))
         Heap Blocks: exact=19
         Buffers: shared hit=19 read=2
         ->  Bitmap Index Scan on idx_reserva_usuario_ativa  (cost=0.00..4.54 rows=34 width=0) (actual time=0.034..0.036 rows=20 loops=1)
               Index Cond: (usuario_id = 6)
               Buffers: shared read=2
 Execution Time: 0.391 ms
```

---

## 4. Cinco Consultas Analíticas (`sql/09_analytics.sql` — B9)

### Consulta 1 — Técnica: `JOIN` (Múltiplas Tabelas)
- **Enunciado em português**: Listar as próximas 10 reservas ativas a partir do momento atual, exibindo a sigla do bloco, o código e o tipo da sala, o nome e o perfil do usuário responsável, os horários de início e fim e a quantidade de tipos de equipamentos instalados na sala.
- **SQL**:
  ```sql
  SELECT
      r.id                                                                 AS reserva_id,
      b.sigla                                                              AS bloco,
      s.codigo                                                             AS sala,
      s.tipo                                                               AS tipo_sala,
      u.nome                                                               AS responsavel,
      u.tipo                                                               AS perfil,
      to_char(lower(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') AS inicio,
      to_char(upper(r.periodo) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')            AS fim,
      COUNT(sr.recurso_id)                                                 AS tipos_equipamentos_na_sala
  FROM reserva r
  INNER JOIN sala s          ON s.id = r.sala_id
  INNER JOIN bloco b         ON b.id = s.bloco_id
  INNER JOIN usuario u       ON u.id = r.usuario_id
  LEFT  JOIN sala_recurso sr ON sr.sala_id = s.id
  WHERE r.status = 'ATIVA'
    AND upper(r.periodo) > CURRENT_TIMESTAMP
  GROUP BY r.id, b.sigla, s.codigo, s.tipo, u.nome, u.tipo, r.periodo
  ORDER BY lower(r.periodo) ASC
  LIMIT 10;
  ```
- **Resultado**:
  ```text
   reserva_id | bloco |  sala  |  tipo_sala   |          responsavel           |  perfil   |      inicio      |  fim  | tipos_equipamentos_na_sala 
  ------------+-------+--------+--------------+--------------------------------+-----------+------------------+-------+----------------------------
           17 | BL-B  | LAB-01 | LABORATORIO  | Prof. Dr. Marcos Aurelio Silva | PROFESSOR | 2026-11-08 10:00 | 12:00 |                          3
           18 | BL-A  | A-101  | SALA_AULA    | Profa. Dra. Beatriz Nogueira   | PROFESSOR | 2026-11-08 14:00 | 16:00 |                          2
        20371 | BL-C  | B-102  | SALA_REUNIAO | Usuário Acadêmico 355          | ALUNO     | 2026-11-09 08:00 | 10:00 |                          0
        20196 | BL-B  | LAB-03 | LABORATORIO  | Usuário Acadêmico 180          | PROFESSOR | 2026-11-09 08:00 | 10:00 |                          2
        20246 | BL-B  | B-110  | LABORATORIO  | Usuário Acadêmico 230          | PROFESSOR | 2026-11-09 10:00 | 12:00 |                          0
        20071 | BL-A  | B-106  | SALA_AULA    | Usuário Acadêmico 55           | ALUNO     | 2026-11-09 10:00 | 12:00 |                          0
           20 | BL-A  | A-201  | SALA_REUNIAO | Fernanda Costa Oliveira        | ALUNO     | 2026-11-09 10:00 | 11:30 |                          2
        20296 | BL-A  | B-103  | SALA_AULA    | Usuário Acadêmico 280          | PROFESSOR | 2026-11-09 12:00 | 14:00 |                          0
        20121 | BL-C  | AUD-01 | AUDITORIO    | Usuário Acadêmico 105          | ALUNO     | 2026-11-09 12:00 | 14:00 |                          3
           19 | BL-B  | LAB-01 | LABORATORIO  | Carlos Eduardo Mendes          | ALUNO     | 2026-11-09 14:00 | 16:00 |                          3
  ```
- **Interpretação**: A combinação de `INNER JOIN` (entre `reserva`, `sala`, `bloco` e `usuario`) com `LEFT JOIN` em `sala_recurso` permite visualizar a agenda operacional enriquecida com a infraestrutura da sala sem descartar salas multiuso que não possuem recursos extras cadastrados (`tipos_equipamentos_na_sala = 0`).

---

### Consulta 2 — Técnica: `GROUP BY / HAVING`
- **Enunciado em português**: Identificar as salas de alta demanda e alta desistência que acumulam mais de 400 horas de reservas ativas e possuem taxa de cancelamento superior a 15%.
- **SQL**:
  ```sql
  SELECT
      s.codigo                                                             AS sala_codigo,
      s.nome                                                               AS sala_nome,
      COUNT(r.id)                                                          AS total_solicitacoes,
      COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')                        AS reservas_ativas,
      COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')                    AS reservas_canceladas,
      ROUND(
          SUM(EXTRACT(EPOCH FROM (upper(r.periodo) - lower(r.periodo))) / 3600.0)
          FILTER (WHERE r.status = 'ATIVA')::NUMERIC,
          1
      )                                                                    AS horas_ativas_totais,
      ROUND(
          (COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')::NUMERIC /
           NULLIF(COUNT(r.id), 0)) * 100.0,
          2
      )                                                                    AS taxa_cancelamento_pct
  FROM sala s
  JOIN reserva r ON r.sala_id = s.id
  GROUP BY s.id, s.codigo, s.nome
  HAVING SUM(EXTRACT(EPOCH FROM (upper(r.periodo) - lower(r.periodo))) / 3600.0)
         FILTER (WHERE r.status = 'ATIVA') > 400
     AND (COUNT(r.id) FILTER (WHERE r.status = 'CANCELADA')::NUMERIC / NULLIF(COUNT(r.id), 0)) > 0.15
  ORDER BY horas_ativas_totais DESC
  LIMIT 10;
  ```
- **Resultado**:
  ```text
   sala_codigo |           sala_nome           | total_solicitacoes | reservas_ativas | reservas_canceladas | horas_ativas_totais | taxa_cancelamento_pct 
  -------------+-------------------------------+--------------------+-----------------+---------------------+---------------------+-----------------------
   B-104       | Sala Multiuso 104             |                942 |             791 |                 151 |              1582.0 |                 16.03
   A-102       | Sala de Aula 102              |                936 |             777 |                 159 |              1554.0 |                 16.99
   A-101       | Sala de Aula 101              |                916 |             769 |                 147 |              1552.0 |                 16.05
   LAB-03      | Laboratório de IA e Robótica  |                925 |             774 |                 151 |              1548.0 |                 16.32
   A-201       | Sala de Reunião Departamental |                924 |             769 |                 155 |              1537.5 |                 16.77
   LAB-01      | Laboratório de Banco de Dados |                918 |             768 |                 150 |              1536.0 |                 16.34
   B-101       | Sala Multiuso 101             |                907 |             767 |                 140 |              1534.0 |                 15.44
   B-109       | Sala Multiuso 109             |                951 |             767 |                 184 |              1534.0 |                 19.35
   B-110       | Sala Multiuso 110             |                904 |             758 |                 146 |              1516.0 |                 16.15
   B-111       | Sala Multiuso 111             |                922 |             757 |                 165 |              1514.0 |                 17.90
  ```
- **Interpretação**: As salas `B-104`, `A-102` e `A-101` lideram em carga horária efetiva (> 1.550 horas ativas), enquanto `B-109` apresenta a maior taxa de cancelamento (19,35%), sinalizando espaços onde bloqueios preventivos e desistências precisam de acompanhamento da coordenação.

---

### Consulta 3 — Técnica: `SUBCONSULTA` (Subquery Correlacionada)
- **Enunciado em português**: Encontrar todas as salas cuja quantidade de reservas ativas é estritamente maior do que a média de reservas ativas das salas pertencentes ao mesmo bloco.
- **SQL**:
  ```sql
  SELECT
      s.codigo      AS sala_codigo,
      s.nome        AS sala_nome,
      b.sigla       AS bloco_sigla,
      (
          SELECT COUNT(*)
          FROM reserva r
          WHERE r.sala_id = s.id
            AND r.status = 'ATIVA'
      )             AS reservas_ativas_sala,
      ROUND(
          (
              SELECT AVG(contagem_bloco.qtd)
              FROM (
                  SELECT COUNT(r2.id) AS qtd
                  FROM sala s2
                  LEFT JOIN reserva r2 ON r2.sala_id = s2.id AND r2.status = 'ATIVA'
                  WHERE s2.bloco_id = s.bloco_id
                  GROUP BY s2.id
              ) AS contagem_bloco
          ),
          2
      )             AS media_bloco
  FROM sala s
  JOIN bloco b ON b.id = s.bloco_id
  WHERE (
      SELECT COUNT(*)
      FROM reserva r
      WHERE r.sala_id = s.id
        AND r.status = 'ATIVA'
  ) > (
      SELECT AVG(contagem_bloco.qtd)
      FROM (
          SELECT COUNT(r2.id) AS qtd
          FROM sala s2
          LEFT JOIN reserva r2 ON r2.sala_id = s2.id AND r2.status = 'ATIVA'
          WHERE s2.bloco_id = s.bloco_id
          GROUP BY s2.id
      ) AS contagem_bloco
  )
  ORDER BY reservas_ativas_sala DESC;
  ```
- **Resultado**:
  ```text
   sala_codigo |            sala_nome             | bloco_sigla | reservas_ativas_sala | media_bloco 
  -------------+----------------------------------+-------------+----------------------+-------------
   B-103       | Sala Multiuso 103                | BL-A        |                  837 |      753.00
   B-104       | Sala Multiuso 104                | BL-B        |                  791 |      726.00
   A-102       | Sala de Aula 102                 | BL-A        |                  777 |      753.00
   B-105       | Sala Multiuso 105                | BL-C        |                  775 |      728.50
   LAB-03      | Laboratório de IA e Robótica     | BL-B        |                  774 |      726.00
   A-201       | Sala de Reunião Departamental    | BL-A        |                  769 |      753.00
   A-101       | Sala de Aula 101                 | BL-A        |                  769 |      753.00
   LAB-01      | Laboratório de Banco de Dados    | BL-B        |                  768 |      726.00
  ```
- **Interpretação**: A subconsulta correlacionada compara cada sala apenas com seus pares do mesmo prédio (`s2.bloco_id = s.bloco_id`), revelando que `B-103` (837 vs média 753 no `BL-A`) e `B-104` (791 vs média 726 no `BL-B`) puxam a demanda de seus respectivos blocos para cima.

---

### Consulta 4 — Técnica: `CTE` (`WITH`)
- **Enunciado em português**: Avaliar a eficiência de dimensionamento físico das salas (taxa de aproveitamento de assentos), comparando a média de participantes por reserva ativa com a capacidade máxima de cada sala.
- **SQL**:
  ```sql
  WITH metricas_ocupacao_sala AS (
      SELECT
          r.sala_id,
          COUNT(*)                           AS qtd_reservas_ativas,
          ROUND(AVG(r.qtd_participantes), 2) AS media_participantes,
          MAX(r.qtd_participantes)           AS pico_participantes
      FROM reserva r
      WHERE r.status = 'ATIVA'
      GROUP BY r.sala_id
  )
  SELECT
      s.codigo                                                   AS sala_codigo,
      s.tipo                                                     AS tipo_sala,
      s.capacidade                                               AS capacidade_maxima,
      m.qtd_reservas_ativas,
      m.media_participantes,
      m.pico_participantes,
      ROUND((m.media_participantes / s.capacidade) * 100.0, 2)   AS taxa_aproveitamento_assentos_pct
  FROM metricas_ocupacao_sala m
  JOIN sala s ON s.id = m.sala_id
  ORDER BY taxa_aproveitamento_assentos_pct DESC
  LIMIT 10;
  ```
- **Resultado**:
  ```text
   sala_codigo |  tipo_sala   | capacidade_maxima | qtd_reservas_ativas | media_participantes | pico_participantes | taxa_aproveitamento_assentos_pct 
  -------------+--------------+-------------------+---------------------+---------------------+--------------------+----------------------------------
   A-201       | SALA_REUNIAO |                12 |                 769 |                6.98 |                 11 |                            58.17
   C-301       | SALA_REUNIAO |                15 |                 748 |                7.06 |                 11 |                            47.07
   LAB-03      | LABORATORIO  |                20 |                 774 |                6.93 |                 11 |                            34.65
   LAB-02      | LABORATORIO  |                25 |                 603 |                6.53 |                 11 |                            26.12
   LAB-01      | LABORATORIO  |                30 |                 768 |                7.07 |                 28 |                            23.57
  ```
- **Interpretação**: A CTE separa o pré-cálculo das métricas de público do cruzamento com o cadastro das salas, mostrando que salas menores de reunião (`A-201` com 58,17% e `C-301` com 47,07% de ocupação média de assentos) têm dimensionamento mais ajustado à demanda média de grupos pequenos do que salas de 30–40 lugares usadas por grupos de estudo.

---

### Consulta 5 — Técnica: `WINDOW FUNCTION` (`RANK() OVER` e `SUM() OVER`)
- **Enunciado em português**: Elaborar o ranking das salas mais disputadas dentro de cada bloco (`PARTITION BY b.id`) juntamente com a participação percentual (*share*) de cada sala no total de reservas ativas do seu bloco.
- **SQL**:
  ```sql
  SELECT
      b.sigla                                                    AS bloco,
      s.codigo                                                   AS sala_codigo,
      s.tipo                                                     AS tipo_sala,
      COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')              AS reservas_ativas,
      RANK() OVER (
          PARTITION BY b.id
          ORDER BY COUNT(r.id) FILTER (WHERE r.status = 'ATIVA') DESC
      )                                                          AS ranking_no_bloco,
      ROUND(
          (
              COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')::NUMERIC /
              NULLIF(SUM(COUNT(r.id) FILTER (WHERE r.status = 'ATIVA')) OVER (PARTITION BY b.id), 0)
          ) * 100.0,
          2
      )                                                          AS share_no_bloco_pct
  FROM sala s
  JOIN bloco b ON b.id = s.bloco_id
  LEFT JOIN reserva r ON r.sala_id = s.id
  GROUP BY b.id, b.sigla, s.id, s.codigo, s.tipo
  ORDER BY b.sigla ASC, ranking_no_bloco ASC;
  ```
- **Resultado**:
  ```text
   bloco | sala_codigo |  tipo_sala   | reservas_ativas | ranking_no_bloco | share_no_bloco_pct 
  -------+-------------+--------------+-----------------+------------------+--------------------
   BL-A  | B-103       | SALA_AULA    |             837 |                1 |              15.88
   BL-A  | A-102       | SALA_AULA    |             777 |                2 |              14.74
   BL-A  | A-201       | SALA_REUNIAO |             769 |                3 |              14.59
   BL-A  | A-101       | SALA_AULA    |             769 |                3 |              14.59
   BL-A  | B-109       | SALA_AULA    |             767 |                5 |              14.55
   BL-B  | B-104       | LABORATORIO  |             791 |                1 |              15.56
   BL-B  | LAB-03      | LABORATORIO  |             774 |                2 |              15.23
   BL-B  | LAB-01      | LABORATORIO  |             768 |                3 |              15.11
   BL-C  | B-105       | SALA_REUNIAO |             775 |                1 |              17.73
   BL-C  | B-111       | SALA_REUNIAO |             757 |                2 |              17.32
  ```
- **Interpretação**: As *window functions* `RANK() OVER (PARTITION BY b.id ...)` e `SUM(...) OVER (PARTITION BY b.id)` calculam simultaneamente a posição competitiva de cada sala no seu bloco (inclusive tratando o empate na 3ª posição do `BL-A` entre `A-201` e `A-101` com 769 reservas e pulando para a posição 5) e sua fatia percentual no prédio sem colapsar as linhas individuais.
