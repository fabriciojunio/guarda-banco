#!/usr/bin/env python3
"""Painel do guarda-banco: tela para ver e ajustar a proteção.

Só biblioteca padrão, fora do driver do banco. Sem framework, sem CDN,
sem build.

    python painel/servidor.py --engine demo
    python painel/servidor.py --engine postgresql --dsn "host=... dbname=... user=..."
    python painel/servidor.py --engine postgresql --somente-leitura

Escuta em 127.0.0.1 de propósito. O painel liga e desliga proteção de
banco: não é coisa para ficar aberta na rede. Se precisar acessar de
outra máquina, use um túnel SSH, não --host 0.0.0.0.
"""

from __future__ import annotations

import argparse
import getpass
import json
import secrets
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

import repositorio as repo  # noqa: E402

PASTA = Path(__file__).resolve().parent
TAMANHO_MAXIMO_CORPO = 64 * 1024


class Estado:
    """Tudo que o handler precisa, montado uma vez no start."""

    def __init__(self, repositorio, somente_leitura: bool, quem: str) -> None:
        self.repositorio = repositorio
        self.somente_leitura = somente_leitura
        self.quem = quem
        self.token = secrets.token_urlsafe(24)


class Handler(BaseHTTPRequestHandler):
    estado: Estado = None  # type: ignore[assignment]
    server_version = "guarda-painel"
    sys_version = ""

    # -- utilidades -------------------------------------------------------
    def _responder(self, status: int, corpo: bytes, tipo: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
            "connect-src 'self'; form-action 'none'; base-uri 'none'",
        )
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(corpo)

    def _json(self, dados, status: int = 200) -> None:
        corpo = json.dumps(dados, ensure_ascii=False).encode("utf-8")
        self._responder(status, corpo, "application/json; charset=utf-8")

    def _erro(self, status: int, mensagem: str) -> None:
        self._json({"erro": mensagem}, status)

    def _corpo(self) -> dict:
        tamanho = int(self.headers.get("Content-Length") or 0)
        if tamanho <= 0:
            return {}
        if tamanho > TAMANHO_MAXIMO_CORPO:
            raise repo.ErroDeUso("Corpo da requisição grande demais.")
        try:
            return json.loads(self.rfile.read(tamanho).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise repo.ErroDeUso("Corpo da requisição não é JSON válido.") from None

    def _conferir_token(self) -> None:
        enviado = self.headers.get("X-Guarda-Token", "")
        if not secrets.compare_digest(enviado, self.estado.token):
            raise repo.ErroDeUso("Token inválido. Recarregue a página.")

    def log_message(self, formato: str, *args) -> None:
        # o log padrão do http.server é ruidoso e mostra o caminho completo
        if self.path.startswith("/api/"):
            sys.stderr.write(f"painel {self.command} {self.path} -> {args[1]}\n")

    # -- rotas ------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        caminho = urlparse(self.path).path
        try:
            if caminho in ("/", "/index.html"):
                return self._pagina()
            if caminho == "/api/estado":
                return self._api_estado()
            if caminho == "/api/tabelas":
                return self._api_tabelas()
            if caminho == "/api/eventos":
                return self._api_eventos()
            return self._erro(404, "Rota não encontrada.")
        except repo.ErroDeUso as e:
            return self._erro(400, str(e))
        except Exception:
            traceback.print_exc()
            return self._erro(500, "Erro no servidor. Veja o terminal do painel.")

    def do_POST(self) -> None:  # noqa: N802
        caminho = urlparse(self.path).path
        try:
            if self.estado.somente_leitura:
                return self._erro(403, "Painel aberto em modo somente leitura.")
            self._conferir_token()

            if caminho == "/api/tabela":
                return self._api_salvar_tabela()
            if caminho == "/api/config":
                return self._api_salvar_config()
            return self._erro(404, "Rota não encontrada.")
        except repo.ErroDeUso as e:
            return self._erro(400, str(e))
        except Exception:
            traceback.print_exc()
            return self._erro(500, "Erro no servidor. Veja o terminal do painel.")

    # -- implementação ----------------------------------------------------
    def _pagina(self) -> None:
        html = (PASTA / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.estado.token)
        self._responder(200, html.encode("utf-8"), "text/html; charset=utf-8")

    def _api_estado(self) -> None:
        tabelas = self.estado.repositorio.tabelas()
        total = len(tabelas)
        protegidas = sum(1 for t in tabelas if t.protegida)
        sem_trigger = sum(1 for t in tabelas if not t.instalada)
        desativadas = sum(1 for t in tabelas if t.instalada and not t.ativo)

        if total == 0:
            situacao = "vazio"
        elif protegidas == total:
            situacao = "protegido"
        elif protegidas == 0:
            situacao = "desprotegido"
        else:
            situacao = "parcial"

        self._json(
            {
                "engine": self.estado.repositorio.engine,
                "config": self.estado.repositorio.config(),
                "somente_leitura": self.estado.somente_leitura,
                "quem": self.estado.quem,
                "resumo": {
                    "total": total,
                    "protegidas": protegidas,
                    "sem_trigger": sem_trigger,
                    "desativadas": desativadas,
                    "situacao": situacao,
                },
            }
        )

    def _api_tabelas(self) -> None:
        self._json([t.como_dicionario() for t in self.estado.repositorio.tabelas()])

    def _api_eventos(self) -> None:
        parametros = parse_qs(urlparse(self.path).query)
        try:
            limite = int(parametros.get("limite", ["100"])[0])
        except ValueError:
            raise repo.ErroDeUso("Parâmetro 'limite' inválido.") from None
        self._json([e.__dict__ for e in self.estado.repositorio.eventos(limite)])

    def _api_salvar_tabela(self) -> None:
        corpo = self._corpo()
        for campo in ("esquema", "tabela", "motivo"):
            if not str(corpo.get(campo) or "").strip():
                raise repo.ErroDeUso(f"Campo '{campo}' é obrigatório.")

        self.estado.repositorio.salvar_tabela(
            esquema=str(corpo["esquema"]),
            tabela=str(corpo["tabela"]),
            ativo=bool(corpo.get("ativo", True)),
            limite_delete=corpo.get("limite_delete"),
            limite_update=corpo.get("limite_update"),
            motivo=str(corpo["motivo"]),
            quem=self.estado.quem,
        )
        self._json({"ok": True})

    def _api_salvar_config(self) -> None:
        corpo = self._corpo()
        for campo in ("chave", "valor", "motivo"):
            if str(corpo.get(campo, "")).strip() == "":
                raise repo.ErroDeUso(f"Campo '{campo}' é obrigatório.")

        self.estado.repositorio.salvar_config(
            chave=str(corpo["chave"]),
            valor=str(corpo["valor"]),
            motivo=str(corpo["motivo"]),
            quem=self.estado.quem,
        )
        self._json({"ok": True})


def criar_servidor(
    repositorio,
    host: str = "127.0.0.1",
    porta: int = 8777,
    somente_leitura: bool = False,
    quem: str | None = None,
) -> ThreadingHTTPServer:
    estado = Estado(
        repositorio=repositorio,
        somente_leitura=somente_leitura,
        quem=quem or _quem_sou_eu(),
    )
    classe = type("HandlerConfigurado", (Handler,), {"estado": estado})
    servidor = ThreadingHTTPServer((host, porta), classe)
    servidor.daemon_threads = True
    servidor.estado = estado  # type: ignore[attr-defined]
    return servidor


def _quem_sou_eu() -> str:
    try:
        return getpass.getuser()
    except Exception:
        return "desconhecido"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="guarda-painel",
        description="Tela para ver e ajustar a proteção do guarda-banco.",
    )
    ap.add_argument(
        "--engine",
        default="demo",
        help="postgresql, mysql, sqlserver ou demo (dados de exemplo, sem banco)",
    )
    ap.add_argument("--dsn", default=None, help="string de conexão, ou use GUARDA_DSN")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--porta", type=int, default=8777)
    ap.add_argument(
        "--somente-leitura",
        action="store_true",
        help="abre o painel sem permitir nenhuma alteração",
    )
    ap.add_argument("--quem", default=None, help="nome que vai para a auditoria")
    args = ap.parse_args(argv)

    for fluxo in (sys.stdout, sys.stderr):
        if hasattr(fluxo, "reconfigure"):
            try:
                fluxo.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass

    try:
        repositorio = repo.criar(args.engine, args.dsn)
    except repo.ErroDeUso as e:
        print(f"guarda-painel: {e}", file=sys.stderr)
        return 2

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print(
            f"guarda-painel: ATENÇÃO, escutando em {args.host}. Este painel liga e "
            "desliga proteção de banco e não tem autenticação. Prefira túnel SSH.",
            file=sys.stderr,
        )

    servidor = criar_servidor(
        repositorio,
        host=args.host,
        porta=args.porta,
        somente_leitura=args.somente_leitura,
        quem=args.quem,
    )

    modo = "somente leitura" if args.somente_leitura else "leitura e escrita"
    print(f"guarda-painel em http://{args.host}:{args.porta}")
    print(f"  engine: {repositorio.engine}   modo: {modo}   auditoria como: {servidor.estado.quem}")
    print("  Ctrl+C para encerrar")

    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("\nencerrando")
    finally:
        servidor.server_close()
        repositorio.fechar()
    return 0


if __name__ == "__main__":
    sys.exit(main())
