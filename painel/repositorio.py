"""Acesso ao banco para o painel.

Uma classe por engine, porque as consultas de catálogo não são portáveis.
O que é igual em todas fica na classe base.

Nenhuma consulta monta SQL com dado de entrada: tudo por parâmetro. A
única coisa interpolada em texto é nome de esquema e tabela nas consultas
de catálogo, e mesmo esses vão como parâmetro.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Protocol


class ErroDeUso(Exception):
    """Entrada inválida vinda do painel. Vira HTTP 400."""


@dataclass
class Tabela:
    esquema: str
    tabela: str
    instalada: bool
    ativo: bool
    limite_delete: int | None
    limite_update: int | None
    linhas_estimadas: int
    observacao: str | None

    @property
    def protegida(self) -> bool:
        return self.instalada and self.ativo

    def como_dicionario(self) -> dict[str, Any]:
        d = self.__dict__.copy()
        d["protegida"] = self.protegida
        return d


@dataclass
class Evento:
    ocorrido_em: str
    resultado: str
    comando: str
    esquema: str | None
    tabela: str | None
    linhas: int | None
    limite: int | None
    justificativa: str | None
    usuario: str | None
    aplicacao: str | None


MOTIVO_MINIMO = 15


def validar_motivo(motivo: str | None) -> str:
    """Mesma regra do guarda.liberar() no banco.

    Desligar proteção sem explicar é o começo de todo incidente, então o
    painel exige o mesmo que o banco exige.
    """
    limpo = (motivo or "").strip()
    if len(limpo) < MOTIVO_MINIMO:
        raise ErroDeUso(
            f"Informe um motivo com pelo menos {MOTIVO_MINIMO} caracteres "
            "(fica registrado em guarda.evento)."
        )
    return limpo


def validar_limite(valor: Any, nome: str) -> int | None:
    if valor is None or valor == "":
        return None
    try:
        numero = int(valor)
    except (TypeError, ValueError):
        raise ErroDeUso(f"{nome} precisa ser um número inteiro.") from None
    if numero < 0:
        raise ErroDeUso(f"{nome} não pode ser negativo.")
    if numero > 1_000_000_000:
        raise ErroDeUso(f"{nome} está absurdamente alto, confira o valor.")
    return numero


class Repositorio(Protocol):
    engine: str

    def config(self) -> dict[str, str]: ...
    def tabelas(self) -> list[Tabela]: ...
    def eventos(self, limite: int = 100) -> list[Evento]: ...
    def salvar_tabela(
        self,
        esquema: str,
        tabela: str,
        ativo: bool,
        limite_delete: int | None,
        limite_update: int | None,
        motivo: str,
        quem: str,
    ) -> None: ...
    def salvar_config(self, chave: str, valor: str, motivo: str, quem: str) -> None: ...
    def fechar(self) -> None: ...


# ---------------------------------------------------------------------------
# Base com o que não depende de engine
# ---------------------------------------------------------------------------
CHAVES_EDITAVEIS = {
    "limite_delete_padrao",
    "limite_update_padrao",
    "registrar_acima_de",
    "exigir_justificativa",
    "proteger_ddl",
    "ambiente",
    "janela_liberacao_seg",
    "exigir_performance_schema",
}


class RepositorioSQL:
    engine = "?"
    marcador = "%s"

    # cada subclasse define
    SQL_CONFIG = ""
    SQL_TABELAS = ""
    SQL_EVENTOS = ""
    SQL_UPSERT_POLITICA = ""
    SQL_UPDATE_CONFIG = ""
    SQL_INSERT_EVENTO = ""

    def __init__(self, conexao: Any) -> None:
        self.conexao = conexao

    # -- leitura ----------------------------------------------------------
    def config(self) -> dict[str, str]:
        with self.conexao.cursor() as cur:
            cur.execute(self.SQL_CONFIG)
            return {str(linha[0]): str(linha[1]) for linha in cur.fetchall()}

    def tabelas(self) -> list[Tabela]:
        with self.conexao.cursor() as cur:
            cur.execute(self.SQL_TABELAS)
            return [
                Tabela(
                    esquema=str(l[0]),
                    tabela=str(l[1]),
                    instalada=bool(l[2]),
                    ativo=bool(l[3]),
                    limite_delete=None if l[4] is None else int(l[4]),
                    limite_update=None if l[5] is None else int(l[5]),
                    linhas_estimadas=max(int(l[6] or 0), 0),
                    observacao=None if l[7] is None else str(l[7]),
                )
                for l in cur.fetchall()
            ]

    def eventos(self, limite: int = 100) -> list[Evento]:
        limite = max(1, min(int(limite), 500))
        with self.conexao.cursor() as cur:
            cur.execute(self.SQL_EVENTOS.format(limite=limite))
            return [
                Evento(
                    ocorrido_em=str(l[0]),
                    resultado=str(l[1]),
                    comando=str(l[2]),
                    esquema=None if l[3] is None else str(l[3]),
                    tabela=None if l[4] is None else str(l[4]),
                    linhas=None if l[5] is None else int(l[5]),
                    limite=None if l[6] is None else int(l[6]),
                    justificativa=None if l[7] is None else str(l[7]),
                    usuario=None if l[8] is None else str(l[8]),
                    aplicacao=None if l[9] is None else str(l[9]),
                )
                for l in cur.fetchall()
            ]

    # -- escrita ----------------------------------------------------------
    def salvar_tabela(
        self,
        esquema: str,
        tabela: str,
        ativo: bool,
        limite_delete: int | None,
        limite_update: int | None,
        motivo: str,
        quem: str,
    ) -> None:
        motivo = validar_motivo(motivo)
        limite_delete = validar_limite(limite_delete, "Limite de DELETE")
        limite_update = validar_limite(limite_update, "Limite de UPDATE")

        if not esquema or not tabela:
            raise ErroDeUso("Esquema e tabela são obrigatórios.")

        acao = "PAINEL ATIVOU" if ativo else "PAINEL DESATIVOU"

        with self.conexao.cursor() as cur:
            cur.execute(
                self.SQL_UPSERT_POLITICA,
                (esquema, tabela, limite_delete, limite_update, 1 if ativo else 0, motivo),
            )
            cur.execute(
                self.SQL_INSERT_EVENTO,
                (acao, esquema, tabela, limite_delete, motivo, quem),
            )
        self.conexao.commit()

    def salvar_config(self, chave: str, valor: str, motivo: str, quem: str) -> None:
        motivo = validar_motivo(motivo)

        if chave not in CHAVES_EDITAVEIS:
            raise ErroDeUso(f"Chave '{chave}' não pode ser alterada pelo painel.")

        valor = str(valor).strip()
        if not valor:
            raise ErroDeUso("Valor não pode ficar vazio.")
        if len(valor) > 200:
            raise ErroDeUso("Valor longo demais.")

        if chave.startswith("limite_") or chave in ("registrar_acima_de", "janela_liberacao_seg"):
            validar_limite(valor, chave)
        if chave in ("exigir_justificativa", "proteger_ddl", "exigir_performance_schema"):
            if valor not in ("sim", "nao"):
                raise ErroDeUso(f"{chave} aceita apenas 'sim' ou 'nao'.")

        with self.conexao.cursor() as cur:
            cur.execute(self.SQL_UPDATE_CONFIG, (valor, chave))
            if cur.rowcount == 0:
                raise ErroDeUso(f"Chave '{chave}' não existe em guarda.config.")
            cur.execute(
                self.SQL_INSERT_EVENTO,
                (f"PAINEL CONFIG {chave}={valor}", None, None, None, motivo, quem),
            )
        self.conexao.commit()

    def fechar(self) -> None:
        try:
            self.conexao.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
class RepositorioPostgres(RepositorioSQL):
    engine = "postgresql"

    SQL_CONFIG = "select chave, valor from guarda.config order by chave"

    SQL_TABELAS = """
        select n.nspname                          as esquema,
               c.relname                          as tabela,
               exists (select 1 from pg_trigger t
                        where t.tgrelid = c.oid
                          and t.tgname like 'guarda\\_%'
                          and not t.tgisinternal) as instalada,
               coalesce(p.ativo, true)            as ativo,
               p.limite_delete,
               p.limite_update,
               greatest(coalesce(c.reltuples, 0), 0)::bigint as linhas_estimadas,
               p.observacao
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          left join guarda.politica p
                 on p.esquema = n.nspname and p.tabela = c.relname
         where c.relkind in ('r', 'p')
           and not c.relispartition
           and n.nspname not in ('guarda', 'pg_catalog', 'information_schema')
           and n.nspname not like 'pg\\_%'
         order by n.nspname, c.relname
    """

    SQL_EVENTOS = """
        select to_char(ocorrido_em, 'YYYY-MM-DD HH24:MI:SS'),
               resultado, comando, esquema, tabela, linhas, limite,
               justificativa, usuario, aplicacao
          from guarda.evento
         order by ocorrido_em desc
         limit {limite}
    """

    SQL_UPSERT_POLITICA = """
        insert into guarda.politica
            (esquema, tabela, limite_delete, limite_update, ativo, observacao)
        values (%s, %s, %s, %s, %s::int::boolean, %s)
        on conflict (esquema, tabela) do update
           set limite_delete = excluded.limite_delete,
               limite_update = excluded.limite_update,
               ativo         = excluded.ativo,
               observacao    = excluded.observacao
    """

    SQL_UPDATE_CONFIG = "update guarda.config set valor = %s where chave = %s"

    SQL_INSERT_EVENTO = """
        insert into guarda.evento
            (resultado, comando, esquema, tabela, limite, justificativa,
             ambiente, usuario, usuario_efetivo, aplicacao)
        values ('configuracao', %s, %s, %s, %s, %s,
                (select valor from guarda.config where chave = 'ambiente'),
                %s, current_user, 'guarda-painel')
    """

    @classmethod
    def conectar(cls, dsn: str) -> RepositorioPostgres:
        try:
            import psycopg
        except ImportError as e:
            raise ErroDeUso(
                "Driver do PostgreSQL não encontrado. Instale com: "
                "pip install 'psycopg[binary]'"
            ) from e
        return cls(psycopg.connect(dsn, autocommit=False))


# ---------------------------------------------------------------------------
# MySQL e MariaDB
# ---------------------------------------------------------------------------
class RepositorioMySQL(RepositorioSQL):
    engine = "mysql"

    SQL_CONFIG = "select chave, valor from guarda.config order by chave"

    SQL_TABELAS = """
        select t.TABLE_SCHEMA,
               t.TABLE_NAME,
               exists (select 1 from information_schema.TRIGGERS tr
                        where tr.EVENT_OBJECT_SCHEMA = t.TABLE_SCHEMA
                          and tr.EVENT_OBJECT_TABLE  = t.TABLE_NAME
                          and left(tr.TRIGGER_NAME, 7) = 'guarda_'),
               coalesce(p.ativo, 1),
               p.limite_delete,
               p.limite_update,
               coalesce(t.TABLE_ROWS, 0),
               p.observacao
          from information_schema.TABLES t
          left join guarda.politica p
                 on p.esquema = t.TABLE_SCHEMA and p.tabela = t.TABLE_NAME
         where t.TABLE_TYPE = 'BASE TABLE'
           and t.TABLE_SCHEMA not in ('mysql', 'information_schema',
                                      'performance_schema', 'sys', 'guarda')
         order by t.TABLE_SCHEMA, t.TABLE_NAME
    """

    SQL_EVENTOS = """
        select date_format(ocorrido_em, '%%Y-%%m-%%d %%H:%%i:%%s'),
               resultado, comando, esquema, tabela, linhas_ao_menos, limite,
               justificativa, usuario, aplicacao
          from guarda.evento
         order by ocorrido_em desc
         limit {limite}
    """

    SQL_UPSERT_POLITICA = """
        insert into guarda.politica
            (esquema, tabela, limite_delete, limite_update, ativo, observacao)
        values (%s, %s, %s, %s, %s, %s)
        on duplicate key update
            limite_delete = values(limite_delete),
            limite_update = values(limite_update),
            ativo         = values(ativo),
            observacao    = values(observacao)
    """

    SQL_UPDATE_CONFIG = "update guarda.config set valor = %s where chave = %s"

    SQL_INSERT_EVENTO = """
        insert into guarda.evento
            (resultado, comando, esquema, tabela, limite, justificativa,
             ambiente, usuario, aplicacao)
        values ('configuracao', %s, %s, %s, %s, %s,
                (select valor from guarda.config where chave = 'ambiente'),
                %s, 'guarda-painel')
    """

    @classmethod
    def conectar(cls, dsn: str) -> RepositorioMySQL:
        try:
            import pymysql
        except ImportError as e:
            raise ErroDeUso(
                "Driver do MySQL não encontrado. Instale com: pip install PyMySQL"
            ) from e
        partes = dict(
            p.split("=", 1) for p in dsn.split() if "=" in p
        )
        return cls(
            pymysql.connect(
                host=partes.get("host", "127.0.0.1"),
                port=int(partes.get("port", 3306)),
                user=partes.get("user", "root"),
                password=partes.get("password", ""),
                database=partes.get("dbname", "guarda"),
                autocommit=False,
            )
        )


# ---------------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------------
class RepositorioSQLServer(RepositorioSQL):
    engine = "sqlserver"
    marcador = "?"

    SQL_CONFIG = "select chave, valor from guarda.config order by chave"

    SQL_TABELAS = """
        select s.name,
               t.name,
               case when exists (select 1 from sys.triggers tr
                                  where tr.parent_id = t.object_id
                                    and tr.name like 'guarda[_]dml[_]%'
                                    and tr.is_disabled = 0)
                    then 1 else 0 end,
               coalesce(p.ativo, 1),
               p.limite_delete,
               p.limite_update,
               coalesce((select sum(ps.row_count) from sys.dm_db_partition_stats ps
                          where ps.object_id = t.object_id and ps.index_id in (0, 1)), 0),
               p.observacao
          from sys.tables t
          join sys.schemas s on s.schema_id = t.schema_id
          left join guarda.politica p
                 on p.esquema = s.name and p.tabela = t.name
         where t.is_ms_shipped = 0
           and s.name not in ('guarda', 'sys')
         order by s.name, t.name
    """

    SQL_EVENTOS = """
        select top {limite}
               convert(varchar(19), ocorrido_em, 120),
               resultado, comando, esquema, tabela, linhas, limite,
               justificativa, usuario, aplicacao
          from guarda.evento
         order by ocorrido_em desc
    """

    SQL_UPSERT_POLITICA = """
        merge guarda.politica as destino
        using (select ? as esquema, ? as tabela, ? as limite_delete,
                      ? as limite_update, ? as ativo, ? as observacao) as origem
           on destino.esquema = origem.esquema and destino.tabela = origem.tabela
        when matched then update
             set limite_delete = origem.limite_delete,
                 limite_update = origem.limite_update,
                 ativo         = origem.ativo,
                 observacao    = origem.observacao
        when not matched then
             insert (esquema, tabela, limite_delete, limite_update, ativo, observacao)
             values (origem.esquema, origem.tabela, origem.limite_delete,
                     origem.limite_update, origem.ativo, origem.observacao);
    """

    SQL_UPDATE_CONFIG = "update guarda.config set valor = ? where chave = ?"

    SQL_INSERT_EVENTO = """
        insert into guarda.evento
            (resultado, comando, esquema, tabela, limite, justificativa,
             ambiente, usuario, usuario_efetivo, aplicacao)
        values ('configuracao', ?, ?, ?, ?, ?,
                (select valor from guarda.config where chave = 'ambiente'),
                ?, user_name(), 'guarda-painel')
    """

    @classmethod
    def conectar(cls, dsn: str) -> RepositorioSQLServer:
        try:
            import pyodbc
        except ImportError as e:
            raise ErroDeUso(
                "Driver do SQL Server não encontrado. Instale com: pip install pyodbc"
            ) from e
        return cls(pyodbc.connect(dsn, autocommit=False))


# ---------------------------------------------------------------------------
# Repositório de memória, para teste e para a demonstração do painel
# ---------------------------------------------------------------------------
@dataclass
class RepositorioMemoria:
    engine: str = "memoria"
    _config: dict[str, str] = field(
        default_factory=lambda: {
            "ambiente": "homologacao",
            "limite_delete_padrao": "500",
            "limite_update_padrao": "500",
            "registrar_acima_de": "100",
            "exigir_justificativa": "sim",
            "proteger_ddl": "sim",
            "papel_admin": "guarda_admin",
        }
    )
    _tabelas: list[Tabela] = field(
        default_factory=lambda: [
            Tabela("public", "cliente", True, True, None, None, 184_320, None),
            Tabela("public", "pedido", True, True, 2000, 500, 951_004, "tabela quente"),
            Tabela("public", "item_pedido", True, True, None, None, 3_402_881, None),
            Tabela("public", "log_acesso", True, False, 10000, None, 48_120_004,
                   "expurgo diario em lotes, OS-4821"),
            Tabela("public", "staging_importacao", False, True, None, None, 0, None),
        ]
    )
    _eventos: list[Evento] = field(default_factory=list)

    def config(self) -> dict[str, str]:
        return dict(self._config)

    def tabelas(self) -> list[Tabela]:
        return list(self._tabelas)

    def eventos(self, limite: int = 100) -> list[Evento]:
        return self._eventos[:limite]

    def salvar_tabela(self, esquema, tabela, ativo, limite_delete, limite_update, motivo, quem):
        motivo = validar_motivo(motivo)
        limite_delete = validar_limite(limite_delete, "Limite de DELETE")
        limite_update = validar_limite(limite_update, "Limite de UPDATE")

        for i, t in enumerate(self._tabelas):
            if t.esquema == esquema and t.tabela == tabela:
                self._tabelas[i] = Tabela(
                    esquema, tabela, t.instalada, ativo,
                    limite_delete, limite_update, t.linhas_estimadas, motivo,
                )
                break
        else:
            raise ErroDeUso(f"Tabela {esquema}.{tabela} não existe.")

        self._eventos.insert(0, Evento(
            "2026-07-29 12:00:00", "configuracao",
            "PAINEL ATIVOU" if ativo else "PAINEL DESATIVOU",
            esquema, tabela, None, limite_delete, motivo, quem, "guarda-painel",
        ))

    def salvar_config(self, chave, valor, motivo, quem):
        motivo = validar_motivo(motivo)
        if chave not in CHAVES_EDITAVEIS:
            raise ErroDeUso(f"Chave '{chave}' não pode ser alterada pelo painel.")
        if chave not in self._config:
            raise ErroDeUso(f"Chave '{chave}' não existe em guarda.config.")
        if chave.startswith("limite_") or chave in ("registrar_acima_de", "janela_liberacao_seg"):
            validar_limite(valor, chave)
        if chave in ("exigir_justificativa", "proteger_ddl", "exigir_performance_schema"):
            if valor not in ("sim", "nao"):
                raise ErroDeUso(f"{chave} aceita apenas 'sim' ou 'nao'.")
        self._config[chave] = str(valor)
        self._eventos.insert(0, Evento(
            "2026-07-29 12:00:00", "configuracao", f"PAINEL CONFIG {chave}={valor}",
            None, None, None, None, motivo, quem, "guarda-painel",
        ))

    def fechar(self) -> None:
        pass


def criar(engine: str, dsn: str | None) -> Repositorio:
    engine = (engine or "").lower()
    if engine in ("memoria", "demo"):
        return RepositorioMemoria()

    dsn = dsn or os.environ.get("GUARDA_DSN", "")
    if not dsn:
        raise ErroDeUso("Informe --dsn ou a variável de ambiente GUARDA_DSN.")

    if engine in ("postgresql", "postgres", "pg"):
        return RepositorioPostgres.conectar(dsn)
    if engine in ("mysql", "mariadb"):
        return RepositorioMySQL.conectar(dsn)
    if engine in ("sqlserver", "mssql"):
        return RepositorioSQLServer.conectar(dsn)

    raise ErroDeUso(f"Engine desconhecida: {engine}")
