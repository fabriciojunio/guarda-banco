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
import unittest

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


if __name__ == "__main__":
    unittest.main()
