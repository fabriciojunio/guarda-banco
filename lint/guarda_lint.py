#!/usr/bin/env python3
"""Verificação estática de SQL antes de virar commit.

O guard do banco pega volume: comando que afeta linhas demais. O que ele
não vê é o comando que afeta POUCAS linhas, mas as erradas. Esses erros
moram no texto do SQL, e é o que este script procura em arquivos de
migração e scripts de manutenção.

Uso:
    python guarda_lint.py migracoes/*.sql
    python guarda_lint.py --formato json migracoes/
    python guarda_lint.py --so-erros migracoes/

Para silenciar uma regra em um ponto específico, escreva na linha
anterior ou na mesma linha:

    -- guarda-lint: ignorar delete-sem-where (expurgo aprovado no OS-4821)

O motivo entre parênteses é obrigatório: silenciar sem explicar é o
começo de todo incidente.
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ERRO = "erro"
AVISO = "aviso"


@dataclass(frozen=True)
class Achado:
    arquivo: str
    linha: int
    regra: str
    severidade: str
    mensagem: str
    trecho: str

    def formatar(self) -> str:
        marca = "erro " if self.severidade == ERRO else "aviso"
        return (
            f"{self.arquivo}:{self.linha}: {marca} [{self.regra}] {self.mensagem}\n"
            f"    {self.trecho}"
        )


# ---------------------------------------------------------------------------
# Limpeza: some com comentários e com o conteúdo de literais, preservando
# posições e quebras de linha para o número da linha continuar certo.
# ---------------------------------------------------------------------------
def limpar(sql: str, apagar_literais: bool = True) -> str:
    """Remove comentários. Com apagar_literais, também esvazia strings.

    O tamanho e as quebras de linha são preservados, então qualquer
    posição continua válida no texto original.
    """
    saida = list(sql)
    i = 0
    n = len(sql)

    def apagar(inicio: int, fim: int) -> None:
        for k in range(inicio, min(fim, n)):
            if saida[k] != "\n":
                saida[k] = " "

    while i < n:
        c = sql[i]
        prox = sql[i + 1] if i + 1 < n else ""

        if c == "-" and prox == "-":
            fim = sql.find("\n", i)
            fim = n if fim == -1 else fim
            apagar(i, fim)
            i = fim
            continue

        if c == "#":  # comentário de linha do MySQL
            fim = sql.find("\n", i)
            fim = n if fim == -1 else fim
            apagar(i, fim)
            i = fim
            continue

        if c == "/" and prox == "*":
            fim = sql.find("*/", i + 2)
            fim = n if fim == -1 else fim + 2
            apagar(i, fim)
            i = fim
            continue

        if c in ("'", '"', "`"):
            j = i + 1
            while j < n:
                if sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:  # aspas duplicada
                        j += 2
                        continue
                    break
                j += 1
            if apagar_literais:
                apagar(i + 1, j)
            i = min(j + 1, n)
            continue

        if c == "$":  # dollar quoting do PostgreSQL
            m = re.match(r"\$[A-Za-z_]*\$", sql[i:])
            if m:
                marca = m.group(0)
                fim = sql.find(marca, i + len(marca))
                if fim == -1:
                    if apagar_literais:
                        apagar(i, n)
                    i = n
                else:
                    if apagar_literais:
                        apagar(i + len(marca), fim)
                    i = fim + len(marca)
                continue

        i += 1

    return "".join(saida)


def inicios_de_linha(texto: str) -> list[int]:
    pos = [0]
    for i, c in enumerate(texto):
        if c == "\n":
            pos.append(i + 1)
    return pos


def linha_de(offset: int, inicios: list[int]) -> int:
    return bisect.bisect_right(inicios, offset)


def dividir_comandos(limpo: str) -> list[tuple[int, str]]:
    comandos = []
    inicio = 0
    for i, c in enumerate(limpo):
        if c == ";":
            trecho = limpo[inicio:i]
            if trecho.strip():
                comandos.append((inicio, trecho))
            inicio = i + 1
    if limpo[inicio:].strip():
        comandos.append((inicio, limpo[inicio:]))
    return comandos


def normalizar(texto: str) -> str:
    return re.sub(r"\s+", " ", texto).strip().lower()


def resumir(original: str, offset: int, tamanho: int = 110) -> str:
    inicio = original.rfind("\n", 0, offset) + 1
    fim = original.find("\n", offset)
    fim = len(original) if fim == -1 else fim
    linha = original[inicio:fim].strip()
    return linha[:tamanho] + ("..." if len(linha) > tamanho else "")


# ---------------------------------------------------------------------------
# Regras
#
# Cada regra recebe duas versões do mesmo comando e devolve uma mensagem,
# ou None:
#
#   cmd  comentários removidos e conteúdo de literais apagado. É o que a
#        maioria das regras quer, para não achar "delete from" dentro de
#        uma string.
#   cru  texto original normalizado. Necessário para as poucas regras que
#        precisam ler o valor de um literal, como o SET de uma variável.
# ---------------------------------------------------------------------------
Regra = tuple[str, str, object]


def _tem_where(cmd: str) -> bool:
    return re.search(r"\bwhere\b", cmd) is not None


def _condicao(cmd: str) -> str:
    """Só a parte de filtro do comando.

    Sem isso, `set email = null` (atribuição legítima) seria confundido
    com `where email = null` (comparação que nunca é verdadeira).
    """
    m = re.search(r"\b(where|having|on)\b(.*)$", cmd)
    return m.group(2) if m else ""


def r_delete_sem_where(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^delete\s+(low_priority\s+|quick\s+|ignore\s+)*from\b", cmd):
        return None
    if _tem_where(cmd):
        return None
    return "DELETE sem WHERE apaga a tabela inteira."


def r_update_sem_where(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^update\b", cmd) or not re.search(r"\bset\b", cmd):
        return None
    if _tem_where(cmd):
        return None
    return "UPDATE sem WHERE sobrescreve a tabela inteira."


def r_comparacao_com_null(cmd: str, cru: str = "") -> str | None:
    if re.search(r"(=|<>|!=)\s*null\b", _condicao(cmd)):
        return (
            "Comparação com NULL nunca é verdadeira. "
            "Use IS NULL ou IS NOT NULL, senão o filtro casa zero linhas em silêncio."
        )
    return None


def r_not_in_subconsulta(cmd: str, cru: str = "") -> str | None:
    if re.search(r"\bnot\s+in\s*\(\s*select\b", cmd):
        return (
            "NOT IN com subconsulta devolve conjunto vazio se a subconsulta "
            "trouxer um NULL. Prefira NOT EXISTS."
        )
    return None


def r_or_sem_parenteses(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^(delete|update)\b", cmd):
        return None
    m = re.search(r"\bwhere\b(.*)$", cmd)
    if not m:
        return None
    condicao = m.group(1)
    if re.search(r"\bor\b", condicao) and re.search(r"\band\b", condicao):
        if "(" not in condicao:
            return (
                "WHERE mistura AND e OR sem parênteses. AND tem precedência sobre OR, "
                "e o filtro provavelmente pega mais linhas do que você espera."
            )
    return None


def r_or_amplo(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^(delete|update)\b", cmd):
        return None
    m = re.search(r"\bwhere\b(.*)$", cmd)
    if not m:
        return None
    if re.search(r"\bor\b", m.group(1)) and not re.search(r"\band\b", m.group(1)):
        return "WHERE com OR em comando destrutivo. Confirme se não era AND."
    return None


def r_update_from_sem_where(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^update\b", cmd):
        return None
    if not re.search(r"\bfrom\b", cmd):
        return None
    if re.search(r"\bjoin\b.*\bon\b", cmd) or _tem_where(cmd):
        return None
    return (
        "UPDATE com FROM sem condição de junção: produto cartesiano. "
        "Cada linha recebe um valor arbitrário da outra tabela."
    )


def r_limit_sem_order(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^(delete|update)\b", cmd):
        return None
    if re.search(r"\blimit\b", cmd) and not re.search(r"\border\s+by\b", cmd):
        return (
            "LIMIT sem ORDER BY em comando destrutivo: as linhas escolhidas "
            "não são determinísticas."
        )
    return None


def r_where_sempre_verdadeiro(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^(delete|update)\b", cmd):
        return None
    m = re.search(r"\bwhere\b(.*)$", cmd)
    if not m:
        return None
    condicao = m.group(1).strip().rstrip(";").strip()
    if re.fullmatch(r"(1\s*=\s*1|true|0\s*=\s*0)", condicao):
        return "WHERE que é sempre verdadeiro equivale a não ter WHERE."
    return None


def r_truncate(cmd: str, cru: str = "") -> str | None:
    if re.match(r"^truncate\b", cmd):
        return (
            "TRUNCATE não deixa rastro por linha e nem sempre é reversível. "
            "Prefira DELETE em lotes."
        )
    return None


def r_drop_destrutivo(cmd: str, cru: str = "") -> str | None:
    m = re.match(r"^drop\s+(table|database|schema)\b", cmd)
    if m:
        return f"DROP {m.group(1).upper()} destrói estrutura e dados juntos."
    if re.match(r"^alter\s+table\b", cmd) and re.search(r"\bdrop\s+(column\b|[`\"\w]+\s*$)", cmd):
        return "ALTER TABLE DROP COLUMN apaga os dados da coluna sem volta."
    return None


def r_fk_checks_desligado(cmd: str, cru: str = "") -> str | None:
    if re.search(r"foreign_key_checks\s*=\s*0", cmd):
        return (
            "FOREIGN_KEY_CHECKS = 0 permite gravar dado órfão. "
            "Se esquecer de religar, a sessão inteira fica sem integridade."
        )
    # o nome da variável aparece no comando limpo, mas o valor está dentro
    # de um literal: só o texto cru sabe se é replica ou origin
    if re.search(r"\bsession_replication_role\s*=", cmd) and re.search(
        r"session_replication_role\s*=\s*'?\s*replica", cru or cmd
    ):
        return (
            "session_replication_role = replica desliga as triggers de usuário, "
            "inclusive as do guard."
        )
    if re.search(r"\balter\s+table\b.*\bdisable\s+trigger\b", cmd):
        return "DISABLE TRIGGER desliga a proteção do banco."
    return None


def r_tipo_reduzido(cmd: str, cru: str = "") -> str | None:
    if not re.match(r"^alter\s+table\b", cmd):
        return None
    if re.search(r"\b(alter|modify)\s+(column\s+)?[`\"\w]+\s+(type\s+)?"
                 r"(varchar|char|nvarchar|numeric|decimal)\s*\(", cmd):
        return (
            "Alteração de tipo com tamanho: se o novo tamanho for menor, "
            "o banco corta ou recusa os dados existentes. Confira o maior valor atual."
        )
    return None


REGRAS: list[Regra] = [
    ("delete-sem-where", ERRO, r_delete_sem_where),
    ("update-sem-where", ERRO, r_update_sem_where),
    ("comparacao-com-null", ERRO, r_comparacao_com_null),
    ("update-from-sem-juncao", ERRO, r_update_from_sem_where),
    ("where-sempre-verdadeiro", ERRO, r_where_sempre_verdadeiro),
    ("or-sem-parenteses", ERRO, r_or_sem_parenteses),
    ("desativa-integridade", ERRO, r_fk_checks_desligado),
    ("truncate", AVISO, r_truncate),
    ("drop-destrutivo", AVISO, r_drop_destrutivo),
    ("not-in-subconsulta", AVISO, r_not_in_subconsulta),
    ("or-em-comando-destrutivo", AVISO, r_or_amplo),
    ("limit-sem-order-by", AVISO, r_limit_sem_order),
    ("tipo-reduzido", AVISO, r_tipo_reduzido),
]

REGRA_TRANSACAO = "ddl-sem-transacao"

PADRAO_IGNORAR = re.compile(
    r"--\s*guarda-lint:\s*ignorar\s+([\w-]+)\s*\(([^)]{5,})\)", re.IGNORECASE
)


def ignorados_por_linha(original: str) -> dict[int, set[str]]:
    """Silenciamentos valem para a própria linha e para a seguinte."""
    mapa: dict[int, set[str]] = {}
    for numero, texto in enumerate(original.splitlines(), start=1):
        for m in PADRAO_IGNORAR.finditer(texto):
            regra = m.group(1).lower()
            mapa.setdefault(numero, set()).add(regra)
            mapa.setdefault(numero + 1, set()).add(regra)
    return mapa


def analisar(texto: str, nome_arquivo: str = "<texto>") -> list[Achado]:
    limpo = limpar(texto)
    # mesma limpeza, mas com os literais preservados: é a versão "cru"
    sem_comentarios = limpar(texto, apagar_literais=False)
    inicios = inicios_de_linha(texto)
    ignorados = ignorados_por_linha(texto)
    achados: list[Achado] = []

    tem_transacao = re.search(
        r"^\s*(begin|start\s+transaction)\b", limpo, re.IGNORECASE | re.MULTILINE
    ) is not None

    houve_ddl_destrutivo = False

    for offset, bruto in dividir_comandos(limpo):
        cmd = normalizar(bruto)
        if not cmd:
            continue

        # limpar() preserva as posições, então o mesmo intervalo devolve o
        # comando com os literais intactos e sem os comentários
        cru = normalizar(sem_comentarios[offset:offset + len(bruto)])

        # o offset aponta para o começo do comando, que pode ser espaço em branco
        deslocamento = offset + (len(bruto) - len(bruto.lstrip()))
        linha = linha_de(deslocamento, inicios)

        if r_truncate(cmd) or r_drop_destrutivo(cmd):
            houve_ddl_destrutivo = True

        for nome, severidade, funcao in REGRAS:
            mensagem = funcao(cmd, cru)
            if not mensagem:
                continue
            if nome in ignorados.get(linha, set()):
                continue
            achados.append(
                Achado(
                    arquivo=nome_arquivo,
                    linha=linha,
                    regra=nome,
                    severidade=severidade,
                    mensagem=mensagem,
                    trecho=resumir(texto, deslocamento),
                )
            )

    if houve_ddl_destrutivo and not tem_transacao:
        achados.append(
            Achado(
                arquivo=nome_arquivo,
                linha=1,
                regra=REGRA_TRANSACAO,
                severidade=AVISO,
                mensagem=(
                    "O arquivo tem comando destrutivo e não abre transação. "
                    "Se falhar no meio, fica pela metade. Envolva em BEGIN/COMMIT."
                ),
                trecho=texto.splitlines()[0][:110] if texto.strip() else "",
            )
        )

    return sorted(achados, key=lambda a: (a.linha, a.regra))


def coletar_arquivos(caminhos: list[str]) -> list[Path]:
    arquivos: list[Path] = []
    for bruto in caminhos:
        p = Path(bruto)
        if p.is_dir():
            arquivos.extend(sorted(p.rglob("*.sql")))
        elif p.is_file():
            arquivos.append(p)
        else:
            print(f"guarda-lint: caminho não encontrado: {bruto}", file=sys.stderr)
    return arquivos


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="guarda-lint",
        description="Procura erros destrutivos em arquivos SQL antes do commit.",
    )
    ap.add_argument("caminhos", nargs="+", help="arquivos .sql ou diretórios")
    ap.add_argument("--formato", choices=["texto", "json"], default="texto")
    ap.add_argument(
        "--so-erros",
        action="store_true",
        help="não mostra avisos, só o que reprova",
    )
    args = ap.parse_args(argv)

    # as mensagens têm acento e o console do Windows costuma abrir em cp1252
    for fluxo in (sys.stdout, sys.stderr):
        if hasattr(fluxo, "reconfigure"):
            try:
                fluxo.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass

    arquivos = coletar_arquivos(args.caminhos)
    if not arquivos:
        print("guarda-lint: nenhum arquivo .sql para analisar", file=sys.stderr)
        return 0

    todos: list[Achado] = []
    for arquivo in arquivos:
        texto = arquivo.read_text(encoding="utf-8", errors="replace")
        todos.extend(analisar(texto, str(arquivo)))

    if args.so_erros:
        todos = [a for a in todos if a.severidade == ERRO]

    erros = sum(1 for a in todos if a.severidade == ERRO)
    avisos = len(todos) - erros

    if args.formato == "json":
        print(json.dumps([a.__dict__ for a in todos], ensure_ascii=False, indent=2))
    else:
        for a in todos:
            print(a.formatar())
        print(
            f"\nguarda-lint: {len(arquivos)} arquivo(s), "
            f"{erros} erro(s), {avisos} aviso(s)"
        )

    return 1 if erros else 0


if __name__ == "__main__":
    sys.exit(main())
