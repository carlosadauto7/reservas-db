-- ============================================================================
-- A2. CONSTRAINT EXCLUDE (Anti-conflito de horário)
-- ============================================================================
-- Habilita btree_gist para combinar igualdade escalar (sala_id WITH =)
-- com interseção de intervalo temporal (periodo WITH &&) em um índice GiST
-- parcial (apenas onde status = 'ATIVA').
--
-- Como tstzrange é semiaberto '[)' por padrão:
--   [10:00, 11:00) && [11:00, 12:00) -> FALSE (adjacentes NÃO conflitam)
--   [10:00, 11:00) && [10:30, 11:30) -> TRUE  (sobrepostas falham!)
--   Reservas com status = 'CANCELADA' ficam fora do predicado WHERE,
--   liberando o horário para novas reservas.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE reserva
    ADD CONSTRAINT ex_reserva_conflito_horario
    EXCLUDE USING gist (
        sala_id WITH =,
        periodo WITH &&
    )
    WHERE (status = 'ATIVA');
