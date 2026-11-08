-- ============================================================================
-- B1. SEED BASE — Dados realistas para testes e demonstração
-- ============================================================================

SET client_min_messages TO WARNING;
SET TIME ZONE 'America/Sao_Paulo';

-- 1. Blocos (3FN)
INSERT INTO bloco (sigla, nome, localizacao) VALUES
    ('BL-A', 'Bloco A — Ensino Graduação',     'Ala Norte — Entrada Principal'),
    ('BL-B', 'Bloco B — Laboratórios de TI',   'Ala Leste — Próximo à Biblioteca'),
    ('BL-C', 'Bloco C — Pós-Graduação e Eventos', 'Ala Sul — Centro de Convenções');

-- 2. Salas e Laboratórios
INSERT INTO sala (bloco_id, codigo, nome, tipo, capacidade, andar, ativa) VALUES
    (1, 'A-101', 'Sala de Aula 101',                'SALA_AULA',    40, 1, TRUE),
    (1, 'A-102', 'Sala de Aula 102',                'SALA_AULA',    35, 1, TRUE),
    (1, 'A-201', 'Sala de Reunião Departamental',   'SALA_REUNIAO', 12, 2, TRUE),
    (2, 'LAB-01', 'Laboratório de Banco de Dados',  'LABORATORIO',  30, 1, TRUE),
    (2, 'LAB-02', 'Laboratório de Redes e Sistemas','LABORATORIO',  25, 1, TRUE),
    (2, 'LAB-03', 'Laboratório de IA e Robótica',   'LABORATORIO',  20, 2, TRUE),
    (3, 'AUD-01', 'Auditório Principal Ada Lovelace','AUDITORIO',  150, 0, TRUE),
    (3, 'C-301', 'Sala de Seminários Avançados',    'SALA_REUNIAO', 15, 3, TRUE);

-- 3. Recursos
INSERT INTO recurso (nome, descricao) VALUES
    ('Projetor Laser 4K',          'Projetor HDMI/Sem fio de alta luminosidade'),
    ('Computador Desktop i7',      'Estação Linux/Windows com 32GB RAM e PostgreSQL 16'),
    ('Quadro Branco Magnético',    'Quadro panorâmico de vidro temperado'),
    ('Sistema de Som e Microfone', 'Caixas acústicas + 2 microfones sem fio'),
    ('Câmera de Videoconferência', 'Câmera PTZ Full HD com microfone omnidirecional'),
    ('Bancada de Eletrônica/IoT',  'Osciloscópio, fontes reguláveis e kits ESP32');

-- 4. Associação Sala <-> Recurso (sala_recurso)
INSERT INTO sala_recurso (sala_id, recurso_id, quantidade, observacao) VALUES
    (1, 1,  1, 'Instalado no teto'),
    (1, 3,  1, 'Parede frontal'),
    (2, 1,  1, 'Instalado no teto'),
    (2, 3,  1, 'Parede frontal'),
    (3, 1,  1, 'TV/Projetor para apresentações'),
    (3, 5,  1, 'Integrado à mesa de reunião'),
    (4, 1,  1, 'Projetor do professor'),
    (4, 2, 30, '1 máquina por aluno'),
    (4, 3,  1, 'Quadro auxiliar'),
    (5, 1,  1, 'Projetor do professor'),
    (5, 2, 25, 'Bancada com switches gerenciáveis'),
    (6, 2, 20, 'Workstations com GPU dedicada'),
    (6, 6, 10, '1 bancada para cada dupla'),
    (7, 1,  2, 'Telão duplo lateral'),
    (7, 4,  1, 'Mesa de som completa no palco'),
    (7, 5,  1, 'Transmissão ao vivo'),
    (8, 1,  1, 'Projetor multimídia'),
    (8, 5,  1, 'Kit híbrido de defesa de mestrado');

-- 5. Usuários
INSERT INTO usuario (matricula, nome, email, tipo, ativo) VALUES
    ('PROF-1001', 'Profa. Dra. Helena Vasconcelos', 'helena.vasconcelos@universidade.edu.br', 'PROFESSOR', TRUE),
    ('PROF-1002', 'Prof. Dr. Marcos Aurelio Silva', 'marcos.silva@universidade.edu.br',       'PROFESSOR', TRUE),
    ('PROF-1003', 'Profa. Dra. Beatriz Nogueira',   'beatriz.nogueira@universidade.edu.br',   'PROFESSOR', TRUE),
    ('TEC-2001',  'Ricardo Almeida (Técnico Lab)',  'ricardo.almeida@universidade.edu.br',    'TECNICO',   TRUE),
    ('ADM-0001',  'Coordenação de Infraestrutura',  'coord.infra@universidade.edu.br',        'ADMIN',     TRUE),
    ('ALU-3001',  'Carlos Eduardo Mendes',          'carlos.mendes@aluno.universidade.edu.br','ALUNO',     TRUE),
    ('ALU-3002',  'Fernanda Costa Oliveira',        'fernanda.oliveira@aluno.universidade.edu.br','ALUNO', TRUE),
    ('ALU-3003',  'Gabriel Santos Rocha',           'gabriel.rocha@aluno.universidade.edu.br','ALUNO',     TRUE),
    ('ALU-3004',  'Juliana Pereira Lima',           'juliana.lima@aluno.universidade.edu.br', 'ALUNO',     TRUE),
    ('ALU-3005',  'Lucas Martins Ferreira',         'lucas.ferreira@aluno.universidade.edu.br','ALUNO',    TRUE);

-- 6. Mês com ocupação conhecida montada à mão para validação exata de B4 e B6:
--    Setembro/2026 (30 dias * 14h/dia = 420 horas disponíveis no mês).
--    Inserimos na Sala 1 (A-101) exatamente 14 reservas ATIVAS de 3 horas = 42 horas reservadas.
--    42h / 420h = 10.00% de ocupação exata!
--    Inserimos também 1 reserva CANCELADA de 3h no mesmo mês para provar que NÃO entra na conta.
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes)
SELECT
    1,
    1,
    tstzrange(
        ('2026-09-01'::DATE + (d - 1))::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo' + INTERVAL '8 hours',
        ('2026-09-01'::DATE + (d - 1))::TIMESTAMP AT TIME ZONE 'America/Sao_Paulo' + INTERVAL '11 hours',
        '[)'
    ),
    'ATIVA',
    'Curso Intensivo de Modelagem Relacional — Dia ' || d,
    30
FROM generate_series(1, 14) AS d;

-- Reserva cancelada em Setembro/2026 (não deve somar na taxa_ocupacao)
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes)
VALUES (
    1,
    2,
    tstzrange(
        '2026-09-20 14:00:00-03'::TIMESTAMPTZ,
        '2026-09-20 17:00:00-03'::TIMESTAMPTZ,
        '[)'
    ),
    'CANCELADA',
    'Monitoria Extra (Cancelada)',
    20
);

-- 7. Reservas operacionais do dia atual e próximos dias (para a agenda do dia e demonstração)
INSERT INTO reserva (sala_id, usuario_id, periodo, status, finalidade, qtd_participantes) VALUES
    -- Reservas para HOJE (CURRENT_DATE)
    (
        4, -- LAB-01
        1, -- Profa. Helena
        tstzrange(
            (CURRENT_DATE + TIME '08:00') AT TIME ZONE 'America/Sao_Paulo',
            (CURRENT_DATE + TIME '10:00') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Aula Prática de SQL e Constraints (Turma A)',
        28
    ),
    (
        4, -- LAB-01 (Adjacente: começa exatamente às 10:00 quando a anterior termina!)
        2, -- Prof. Marcos
        tstzrange(
            (CURRENT_DATE + TIME '10:00') AT TIME ZONE 'America/Sao_Paulo',
            (CURRENT_DATE + TIME '12:00') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Laboratório de Indexação e EXPLAIN ANALYZE',
        25
    ),
    (
        1, -- A-101
        3, -- Profa. Beatriz
        tstzrange(
            (CURRENT_DATE + TIME '14:00') AT TIME ZONE 'America/Sao_Paulo',
            (CURRENT_DATE + TIME '16:00') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Aula Teórica de Normalização e 3FN',
        35
    ),
    -- Reservas futuras (Amanhã e Depois de Amanhã)
    (
        4, -- LAB-01
        6, -- Aluno Carlos Eduardo (Reserva futura #1 de 3)
        tstzrange(
            ((CURRENT_DATE + 1) + TIME '14:00') AT TIME ZONE 'America/Sao_Paulo',
            ((CURRENT_DATE + 1) + TIME '16:00') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Projeto em Dupla — Testes de Triggers e Functions',
        10
    ),
    (
        3, -- A-201 (Sala de Reunião)
        7, -- Aluna Fernanda
        tstzrange(
            ((CURRENT_DATE + 1) + TIME '10:00') AT TIME ZONE 'America/Sao_Paulo',
            ((CURRENT_DATE + 1) + TIME '11:30') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Reunião do Grupo de Estudos de Bancos de Dados',
        8
    ),
    (
        7, -- AUD-01
        1, -- Profa. Helena
        tstzrange(
            ((CURRENT_DATE + 2) + TIME '18:00') AT TIME ZONE 'America/Sao_Paulo',
            ((CURRENT_DATE + 2) + TIME '21:00') AT TIME ZONE 'America/Sao_Paulo',
            '[)'
        ),
        'ATIVA',
        'Seminário de Engenharia de Dados e Concorrência',
        120
    );

-- Atualizar a Materialized View após o seed inicial
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ocupacao_mensal;
