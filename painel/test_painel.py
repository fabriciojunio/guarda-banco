"""Testes do painel.

Sobem o servidor de verdade numa porta livre, com o repositório de
memória, e conversam com ele por HTTP. Não precisa de banco.

    python -m unittest test_painel -v
"""

import json
import threading
import unittest
import urllib.error
import urllib.request

import repositorio as repo
from servidor import criar_servidor


class TestValidacoes(unittest.TestCase):
    def test_motivo_curto_e_recusado(self):
        with self.assertRaises(repo.ErroDeUso):
            repo.validar_motivo("curto")

    def test_motivo_vazio_e_recusado(self):
        for valor in (None, "", "   "):
            with self.assertRaises(repo.ErroDeUso):
                repo.validar_motivo(valor)

    def test_motivo_com_espaco_nao_engana_o_minimo(self):
        with self.assertRaises(repo.ErroDeUso):
            repo.validar_motivo("   oi    ")

    def test_motivo_bom_volta_limpo(self):
        self.assertEqual(repo.validar_motivo("  expurgo LGPD OS-4821  "),
                         "expurgo LGPD OS-4821")

    def test_limite_vazio_vira_none(self):
        self.assertIsNone(repo.validar_limite(None, "x"))
        self.assertIsNone(repo.validar_limite("", "x"))

    def test_limite_negativo_recusado(self):
        with self.assertRaises(repo.ErroDeUso):
            repo.validar_limite(-1, "x")

    def test_limite_absurdo_recusado(self):
        with self.assertRaises(repo.ErroDeUso):
            repo.validar_limite(10**12, "x")

    def test_limite_texto_recusado(self):
        with self.assertRaises(repo.ErroDeUso):
            repo.validar_limite("mil", "x")

    def test_limite_numerico_em_texto_aceito(self):
        self.assertEqual(repo.validar_limite("500", "x"), 500)


class TestRepositorioMemoria(unittest.TestCase):
    def setUp(self):
        self.r = repo.RepositorioMemoria()

    def test_desativar_registra_evento_com_motivo(self):
        self.r.salvar_tabela("public", "cliente", False, None, None,
                             "carga mensal, OS-4821", "maria")
        tabela = next(t for t in self.r.tabelas() if t.tabela == "cliente")
        self.assertFalse(tabela.ativo)

        evento = self.r.eventos()[0]
        self.assertEqual(evento.comando, "PAINEL DESATIVOU")
        self.assertEqual(evento.justificativa, "carga mensal, OS-4821")
        self.assertEqual(evento.usuario, "maria")
        self.assertEqual(evento.resultado, "configuracao")

    def test_tabela_inexistente_da_erro(self):
        with self.assertRaises(repo.ErroDeUso):
            self.r.salvar_tabela("public", "nao_existe", False, None, None,
                                 "motivo suficientemente longo", "maria")

    def test_chave_de_config_fora_da_lista_e_recusada(self):
        with self.assertRaises(repo.ErroDeUso) as ctx:
            self.r.salvar_config("papel_admin", "outro", "motivo suficiente aqui", "maria")
        self.assertIn("não pode ser alterada", str(ctx.exception))

    def test_config_booleana_so_aceita_sim_ou_nao(self):
        with self.assertRaises(repo.ErroDeUso):
            self.r.salvar_config("proteger_ddl", "talvez", "motivo suficiente aqui", "maria")

    def test_config_de_limite_recusa_texto(self):
        with self.assertRaises(repo.ErroDeUso):
            self.r.salvar_config("limite_delete_padrao", "muitas",
                                 "motivo suficiente aqui", "maria")

    def test_config_valida_altera_e_audita(self):
        self.r.salvar_config("limite_delete_padrao", "1000",
                             "volume da tabela de log subiu, OS-4900", "maria")
        self.assertEqual(self.r.config()["limite_delete_padrao"], "1000")
        self.assertIn("limite_delete_padrao=1000", self.r.eventos()[0].comando)

    def test_tabela_sem_trigger_conta_como_desprotegida(self):
        alvo = next(t for t in self.r.tabelas() if t.tabela == "staging_importacao")
        self.assertFalse(alvo.instalada)
        self.assertFalse(alvo.protegida)


class BaseHTTP(unittest.TestCase):
    somente_leitura = False

    def setUp(self):
        self.repositorio = repo.RepositorioMemoria()
        self.servidor = criar_servidor(
            self.repositorio,
            host="127.0.0.1",
            porta=0,
            somente_leitura=self.somente_leitura,
            quem="teste",
        )
        self.porta = self.servidor.server_address[1]
        self.token = self.servidor.estado.token
        self.thread = threading.Thread(target=self.servidor.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.servidor.shutdown()
        self.servidor.server_close()
        self.thread.join(timeout=5)

    def url(self, caminho):
        return f"http://127.0.0.1:{self.porta}{caminho}"

    def get(self, caminho):
        with urllib.request.urlopen(self.url(caminho), timeout=10) as r:
            return r.status, r.read().decode("utf-8"), dict(r.headers)

    def post(self, caminho, corpo, token=None):
        pedido = urllib.request.Request(
            self.url(caminho),
            data=json.dumps(corpo).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        if token is not None:
            pedido.add_header("X-Guarda-Token", token)
        try:
            with urllib.request.urlopen(pedido, timeout=10) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))


class TestLeitura(BaseHTTP):
    def test_pagina_inicial_serve_html_com_token(self):
        status, corpo, cabecalhos = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", cabecalhos["Content-Type"])
        self.assertIn(self.token, corpo)
        self.assertNotIn("{{TOKEN}}", corpo)

    def test_pagina_manda_cabecalhos_de_seguranca(self):
        _, _, cabecalhos = self.get("/")
        self.assertIn("Content-Security-Policy", cabecalhos)
        self.assertEqual(cabecalhos["X-Content-Type-Options"], "nosniff")

    def test_estado_resume_a_situacao(self):
        status, corpo, _ = self.get("/api/estado")
        self.assertEqual(status, 200)
        dados = json.loads(corpo)
        self.assertEqual(dados["engine"], "memoria")
        self.assertEqual(dados["quem"], "teste")
        self.assertFalse(dados["somente_leitura"])
        # a massa de exemplo tem uma desativada e uma sem trigger
        self.assertEqual(dados["resumo"]["total"], 5)
        self.assertEqual(dados["resumo"]["protegidas"], 3)
        self.assertEqual(dados["resumo"]["desativadas"], 1)
        self.assertEqual(dados["resumo"]["sem_trigger"], 1)
        self.assertEqual(dados["resumo"]["situacao"], "parcial")

    def test_tabelas_traz_campo_calculado(self):
        _, corpo, _ = self.get("/api/tabelas")
        tabelas = json.loads(corpo)
        por_nome = {t["tabela"]: t for t in tabelas}
        self.assertTrue(por_nome["cliente"]["protegida"])
        self.assertFalse(por_nome["log_acesso"]["protegida"])
        self.assertFalse(por_nome["staging_importacao"]["protegida"])

    def test_rota_desconhecida_da_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/api/naoexiste")
        self.assertEqual(ctx.exception.code, 404)

    def test_limite_invalido_em_eventos_da_400(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/api/eventos?limite=abc")
        self.assertEqual(ctx.exception.code, 400)


class TestEscrita(BaseHTTP):
    def test_sem_token_recusa(self):
        status, corpo = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False,
            "motivo": "motivo suficientemente longo",
        })
        self.assertEqual(status, 400)
        self.assertIn("Token", corpo["erro"])

    def test_token_errado_recusa(self):
        status, _ = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False,
            "motivo": "motivo suficientemente longo",
        }, token="token-falso")
        self.assertEqual(status, 400)

    def test_motivo_curto_recusa(self):
        status, corpo = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False, "motivo": "urgente",
        }, token=self.token)
        self.assertEqual(status, 400)
        self.assertIn("15 caracteres", corpo["erro"])

    def test_campo_faltando_recusa(self):
        status, corpo = self.post("/api/tabela", {"esquema": "public"}, token=self.token)
        self.assertEqual(status, 400)
        self.assertIn("obrigatório", corpo["erro"])

    def test_desativar_funciona_e_aparece_no_estado(self):
        status, corpo = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False,
            "limite_delete": None, "limite_update": None,
            "motivo": "carga mensal de clientes, OS-4821",
        }, token=self.token)
        self.assertEqual(status, 200)
        self.assertTrue(corpo["ok"])

        _, texto, _ = self.get("/api/estado")
        self.assertEqual(json.loads(texto)["resumo"]["desativadas"], 2)

        _, texto, _ = self.get("/api/eventos")
        evento = json.loads(texto)[0]
        self.assertEqual(evento["comando"], "PAINEL DESATIVOU")
        self.assertEqual(evento["justificativa"], "carga mensal de clientes, OS-4821")
        self.assertEqual(evento["usuario"], "teste")

    def test_reativar_funciona(self):
        self.post("/api/tabela", {
            "esquema": "public", "tabela": "log_acesso", "ativo": True,
            "motivo": "expurgo terminou, protecao de volta",
        }, token=self.token)
        _, texto, _ = self.get("/api/estado")
        self.assertEqual(json.loads(texto)["resumo"]["desativadas"], 0)

    def test_limite_negativo_recusa(self):
        status, corpo = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": True,
            "limite_delete": -5, "motivo": "motivo suficientemente longo",
        }, token=self.token)
        self.assertEqual(status, 400)
        self.assertIn("negativo", corpo["erro"])

    def test_config_protegida_recusa(self):
        status, _ = self.post("/api/config", {
            "chave": "papel_admin", "valor": "root", "motivo": "motivo suficiente aqui",
        }, token=self.token)
        self.assertEqual(status, 400)

    def test_config_valida_aplica(self):
        status, _ = self.post("/api/config", {
            "chave": "limite_delete_padrao", "valor": "1500",
            "motivo": "volume das tabelas de log subiu, OS-4900",
        }, token=self.token)
        self.assertEqual(status, 200)
        _, texto, _ = self.get("/api/estado")
        self.assertEqual(json.loads(texto)["config"]["limite_delete_padrao"], "1500")

    def test_corpo_invalido_da_400(self):
        pedido = urllib.request.Request(
            self.url("/api/tabela"), data=b"nao sou json",
            headers={"Content-Type": "application/json", "X-Guarda-Token": self.token},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(pedido, timeout=10)
        self.assertEqual(ctx.exception.code, 400)


class TestSomenteLeitura(BaseHTTP):
    somente_leitura = True

    def test_estado_avisa_o_modo(self):
        _, corpo, _ = self.get("/api/estado")
        self.assertTrue(json.loads(corpo)["somente_leitura"])

    def test_qualquer_escrita_e_recusada(self):
        status, corpo = self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False,
            "motivo": "motivo suficientemente longo",
        }, token=self.token)
        self.assertEqual(status, 403)
        self.assertIn("somente leitura", corpo["erro"])

    def test_nada_mudou_no_repositorio(self):
        self.post("/api/tabela", {
            "esquema": "public", "tabela": "cliente", "ativo": False,
            "motivo": "motivo suficientemente longo",
        }, token=self.token)
        tabela = next(t for t in self.repositorio.tabelas() if t.tabela == "cliente")
        self.assertTrue(tabela.ativo)


if __name__ == "__main__":
    unittest.main()
