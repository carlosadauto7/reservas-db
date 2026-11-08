"""Componentes de interface Streamlit da camada de apresentação.

Desacoplados do driver de banco de dados: interagem apenas com o serviço
de aplicação (ReservaApplicationService) e tratam DatabaseRuleError.
"""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import streamlit as st

from app.application.use_cases import ReservaApplicationService
from app.domain.entities import (
    CancelarReservaCommand,
    DatabaseRuleError,
    NovaReservaCommand,
)

TZ_SP = ZoneInfo("America/Sao_Paulo")


class StreamlitDashboard:
    """Controlador de interface Streamlit com injeção do serviço."""

    def __init__(self, service: ReservaApplicationService) -> None:
        self._service = service

    def render(self) -> None:
        """Renderiza o cabeçalho e as 5 abas da aplicação."""
        st.set_page_config(
            page_title="Sistema de Reserva de Salas e Laboratórios",
            page_icon="🏛️",
            layout="wide",
        )

        st.title("🏛️ Sistema de Reserva de Salas e Laboratórios")
        st.caption(
            "Aplicação Casca (Task A7 — Clean Architecture) | "
            "Conectada como `app_reservas` | 100% das regras no PostgreSQL."
        )

        (
            tab_agenda,
            tab_criar,
            tab_cancelar,
            tab_relatorio,
            tab_seguranca,
        ) = st.tabs(
            [
                "📅 1. Agenda do Dia (View)",
                "➕ 2. Criar Reserva (Function)",
                "🚫 3. Cancelar Reserva (Function)",
                "📊 4. Ocupação Mensal (MatView)",
                "🔒 5. Prova de Segurança (Role A5)",
            ]
        )

        with tab_agenda:
            self._render_tab_agenda()
        with tab_criar:
            self._render_tab_criar()
        with tab_cancelar:
            self._render_tab_cancelar()
        with tab_relatorio:
            self._render_tab_relatorio()
        with tab_seguranca:
            self._render_tab_seguranca()

    def _render_tab_agenda(self) -> None:
        """Renderiza a aba de consulta à view v_agenda_dia."""
        st.subheader("Agenda do Dia (`v_agenda_dia`)")
        col_data, col_sala = st.columns([1, 2])

        with col_data:
            data_selecionada = st.date_input(
                "Selecione a data",
                value=date.today(),
            )

        try:
            salas_df = self._service.obter_catalogo_salas()
            opcoes_sala: dict[str, int | None] = {"Todas as salas": None}
            for _, row in salas_df.iterrows():
                chave = (
                    f"{row['codigo']} — {row['nome']} "
                    f"({row['bloco_sigla']}, cap. {row['capacidade']})"
                )
                opcoes_sala[chave] = int(row["sala_id"])

            with col_sala:
                sala_label = st.selectbox(
                    "Filtrar por sala",
                    options=list(opcoes_sala.keys()),
                )
                sala_filtro_id = opcoes_sala[sala_label]

            df_agenda = self._service.consultar_agenda_do_dia(
                data_selecionada,
                sala_filtro_id,
            )

            if df_agenda.empty:
                data_fmt = data_selecionada.strftime("%d/%m/%Y")
                st.info(f"Nenhuma reserva ativa encontrada para {data_fmt}.")
            else:
                st.dataframe(
                    df_agenda,
                    use_container_width=True,
                    hide_index=True,
                )

        except DatabaseRuleError as exc:
            st.error(f"Erro retornado pelo banco: {exc}")

    def _render_tab_criar(self) -> None:
        """Renderiza a aba de criação de reserva via criar_reserva."""
        st.subheader("Nova Reserva (`SELECT criar_reserva(...)`)")
        st.markdown(
            "A aplicação **não faz validações em Python**: todos os dados "
            "abaixo são enviados diretamente para `criar_reserva` no SGBD."
        )

        modo_manual = st.checkbox(
            "Modo de teste avançado: digitar IDs manualmente "
            "(para testar IDs inexistentes)",
            value=False,
        )

        try:
            salas_df = self._service.obter_catalogo_salas()
            usuarios_df = self._service.obter_catalogo_usuarios()

            with st.form("form_criar_reserva"):
                col_1, col_2 = st.columns(2)
                with col_1:
                    if modo_manual:
                        p_sala_id = int(
                            st.number_input(
                                "ID da Sala (manual)",
                                value=4,
                                step=1,
                            )
                        )
                    else:
                        mapa_salas = {
                            (
                                f"[ID {row['sala_id']}] {row['codigo']} — "
                                f"{row['nome']} (Cap: {row['capacidade']})"
                            ): int(row["sala_id"])
                            for _, row in salas_df.iterrows()
                        }
                        sala_escolhida = st.selectbox(
                            "Sala / Laboratório",
                            options=list(mapa_salas.keys()),
                        )
                        p_sala_id = mapa_salas[sala_escolhida]

                    data_res = st.date_input(
                        "Data da Reserva",
                        value=date.today() + timedelta(days=1),
                    )
                    hora_ini = st.time_input(
                        "Hora de Início",
                        value=time(14, 0),
                        step=timedelta(minutes=30),
                    )

                with col_2:
                    if modo_manual:
                        p_usuario_id = int(
                            st.number_input(
                                "ID do Usuário (manual)",
                                value=6,
                                step=1,
                            )
                        )
                    else:
                        mapa_usuarios = {
                            (
                                f"[ID {row['usuario_id']}] {row['nome']} "
                                f"({row['tipo']} - {row['matricula']})"
                            ): int(row["usuario_id"])
                            for _, row in usuarios_df.iterrows()
                        }
                        usuario_escolhido = st.selectbox(
                            "Usuário Solicitante",
                            options=list(mapa_usuarios.keys()),
                        )
                        p_usuario_id = mapa_usuarios[usuario_escolhido]

                    qtd_part = int(
                        st.number_input(
                            "Quantidade de Participantes",
                            value=15,
                            step=1,
                        )
                    )
                    hora_fim = st.time_input(
                        "Hora de Término",
                        value=time(16, 0),
                        step=timedelta(minutes=30),
                    )

                finalidade = st.text_input(
                    "Finalidade da Reserva",
                    value="Monitoria Prática de Banco de Dados",
                )

                submitted = st.form_submit_button(
                    "Confirmar Reserva no Banco",
                    type="primary",
                )

                if submitted:
                    cmd = NovaReservaCommand(
                        sala_id=p_sala_id,
                        usuario_id=p_usuario_id,
                        inicio=datetime.combine(
                            data_res,
                            hora_ini,
                            tzinfo=TZ_SP,
                        ),
                        fim=datetime.combine(
                            data_res,
                            hora_fim,
                            tzinfo=TZ_SP,
                        ),
                        finalidade=finalidade,
                        qtd_participantes=qtd_part,
                    )
                    try:
                        novo_id = self._service.criar_nova_reserva(cmd)
                        st.success(
                            "✅ Reserva criada com sucesso pelo "
                            f"PostgreSQL! ID gerado: **{novo_id}**"
                        )
                    except DatabaseRuleError as exc:
                        st.error(f"❌ Recusado pelo PostgreSQL: {exc}")

        except DatabaseRuleError as exc:
            st.error(f"Erro retornado pelo banco: {exc}")

    def _render_tab_cancelar(self) -> None:
        """Renderiza a aba de cancelamento de reservas."""
        st.subheader(
            "Reservas Ativas Futuras (`v_reservas_usuario`) "
            "e Cancelamento (`cancelar_reserva`)"
        )

        try:
            df_futuras = self._service.listar_reservas_futuras()

            if df_futuras.empty:
                st.info("Não há reservas ativas futuras no momento.")
            else:
                st.dataframe(
                    df_futuras,
                    use_container_width=True,
                    hide_index=True,
                )

            st.divider()
            st.markdown(
                "#### Executar Cancelamento "
                "(`SELECT cancelar_reserva(p_reserva_id, p_usuario_id)`)"
            )
            with st.form("form_cancelar_reserva"):
                col_c1, col_c2 = st.columns(2)
                default_res = (
                    int(df_futuras.iloc[0]["ID Reserva"])
                    if not df_futuras.empty
                    else 1
                )
                default_usu = (
                    int(df_futuras.iloc[0]["ID Usuário"])
                    if not df_futuras.empty
                    else 6
                )
                with col_c1:
                    id_reserva_cancelar = int(
                        st.number_input(
                            "ID da Reserva a cancelar",
                            value=default_res,
                            step=1,
                        )
                    )
                with col_c2:
                    id_usuario_solicitante = int(
                        st.number_input(
                            "ID do Usuário solicitante "
                            "(teste outro ID para ver bloqueio)",
                            value=default_usu,
                            step=1,
                        )
                    )

                btn_cancelar = st.form_submit_button("Solicitar Cancelamento")
                if btn_cancelar:
                    cmd = CancelarReservaCommand(
                        reserva_id=id_reserva_cancelar,
                        usuario_id=id_usuario_solicitante,
                    )
                    try:
                        self._service.cancelar_reserva_existente(cmd)
                        st.success(
                            f"✅ Reserva #{id_reserva_cancelar} alterada "
                            "para CANCELADA com sucesso! O horário já "
                            "está livre e o evento foi registrado em "
                            "`log_reserva`."
                        )
                    except DatabaseRuleError as exc:
                        st.error(f"❌ Recusado pelo PostgreSQL: {exc}")

        except DatabaseRuleError as exc:
            st.error(f"Erro retornado pelo banco: {exc}")

    def _render_tab_relatorio(self) -> None:
        """Renderiza a aba do relatório mensal via mv_ocupacao_mensal."""
        st.subheader("Relatório Mensal de Ocupação (`mv_ocupacao_mensal`)")

        col_btn, _ = st.columns([1, 3])
        with col_btn:
            if st.button("🔄 Atualizar Materialized View (CONCURRENTLY)"):
                try:
                    self._service.atualizar_relatorio_mensal()
                    st.success(
                        "`REFRESH MATERIALIZED VIEW CONCURRENTLY "
                        "mv_ocupacao_mensal` executado com sucesso!"
                    )
                except DatabaseRuleError as exc:
                    st.error(f"Erro ao atualizar Materialized View: {exc}")

        try:
            opcoes_mes = self._service.listar_meses_relatorio()
            mes_escolhido = st.selectbox(
                "Filtrar por Mês de Referência "
                "(Dica: `2026-09` tem ocupação exata de 10.00% em A-101)",
                options=opcoes_mes,
            )

            df_mv = self._service.consultar_relatorio_mensal(mes_escolhido)
            st.dataframe(df_mv, use_container_width=True, hide_index=True)

        except DatabaseRuleError as exc:
            st.error(f"Erro retornado pelo banco: {exc}")

    def _render_tab_seguranca(self) -> None:
        """Renderiza a aba de demonstração de bloqueio de acesso (A5)."""
        st.subheader(
            "Verificação de Permissões da Role `app_reservas` (Task A5)"
        )
        st.markdown(
            "Conectado como `app_reservas`, qualquer tentativa de acessar "
            "diretamente as tabelas (`reserva`, `usuario`, `sala`, "
            "`log_reserva`) deve falhar com erro de permissão, enquanto o "
            "uso das Views e Functions `SECURITY DEFINER` é permitido."
        )

        col_s1, col_s2 = st.columns(2)
        with col_s1:
            if st.button("Testar `SELECT * FROM reserva` (Tabela Base)"):
                try:
                    self._service.testar_bloqueio_tabela_base("reserva")
                    st.warning("A consulta passou (inesperado)!")
                except DatabaseRuleError as exc:
                    st.error(f"🔒 Bloqueado pelo SGBD (Esperado!): {exc}")

        with col_s2:
            if st.button("Testar `SELECT * FROM log_reserva` (Auditoria)"):
                try:
                    self._service.testar_bloqueio_tabela_base("log_reserva")
                    st.warning("A consulta passou (inesperado)!")
                except DatabaseRuleError as exc:
                    st.error(f"🔒 Bloqueado pelo SGBD (Esperado!): {exc}")
