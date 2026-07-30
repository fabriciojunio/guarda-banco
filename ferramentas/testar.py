#!/usr/bin/env python3
"""Roda todos os testes do projeto de uma vez.

    python ferramentas/testar.py

Os testes de unidade não precisam de banco. Se GUARDA_DSN estiver
definida, o teste de integração do painel também roda, contra o banco
apontado por ela.

    # PowerShell
    $env:GUARDA_DSN = "host=127.0.0.1 port=5432 dbname=lojateste user=postgres"
    python ferramentas/testar.py

O teste de aceitação do SQL não entra aqui: ele roda dentro do banco, com
psql / sqlcmd / mysql. Ver ferramentas/postgres-local.ps1 e o README.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent

SUITES = [
    ("linter", RAIZ / "lint", ["test_guarda_lint"]),
    ("painel", RAIZ / "painel", ["test_painel"]),
    ("painel (integração, precisa de GUARDA_DSN)", RAIZ / "painel", ["test_integracao"]),
]


def rodar(nome: str, pasta: Path, modulos: list[str]) -> tuple[str, bool, str]:
    processo = subprocess.run(
        [sys.executable, "-m", "unittest", *modulos],
        cwd=pasta,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    saida = (processo.stderr or "") + (processo.stdout or "")
    ultima = [l for l in saida.strip().splitlines() if l.strip()]
    resumo = ultima[-1] if ultima else "sem saída"

    # unittest põe a contagem numa linha do tipo "Ran 40 tests in 0.013s"
    contagem = next((l for l in ultima if l.startswith("Ran ")), "")
    if contagem:
        resumo = f"{contagem.strip()} -> {resumo}"

    return nome, processo.returncode == 0, resumo


def main() -> int:
    for fluxo in (sys.stdout, sys.stderr):
        if hasattr(fluxo, "reconfigure"):
            try:
                fluxo.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass

    tem_dsn = bool(os.environ.get("GUARDA_DSN"))
    print(f"guarda-banco: rodando os testes (GUARDA_DSN {'definida' if tem_dsn else 'ausente'})\n")

    falhou = False
    for nome, pasta, modulos in SUITES:
        rotulo, ok, resumo = rodar(nome, pasta, modulos)
        marca = "ok    " if ok else "FALHOU"
        print(f"  [{marca}] {rotulo}")
        print(f"           {resumo}")
        if not ok:
            falhou = True

    if not tem_dsn:
        print(
            "\n  Os testes de integração foram pulados. Para rodá-los, suba um "
            "PostgreSQL de teste\n  com ferramentas/postgres-local.ps1 e defina GUARDA_DSN."
        )

    print("\nresultado: " + ("alguma suíte falhou" if falhou else "tudo passando"))
    return 1 if falhou else 0


if __name__ == "__main__":
    sys.exit(main())
