"""Teste de integração do painel contra um banco de verdade.

Pula sozinho se GUARDA_DSN não estiver definida, então roda junto com os
outros sem incomodar quem não tem banco à mão.

    # PostgreSQL
    export GUARDA_DSN="host=127.0.0.1 port=5432 dbname=lojateste user=postgres"
    python -m unittest test_integracao -v

O teste principal aqui é o que fecha o ciclo: desativar pelo painel faz o
banco parar de bloquear, reativar faz voltar a bloquear. É a única forma de
provar que o botão da tela mexe de verdade na proteção.

Cuidado: ele cria e derruba o esquema painel_teste no banco apontado pela
DSN. Aponte para homologação.
"""

import os
import sys
import unittest
from pathlib import Path

import repositorio as repo

DSN = os.environ.get("GUARDA_DSN", "")
ENGINE = os.environ.get("GUARDA_ENGINE", "postgresql")

ESQUEMA = "painel_teste"
TABELA = "movimento"
LINHAS = 3000
LIMITE = 100


@unittest.skipUnless(DSN, "defina GUARDA_DSN para rodar o teste de integração")
@unittest.skipUnless(ENGINE.startswith("postgres"), "por enquanto só PostgreSQL")
class TestIntegracaoPostgres(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import psycopg

        cls.psycopg = psycopg
        # autocommit=False de propósito: guarda.manutencao() vale só na
        # transação atual, então com autocommit cada DDL perderia a liberação
        # e o próprio guard bloquearia a preparação do teste
        cls.conexao = psycopg.connect(DSN, autocommit=False)

        with cls.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute(f"drop schema if exists {ESQUEMA} cascade")
            cur.execute(f"create schema {ESQUEMA}")
            cur.execute(
                f"create table {ESQUEMA}.{TABELA} "
                "(id integer primary key, valor numeric(10,2) default 10)"
            )
            cur.execute(
                f"insert into {ESQUEMA}.{TABELA} (id) "
                f"select g from generate_series(1, {LINHAS}) g"
            )
            cur.execute("select guarda.instalar(%s, %s)", (ESQUEMA, TABELA))
            cur.execute(
                """
                insert into guarda.politica (esquema, tabela, limite_delete, limite_update)
                values (%s, %s, %s, %s)
                on conflict (esquema, tabela) do update
                   set limite_delete = excluded.limite_delete,
                       limite_update = excluded.limite_update,
                       ativo = true
                """,
                (ESQUEMA, TABELA, LIMITE, LIMITE),
            )
            # linhas_estimadas vem de pg_class.reltuples, que só existe
            # depois de um ANALYZE
            cur.execute(f"analyze {ESQUEMA}.{TABELA}")
        cls.conexao.commit()

    @classmethod
    def tearDownClass(cls):
        with cls.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute("delete from guarda.politica where esquema = %s", (ESQUEMA,))
            cur.execute("delete from guarda.evento where esquema = %s", (ESQUEMA,))
            cur.execute(f"drop schema if exists {ESQUEMA} cascade")
        cls.conexao.commit()
        cls.conexao.close()

    def setUp(self):
        self.repositorio = repo.RepositorioPostgres.conectar(DSN)

    def tearDown(self):
        self.repositorio.fechar()

    # -- utilidades -------------------------------------------------------
    def _tentar_delete_grande(self) -> bool:
        """Devolve True se o DELETE passou. Sempre desfaz no fim."""
        with self.psycopg.connect(DSN, autocommit=False) as conexao:
            try:
                with conexao.cursor() as cur:
                    cur.execute(f"delete from {ESQUEMA}.{TABELA} where valor > 0")
                passou = True
            except self.psycopg.errors.RaiseException as e:
                self.assertIn("GUARDA", str(e))
                passou = False
            conexao.rollback()
        return passou

    def _politica(self) -> repo.Tabela:
        return next(
            t for t in self.repositorio.tabelas()
            if t.esquema == ESQUEMA and t.tabela == TABELA
        )

    # -- leitura ----------------------------------------------------------
    def test_le_config_do_banco(self):
        config = self.repositorio.config()
        self.assertIn("limite_delete_padrao", config)
        self.assertIn("ambiente", config)

    def test_le_a_tabela_com_a_politica(self):
        tabela = self._politica()
        self.assertTrue(tabela.instalada)
        self.assertTrue(tabela.ativo)
        self.assertEqual(tabela.limite_delete, LIMITE)
        self.assertGreater(tabela.linhas_estimadas, 0)

    def test_le_eventos(self):
        self.assertIsInstance(self.repositorio.eventos(5), list)

    # -- o ciclo que importa ----------------------------------------------
    def test_ciclo_desativar_e_reativar_muda_o_comportamento_do_banco(self):
        # 1. protegida: o DELETE grande é bloqueado
        self.assertFalse(
            self._tentar_delete_grande(),
            "com a proteção ativa o DELETE deveria ter sido bloqueado",
        )

        # 2. o painel desativa
        self.repositorio.salvar_tabela(
            esquema=ESQUEMA, tabela=TABELA, ativo=False,
            limite_delete=LIMITE, limite_update=LIMITE,
            motivo="carga noturna de movimento, OS-4821", quem="teste-integracao",
        )
        self.assertFalse(self._politica().ativo)

        # 3. agora o mesmo DELETE passa
        self.assertTrue(
            self._tentar_delete_grande(),
            "com a proteção desativada o DELETE deveria ter passado",
        )

        # 4. o painel reativa
        self.repositorio.salvar_tabela(
            esquema=ESQUEMA, tabela=TABELA, ativo=True,
            limite_delete=LIMITE, limite_update=LIMITE,
            motivo="carga terminou, proteção de volta OS-4821", quem="teste-integracao",
        )
        self.assertTrue(self._politica().ativo)

        # 5. e volta a bloquear
        self.assertFalse(
            self._tentar_delete_grande(),
            "depois de reativar o DELETE deveria ser bloqueado de novo",
        )

    def test_toda_mudanca_fica_na_auditoria(self):
        self.repositorio.salvar_tabela(
            esquema=ESQUEMA, tabela=TABELA, ativo=False,
            limite_delete=LIMITE, limite_update=LIMITE,
            motivo="conferindo a trilha de auditoria, OS-4900", quem="fulano",
        )
        try:
            evento = self.repositorio.eventos(5)[0]
            self.assertEqual(evento.resultado, "configuracao")
            self.assertEqual(evento.comando, "PAINEL DESATIVOU")
            self.assertEqual(evento.tabela, TABELA)
            self.assertEqual(evento.justificativa, "conferindo a trilha de auditoria, OS-4900")
            self.assertEqual(evento.usuario, "fulano")
            self.assertEqual(evento.aplicacao, "guarda-painel")
        finally:
            self.repositorio.salvar_tabela(
                esquema=ESQUEMA, tabela=TABELA, ativo=True,
                limite_delete=LIMITE, limite_update=LIMITE,
                motivo="restaurando estado do teste, OS-4900", quem="fulano",
            )

    def test_motivo_curto_nao_chega_no_banco(self):
        with self.assertRaises(repo.ErroDeUso):
            self.repositorio.salvar_tabela(
                esquema=ESQUEMA, tabela=TABELA, ativo=False,
                limite_delete=None, limite_update=None,
                motivo="agora", quem="teste",
            )
        self.assertTrue(self._politica().ativo, "nada deveria ter mudado")

    def test_limite_por_tabela_vale_mais_que_o_global(self):
        self.repositorio.salvar_tabela(
            esquema=ESQUEMA, tabela=TABELA, ativo=True,
            limite_delete=LINHAS + 1000, limite_update=LIMITE,
            motivo="subindo limite para conferir precedencia", quem="teste",
        )
        try:
            self.assertTrue(
                self._tentar_delete_grande(),
                "com limite acima do total de linhas o DELETE deveria passar",
            )
        finally:
            self.repositorio.salvar_tabela(
                esquema=ESQUEMA, tabela=TABELA, ativo=True,
                limite_delete=LIMITE, limite_update=LIMITE,
                motivo="devolvendo o limite original do teste", quem="teste",
            )

    def test_config_global_muda_de_verdade(self):
        original = self.repositorio.config()["registrar_acima_de"]
        try:
            self.repositorio.salvar_config(
                "registrar_acima_de", "250",
                "ajuste de ruido na auditoria, OS-4900", "teste",
            )
            self.assertEqual(self.repositorio.config()["registrar_acima_de"], "250")
        finally:
            self.repositorio.salvar_config(
                "registrar_acima_de", original,
                "devolvendo o valor original do teste", "teste",
            )


@unittest.skipUnless(DSN, "defina GUARDA_DSN para rodar o teste de integração")
@unittest.skipUnless(ENGINE.startswith("postgres"), "por enquanto só PostgreSQL")
class TestWatchdog(unittest.TestCase):
    """A promessa é: depois de ligado, continua ligado até uma pessoa desligar.

    Quem sustenta isso quando alguém remove a trigger na marra é o
    ferramentas/rearmar.py. Estes testes derrubam a proteção de propósito e
    conferem que ela volta, e que o watchdog respeita quem foi desligado
    de propósito.
    """

    @classmethod
    def setUpClass(cls):
        import psycopg

        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "ferramentas"))
        import rearmar

        cls.rearmar = rearmar
        cls.psycopg = psycopg
        cls.conexao = psycopg.connect(DSN, autocommit=False)

        with cls.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute(f"drop schema if exists {ESQUEMA}_wd cascade")
            cur.execute(f"create schema {ESQUEMA}_wd")
            cur.execute(
                f"create table {ESQUEMA}_wd.{TABELA} "
                "(id integer primary key, valor numeric(10,2) default 10)"
            )
            cur.execute(
                f"insert into {ESQUEMA}_wd.{TABELA} (id) "
                f"select g from generate_series(1, {LINHAS}) g"
            )
            cur.execute("select guarda.instalar(%s, %s)", (f"{ESQUEMA}_wd", TABELA))
            cur.execute(f"analyze {ESQUEMA}_wd.{TABELA}")
        cls.conexao.commit()

    @classmethod
    def tearDownClass(cls):
        with cls.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute("delete from guarda.politica where esquema = %s", (f"{ESQUEMA}_wd",))
            cur.execute("delete from guarda.evento where esquema = %s", (f"{ESQUEMA}_wd",))
            cur.execute("delete from guarda.evento where aplicacao = 'guarda-rearmar'")
            cur.execute(f"drop schema if exists {ESQUEMA}_wd cascade")
        cls.conexao.commit()
        cls.conexao.close()

    def setUp(self):
        """Cada teste começa com a proteção armada e ativa.

        Sem isto os testes dependeriam da ordem em que o unittest resolve
        rodá-los, que é alfabética e pode mudar.
        """
        with self.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute("select guarda.instalar(%s, %s)", (f"{ESQUEMA}_wd", TABELA))
            cur.execute(
                """
                insert into guarda.politica (esquema, tabela, ativo)
                values (%s, %s, true)
                on conflict (esquema, tabela) do update set ativo = true
                """,
                (f"{ESQUEMA}_wd", TABELA),
            )
            cur.execute("delete from guarda.evento where aplicacao = 'guarda-rearmar'")
        self.conexao.commit()

    # -- utilidades -------------------------------------------------------
    def _vigia(self):
        vigia, repositorio = self.rearmar.criar_vigia("postgresql", DSN)
        return vigia, repositorio

    def _derrubar_protecao(self):
        with self.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            cur.execute(
                f"drop trigger guarda_conta_delete on {ESQUEMA}_wd.{TABELA}"
            )
            cur.execute(
                f"drop trigger guarda_ini_delete on {ESQUEMA}_wd.{TABELA}"
            )
        self.conexao.commit()

    def _delete_grande_passa(self) -> bool:
        with self.psycopg.connect(DSN, autocommit=False) as conexao:
            try:
                with conexao.cursor() as cur:
                    cur.execute(f"delete from {ESQUEMA}_wd.{TABELA} where valor > 0")
                passou = True
            except self.psycopg.errors.RaiseException:
                passou = False
            conexao.rollback()
        return passou

    # -- testes -----------------------------------------------------------
    def test_estado_integro_nao_acusa_nada(self):
        vigia, repositorio = self._vigia()
        try:
            self.assertEqual(vigia.conferir(), [])
        finally:
            repositorio.fechar()

    def test_watchdog_devolve_a_protecao_removida(self):
        self.assertFalse(self._delete_grande_passa(), "deveria estar protegida")

        self._derrubar_protecao()
        self.assertTrue(self._delete_grande_passa(),
                        "sem trigger, o DELETE grande deveria passar")

        vigia, repositorio = self._vigia()
        try:
            achados = vigia.conferir()
            self.assertEqual(len(achados), 1)
            self.assertEqual(achados[0].tipo, "tabela sem trigger")
            vigia.corrigir(achados)
            self.assertTrue(achados[0].corrigido)
        finally:
            repositorio.fechar()

        self.assertFalse(self._delete_grande_passa(),
                         "depois do rearme o DELETE grande tem que voltar a ser bloqueado")

    def test_modo_conferir_nao_altera_nada(self):
        self._derrubar_protecao()
        try:
            codigo = self.rearmar.main(
                ["--engine", "postgresql", "--dsn", DSN, "--conferir"]
            )
            self.assertEqual(codigo, 1, "achou problema, entao sai com 1")
            self.assertTrue(self._delete_grande_passa(),
                            "--conferir nao pode ter consertado")
        finally:
            self.rearmar.main(["--engine", "postgresql", "--dsn", DSN, "--silencioso"])

    def test_nao_religa_o_que_foi_desligado_de_proposito(self):
        repositorio = self.rearmar.repo.RepositorioPostgres.conectar(DSN)
        try:
            repositorio.salvar_tabela(
                esquema=f"{ESQUEMA}_wd", tabela=TABELA, ativo=False,
                limite_delete=None, limite_update=None,
                motivo="carga noturna, desligado de proposito OS-5000", quem="gestor",
            )

            self.assertTrue(self._delete_grande_passa(),
                            "desligado pelo painel, o DELETE grande passa")

            codigo = self.rearmar.main(["--engine", "postgresql", "--dsn", DSN])
            self.assertEqual(codigo, 0, "nao ha buraco: a trigger continua instalada")

            alvo = next(t for t in repositorio.tabelas()
                        if t.esquema == f"{ESQUEMA}_wd" and t.tabela == TABELA)
            self.assertFalse(alvo.ativo, "o watchdog nao pode religar sozinho")
            self.assertTrue(alvo.instalada, "a trigger tem que continuar instalada")
        finally:
            repositorio.salvar_tabela(
                esquema=f"{ESQUEMA}_wd", tabela=TABELA, ativo=True,
                limite_delete=None, limite_update=None,
                motivo="devolvendo o estado do teste automatizado", quem="teste",
            )
            repositorio.fechar()

    def test_saida_zero_quando_esta_tudo_certo(self):
        codigo = self.rearmar.main(
            ["--engine", "postgresql", "--dsn", DSN, "--silencioso"]
        )
        self.assertEqual(codigo, 0)

    def test_registra_na_auditoria_o_que_consertou(self):
        # o setUp acabou de limpar os eventos do watchdog, entao o que
        # aparecer aqui foi este teste que gerou
        self._derrubar_protecao()
        self.rearmar.main(["--engine", "postgresql", "--dsn", DSN, "--silencioso"])

        with self.psycopg.connect(DSN) as conexao:
            with conexao.cursor() as cur:
                cur.execute(
                    """
                    select comando, justificativa, aplicacao
                      from guarda.evento
                     where aplicacao = 'guarda-rearmar'
                     order by id desc limit 1
                    """
                )
                linha = cur.fetchone()

        self.assertIsNotNone(linha, "o watchdog tem que deixar rastro")
        self.assertEqual(linha[0], "WATCHDOG CORRIGIU")
        self.assertIn(TABELA, linha[1])


if __name__ == "__main__":
    unittest.main()
