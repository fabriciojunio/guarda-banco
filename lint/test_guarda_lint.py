"""Testes do guarda_lint.

    python -m unittest discover -s lint -v
"""

import unittest

from guarda_lint import ERRO, analisar, limpar


def regras(sql: str) -> set[str]:
    return {a.regra for a in analisar(sql)}


def erros(sql: str) -> set[str]:
    return {a.regra for a in analisar(sql) if a.severidade == ERRO}


class TestLimpeza(unittest.TestCase):
    def test_comentario_de_linha_nao_conta(self):
        sql = "-- delete from cliente\nselect 1;"
        self.assertEqual(regras(sql), set())

    def test_comentario_de_bloco_nao_conta(self):
        sql = "/* delete from cliente */ select 1;"
        self.assertEqual(regras(sql), set())

    def test_literal_nao_conta(self):
        sql = "insert into log (texto) values ('delete from cliente');"
        self.assertEqual(regras(sql), set())

    def test_limpeza_preserva_numero_de_linhas(self):
        sql = "-- comentario\n/* bloco\nem duas linhas */\ndelete from cliente;"
        limpo = limpar(sql)
        self.assertEqual(limpo.count("\n"), sql.count("\n"))
        achado = analisar(sql)[0]
        self.assertEqual(achado.linha, 4)

    def test_corpo_de_funcao_com_dollar_quoting_e_ignorado(self):
        sql = (
            "create function f() returns void as $$\n"
            "begin\n"
            "  delete from cliente;\n"
            "end;\n"
            "$$ language plpgsql;"
        )
        self.assertEqual(regras(sql), set())


class TestVolume(unittest.TestCase):
    def test_delete_sem_where(self):
        self.assertIn("delete-sem-where", erros("delete from cliente;"))

    def test_delete_com_where_passa(self):
        self.assertEqual(erros("delete from cliente where id = 7;"), set())

    def test_delete_mysql_com_modificadores(self):
        self.assertIn("delete-sem-where", erros("delete low_priority quick from cliente;"))

    def test_update_sem_where(self):
        self.assertIn("update-sem-where", erros("update cliente set ativo = false;"))

    def test_update_com_where_passa(self):
        self.assertEqual(erros("update cliente set ativo = false where id = 7;"), set())

    def test_truncate_gera_aviso_nao_erro(self):
        achados = analisar("begin; truncate table cliente; commit;")
        self.assertIn("truncate", {a.regra for a in achados})
        self.assertEqual(erros("begin; truncate table cliente; commit;"), set())


class TestFiltroErrado(unittest.TestCase):
    def test_igual_null(self):
        self.assertIn("comparacao-com-null", erros("delete from cliente where email = null;"))

    def test_diferente_null(self):
        self.assertIn("comparacao-com-null", erros("update cliente set x = 1 where y != null;"))

    def test_is_null_passa(self):
        self.assertEqual(erros("delete from cliente where email is null;"), set())

    def test_atribuir_null_no_set_e_legitimo(self):
        sql = "update cliente set email = null where id = 7;"
        self.assertNotIn("comparacao-com-null", erros(sql))

    def test_atribuir_null_no_set_e_comparar_no_where(self):
        sql = "update cliente set email = null where telefone = null;"
        self.assertIn("comparacao-com-null", erros(sql))

    def test_or_com_and_sem_parenteses(self):
        sql = "delete from pedido where cliente_id = 10 and status = 'x' or status = 'y';"
        self.assertIn("or-sem-parenteses", erros(sql))

    def test_or_com_parenteses_nao_reprova(self):
        sql = "delete from pedido where cliente_id = 10 and (status = 'x' or status = 'y');"
        self.assertNotIn("or-sem-parenteses", erros(sql))

    def test_where_sempre_verdadeiro(self):
        self.assertIn("where-sempre-verdadeiro", erros("delete from cliente where 1=1;"))

    def test_update_from_sem_juncao(self):
        sql = "update pedido set total = item.valor from item;"
        self.assertIn("update-from-sem-juncao", erros(sql))

    def test_update_from_com_where_passa(self):
        sql = "update pedido set total = item.valor from item where item.pedido_id = pedido.id;"
        self.assertNotIn("update-from-sem-juncao", erros(sql))

    def test_not_in_subconsulta_avisa(self):
        sql = "delete from cliente where id not in (select cliente_id from pedido);"
        self.assertIn("not-in-subconsulta", regras(sql))

    def test_limit_sem_order_by(self):
        self.assertIn("limit-sem-order-by", regras("delete from fila where lido = 1 limit 100;"))

    def test_limit_com_order_by_passa(self):
        sql = "delete from fila where lido = 1 order by id limit 100;"
        self.assertNotIn("limit-sem-order-by", regras(sql))


class TestEstrutura(unittest.TestCase):
    def test_drop_table(self):
        self.assertIn("drop-destrutivo", regras("begin; drop table cliente; commit;"))

    def test_drop_column(self):
        self.assertIn("drop-destrutivo", regras("begin; alter table cliente drop column cpf; commit;"))

    def test_ddl_destrutivo_sem_transacao_avisa(self):
        self.assertIn("ddl-sem-transacao", regras("drop table cliente;"))

    def test_ddl_destrutivo_com_transacao_nao_avisa(self):
        self.assertNotIn("ddl-sem-transacao", regras("begin;\ndrop table cliente;\ncommit;"))

    def test_tipo_reduzido_avisa(self):
        sql = "begin; alter table cliente alter column nome type varchar(50); commit;"
        self.assertIn("tipo-reduzido", regras(sql))

    def test_desativa_fk_checks(self):
        self.assertIn("desativa-integridade", erros("set foreign_key_checks = 0;"))

    def test_desativa_trigger(self):
        self.assertIn("desativa-integridade", erros("alter table cliente disable trigger all;"))

    def test_session_replication_role(self):
        self.assertIn("desativa-integridade", erros("set session_replication_role = 'replica';"))

    def test_session_replication_role_em_comentario_nao_conta(self):
        sql = "-- nunca faca set session_replication_role = 'replica'\nselect 1;"
        self.assertEqual(erros(sql), set())

    def test_session_replication_role_dentro_de_literal_nao_conta(self):
        sql = "insert into doc (texto) values ('set session_replication_role = replica');"
        self.assertEqual(erros(sql), set())


class TestSilenciamento(unittest.TestCase):
    def test_ignorar_na_linha_anterior(self):
        sql = (
            "-- guarda-lint: ignorar delete-sem-where (expurgo aprovado no OS-4821)\n"
            "delete from tabela_temporaria;"
        )
        self.assertEqual(erros(sql), set())

    def test_ignorar_na_mesma_linha(self):
        sql = "delete from tmp; -- guarda-lint: ignorar delete-sem-where (tabela de apoio, OS-4821)"
        self.assertEqual(erros(sql), set())

    def test_ignorar_sem_motivo_nao_vale(self):
        sql = "-- guarda-lint: ignorar delete-sem-where\ndelete from cliente;"
        self.assertIn("delete-sem-where", erros(sql))

    def test_ignorar_nao_afeta_outra_regra(self):
        sql = (
            "-- guarda-lint: ignorar delete-sem-where (motivo suficiente aqui)\n"
            "delete from cliente where email = null;"
        )
        self.assertIn("comparacao-com-null", erros(sql))


class TestArquivoRealista(unittest.TestCase):
    MIGRACAO = """
-- migracao 0042: limpeza de clientes inativos
begin;

-- ok: filtro fechado
delete from cliente
 where ativo = false
   and ultimo_acesso < '2024-01-01';

-- erro classico: colou a linha e o where ficou fora
update cliente
   set email = null;

-- erro de comparacao
delete from contato where email = null;

commit;
"""

    def test_encontra_os_dois_problemas_e_ignora_o_comando_correto(self):
        achados = analisar(self.MIGRACAO, "0042_limpeza.sql")
        nomes = {a.regra for a in achados}
        self.assertEqual(nomes, {"update-sem-where", "comparacao-com-null"})

    def test_reporta_a_linha_certa(self):
        achados = {a.regra: a.linha for a in analisar(self.MIGRACAO, "0042_limpeza.sql")}
        linhas = self.MIGRACAO.splitlines()
        self.assertTrue(linhas[achados["update-sem-where"] - 1].strip().startswith("update cliente"))
        self.assertIn("email = null", linhas[achados["comparacao-com-null"] - 1])


if __name__ == "__main__":
    unittest.main()
