#!/usr/bin/env python3
"""Watchdog: garante que a proteção continue ligada.

Depois de instalado, o guard tem que ficar ligado sozinho até alguém
desligar de propósito. Em PostgreSQL e SQL Server isso já acontece dentro
do banco, porque existe trigger de DDL que adota tabela nova na hora. No
MySQL não existe trigger de DDL, e pior, o MySQL não aceita CREATE TRIGGER
em prepared statement, então nenhuma rotina dentro do banco consegue se
rearmar. Daí este programa, que roda de fora.

    python ferramentas/rearmar.py --engine mysql --conferir     # só olha
    python ferramentas/rearmar.py --engine mysql                # olha e conserta

Regra que não se quebra: tabela desligada de propósito continua desligada.
O watchdog devolve a trigger que sumiu, mas nunca mexe em
guarda.politica.ativo. Quem desligou pelo painel foi uma pessoa, e só uma
pessoa religa.

Código de saída, pensado para monitoramento:

    0  estava tudo certo, nada a fazer
    1  havia buraco e foi corrigido (ou, com --conferir, apenas encontrado)
    2  erro de conexão ou de permissão

Para deixar rodando de tempos em tempos, ver docs/operacao.md.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "painel"))

import repositorio as repo  # noqa: E402

SISTEMAS = ("mysql", "information_schema", "performance_schema", "sys", "guarda")


class Achado:
    def __init__(self, tipo: str, alvo: str, detalhe: str) -> None:
        self.tipo = tipo
        self.alvo = alvo
        self.detalhe = detalhe
        self.corrigido = False

    def __str__(self) -> str:
        marca = "corrigido" if self.corrigido else "PENDENTE "
        return f"  [{marca}] {self.tipo}: {self.alvo}\n              {self.detalhe}"


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
class VigiaPostgres:
    engine = "postgresql"

    def __init__(self, conexao):
        self.conexao = conexao

    def conferir(self) -> list[Achado]:
        achados: list[Achado] = []
        with self.conexao.cursor() as cur:
            cur.execute("select esquema, tabela from guarda.sem_protecao")
            for esquema, tabela in cur.fetchall():
                achados.append(Achado(
                    "tabela sem trigger", f"{esquema}.{tabela}",
                    "criada fora do alcance do event trigger, ou trigger removida",
                ))

            cur.execute("""
                select evtname, evtenabled
                  from pg_event_trigger
                 where evtname like 'guarda\\_%'
            """)
            presentes = {nome: estado for nome, estado in cur.fetchall()}
            for esperado in ("guarda_et_create", "guarda_et_drop", "guarda_et_alter"):
                if esperado not in presentes:
                    achados.append(Achado(
                        "event trigger sumiu", esperado,
                        "sem ele o banco para de adotar tabela nova e de barrar DDL",
                    ))
                elif presentes[esperado] == "D":
                    achados.append(Achado(
                        "event trigger desativado", esperado,
                        "está instalado mas desabilitado",
                    ))

            cur.execute("""
                select c.relname
                  from pg_class c
                  join pg_namespace n on n.oid = c.relnamespace
                  join pg_trigger t on t.tgrelid = c.oid
                 where t.tgname like 'guarda\\_%'
                   and t.tgenabled = 'D'
                   and not t.tgisinternal
                 group by c.relname
            """)
            for (tabela,) in cur.fetchall():
                achados.append(Achado(
                    "trigger desativada", tabela,
                    "ALTER TABLE ... DISABLE TRIGGER foi aplicado",
                ))
        return achados

    def corrigir(self, achados: list[Achado]) -> None:
        with self.conexao.cursor() as cur:
            cur.execute("select guarda.manutencao()")
            for achado in achados:
                if achado.tipo == "tabela sem trigger":
                    esquema, tabela = achado.alvo.split(".", 1)
                    cur.execute("select guarda.instalar(%s, %s)", (esquema, tabela))
                    achado.corrigido = True
                elif achado.tipo == "trigger desativada":
                    cur.execute(
                        f'alter table "{achado.alvo}" enable trigger user'
                    )
                    achado.corrigido = True
        self.conexao.commit()

    def registrar(self, achados: list[Achado], corrigiu: bool) -> None:
        with self.conexao.cursor() as cur:
            cur.execute(
                """
                insert into guarda.evento
                    (resultado, comando, justificativa, ambiente,
                     usuario, usuario_efetivo, aplicacao)
                values ('configuracao', %s, %s,
                        (select valor from guarda.config where chave = 'ambiente'),
                        %s, current_user, 'guarda-rearmar')
                """,
                (
                    "WATCHDOG CORRIGIU" if corrigiu else "WATCHDOG ENCONTROU",
                    "; ".join(f"{a.tipo}: {a.alvo}" for a in achados)[:1000],
                    os.environ.get("USERNAME") or os.environ.get("USER") or "watchdog",
                ),
            )
        self.conexao.commit()


# ---------------------------------------------------------------------------
# MySQL: o caso que realmente precisa disso
# ---------------------------------------------------------------------------
class VigiaMySQL:
    engine = "mysql"

    def __init__(self, conexao):
        self.conexao = conexao

    def conferir(self) -> list[Achado]:
        achados: list[Achado] = []
        with self.conexao.cursor() as cur:
            cur.execute("select esquema, tabela from guarda.sem_protecao")
            for esquema, tabela in cur.fetchall():
                if len(tabela) + 11 > 64:
                    achados.append(Achado(
                        "nome longo demais", f"{esquema}.{tabela}",
                        "o nome da trigger passaria de 64 caracteres, precisa de apelido manual",
                    ))
                else:
                    achados.append(Achado(
                        "tabela sem trigger", f"{esquema}.{tabela}",
                        "MySQL não adota tabela nova sozinho, por isso este watchdog existe",
                    ))

            cur.execute("select @@GLOBAL.sql_safe_updates")
            if int(cur.fetchone()[0]) != 1:
                achados.append(Achado(
                    "sql_safe_updates desligado", "servidor",
                    "a defesa nativa contra DELETE sem WHERE está fora do ar",
                ))

            cur.execute("select @@GLOBAL.performance_schema")
            if int(cur.fetchone()[0]) != 1:
                achados.append(Achado(
                    "performance_schema desligado", "servidor",
                    "sem ele o contador de linhas não funciona, e isso o watchdog "
                    "não conserta: exige reinício do MySQL",
                ))
        return achados

    def corrigir(self, achados: list[Achado]) -> None:
        with self.conexao.cursor() as cur:
            for achado in achados:
                if achado.tipo == "tabela sem trigger":
                    esquema, tabela = achado.alvo.split(".", 1)
                    for prefixo, evento in (("del", "DELETE"), ("upd", "UPDATE")):
                        # CREATE TRIGGER não pode ir por prepared statement no
                        # MySQL, mas mandar o texto direto pelo cliente funciona
                        cur.execute(
                            f"DROP TRIGGER IF EXISTS `{esquema}`.`guarda_{prefixo}_{tabela}`"
                        )
                        cur.execute(
                            f"CREATE TRIGGER `{esquema}`.`guarda_{prefixo}_{tabela}` "
                            f"BEFORE {evento} ON `{esquema}`.`{tabela}` "
                            f"FOR EACH ROW CALL guarda.checar("
                            f"'{esquema}', '{tabela}', '{evento}')"
                        )
                    achado.corrigido = True

                elif achado.tipo == "sql_safe_updates desligado":
                    cur.execute("SET PERSIST sql_safe_updates = ON")
                    cur.execute("SET GLOBAL sql_safe_updates = ON")
                    achado.corrigido = True
        self.conexao.commit()

    def registrar(self, achados: list[Achado], corrigiu: bool) -> None:
        with self.conexao.cursor() as cur:
            cur.execute(
                """
                insert into guarda.evento
                    (resultado, comando, justificativa, ambiente, usuario, aplicacao)
                values ('configuracao', %s, %s,
                        (select valor from guarda.config where chave = 'ambiente'),
                        %s, 'guarda-rearmar')
                """,
                (
                    "WATCHDOG CORRIGIU" if corrigiu else "WATCHDOG ENCONTROU",
                    "; ".join(f"{a.tipo}: {a.alvo}" for a in achados)[:1000],
                    os.environ.get("USERNAME") or os.environ.get("USER") or "watchdog",
                ),
            )
        self.conexao.commit()


# ---------------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------------
class VigiaSQLServer:
    engine = "sqlserver"

    def __init__(self, conexao):
        self.conexao = conexao

    def conferir(self) -> list[Achado]:
        achados: list[Achado] = []
        with self.conexao.cursor() as cur:
            cur.execute("select esquema, tabela from guarda.sem_protecao")
            for esquema, tabela in cur.fetchall():
                achados.append(Achado(
                    "tabela sem trigger", f"{esquema}.{tabela}",
                    "criada fora do alcance do DDL trigger, ou trigger removida",
                ))

            cur.execute("""
                select name, is_disabled from sys.triggers
                 where parent_class_desc = 'DATABASE' and name like 'guarda[_]%'
            """)
            presentes = {nome: bool(desab) for nome, desab in cur.fetchall()}
            if not presentes:
                achados.append(Achado(
                    "DDL trigger sumiu", "guarda_ddl",
                    "sem ele o banco para de adotar tabela nova e de barrar DROP",
                ))
            for nome, desabilitado in presentes.items():
                if desabilitado:
                    achados.append(Achado("DDL trigger desativado", nome,
                                          "está instalado mas desabilitado"))

            cur.execute("""
                select t.name from sys.triggers t
                 where t.name like 'guarda[_]dml[_]%' and t.is_disabled = 1
            """)
            for (nome,) in cur.fetchall():
                achados.append(Achado("trigger desativada", nome, "DISABLE TRIGGER foi aplicado"))
        return achados

    def corrigir(self, achados: list[Achado]) -> None:
        with self.conexao.cursor() as cur:
            for achado in achados:
                if achado.tipo == "tabela sem trigger":
                    esquema, tabela = achado.alvo.split(".", 1)
                    cur.execute("EXEC guarda.instalar ?, ?", (esquema, tabela))
                    achado.corrigido = True
                elif achado.tipo in ("DDL trigger desativado", "trigger desativada"):
                    cur.execute(f"ENABLE TRIGGER [{achado.alvo}] ON DATABASE")
                    achado.corrigido = True
        self.conexao.commit()

    def registrar(self, achados: list[Achado], corrigiu: bool) -> None:
        with self.conexao.cursor() as cur:
            cur.execute(
                """
                insert into guarda.evento
                    (resultado, comando, justificativa, ambiente,
                     usuario, usuario_efetivo, aplicacao)
                values ('configuracao', ?, ?,
                        (select valor from guarda.config where chave = 'ambiente'),
                        ?, user_name(), 'guarda-rearmar')
                """,
                (
                    "WATCHDOG CORRIGIU" if corrigiu else "WATCHDOG ENCONTROU",
                    "; ".join(f"{a.tipo}: {a.alvo}" for a in achados)[:1000],
                    os.environ.get("USERNAME") or os.environ.get("USER") or "watchdog",
                ),
            )
        self.conexao.commit()


VIGIAS = {
    "postgresql": (VigiaPostgres, repo.RepositorioPostgres),
    "postgres": (VigiaPostgres, repo.RepositorioPostgres),
    "mysql": (VigiaMySQL, repo.RepositorioMySQL),
    "mariadb": (VigiaMySQL, repo.RepositorioMySQL),
    "sqlserver": (VigiaSQLServer, repo.RepositorioSQLServer),
    "mssql": (VigiaSQLServer, repo.RepositorioSQLServer),
}


def criar_vigia(engine: str, dsn: str):
    engine = (engine or "").lower()
    if engine not in VIGIAS:
        raise repo.ErroDeUso(f"Engine desconhecida: {engine}")
    classe_vigia, classe_repo = VIGIAS[engine]
    repositorio = classe_repo.conectar(dsn)
    return classe_vigia(repositorio.conexao), repositorio


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="guarda-rearmar",
        description="Confere se a proteção continua ligada, e devolve o que faltar.",
    )
    ap.add_argument("--engine", required=True, help="postgresql, mysql ou sqlserver")
    ap.add_argument("--dsn", default=None, help="string de conexão, ou use GUARDA_DSN")
    ap.add_argument("--conferir", action="store_true",
                    help="apenas relata, não altera nada")
    ap.add_argument("--silencioso", action="store_true",
                    help="não escreve nada quando está tudo certo")
    args = ap.parse_args(argv)

    for fluxo in (sys.stdout, sys.stderr):
        if hasattr(fluxo, "reconfigure"):
            try:
                fluxo.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass

    dsn = args.dsn or os.environ.get("GUARDA_DSN", "")
    if not dsn:
        print("guarda-rearmar: informe --dsn ou a variável GUARDA_DSN", file=sys.stderr)
        return 2

    try:
        vigia, repositorio = criar_vigia(args.engine, dsn)
    except repo.ErroDeUso as e:
        print(f"guarda-rearmar: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"guarda-rearmar: não consegui conectar: {e}", file=sys.stderr)
        return 2

    try:
        achados = vigia.conferir()

        if not achados:
            if not args.silencioso:
                print("guarda-rearmar: proteção íntegra, nada a fazer.")
            return 0

        print(f"guarda-rearmar: {len(achados)} problema(s) na proteção:")

        if not args.conferir:
            vigia.corrigir(achados)

        for achado in achados:
            print(achado)

        vigia.registrar(achados, corrigiu=not args.conferir)

        pendentes = [a for a in achados if not a.corrigido]
        if pendentes:
            print(f"\n{len(pendentes)} item(ns) exigem uma pessoa. Veja docs/operacao.md.")
        return 1
    except Exception as e:
        print(f"guarda-rearmar: falhou no meio do caminho: {e}", file=sys.stderr)
        return 2
    finally:
        repositorio.fechar()


if __name__ == "__main__":
    sys.exit(main())
