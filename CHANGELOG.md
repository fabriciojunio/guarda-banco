# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
versionamento conforme [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-07-31

Primeira versão utilizável em produção. PostgreSQL e MySQL rodam na CI a
cada push. SQL Server está escrito e revisado, mas ainda não foi executado
em servidor real.

### Adicionado

- **PostgreSQL**: contagem por linha que aborta antes de apagar, proteção
  de `TRUNCATE`, event triggers para DDL destrutivo, antissabotagem e
  adoção automática de tabelas novas
- **SQL Server**: mesma ideia com trigger `AFTER` e DDL trigger
- **MySQL**: contador via `performance_schema`, com os pontos cegos
  documentados em `docs/limitacoes.md`
- **Painel** local para ver a situação e ligar ou desligar a proteção, com
  motivo obrigatório de 15 caracteres que vai para a auditoria
- **Watchdog** (`ferramentas/rearmar.py`) que devolve a proteção removida e
  adota tabela nova no MySQL, sem nunca religar o que uma pessoa desligou
  de propósito
- **Linter** de SQL para migrações, com hook de pre-commit
- Catálogo dos 27 incidentes levantados e o que cada camada pega
- Guia de implantação na empresa, em `docs/implantacao.md`
- 83 testes de Python e 17 casos de aceitação rodando dentro do banco

### Detalhes que custaram caro para descobrir

- **Cascata zerava o contador.** `DELETE` em cascata gera comando interno
  na tabela filha, que disparava o `BEFORE STATEMENT` e zerava a conta do
  pai. Corrigido com contagem de nível de aninhamento.
- **`sql_safe_updates` age antes da trigger no MySQL**, e `guarda.liberar()`
  não passa por cima dele. No MySQL, expurgo grande sempre sai em lote.
