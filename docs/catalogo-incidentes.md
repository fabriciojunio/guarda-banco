# Catálogo de incidentes

Levantamento dos erros manuais que mais causam perda ou corrupção de dados em
ambiente corporativo, e onde cada um é interceptado por este sistema.

Legenda da coluna "onde pega":

- **contador** — trigger de linha que aborta ao passar do limite de linhas
- **truncate** — trigger BEFORE TRUNCATE
- **ddl** — event trigger / DDL trigger
- **privilégio** — GRANT/REVOKE, o guard não é a defesa
- **linter** — verificação estática nos arquivos de migração
- **processo** — não tem defesa técnica direta, entra no runbook

## A. Destruição de dados em massa

| # | Erro | Frequência | Onde pega |
|---|------|-----------|-----------|
| A1 | `DELETE FROM tabela` sem `WHERE` | alta | contador, linter |
| A2 | `UPDATE tabela SET col = x` sem `WHERE` | alta | contador, linter |
| A3 | `WHERE` que casa muito mais linhas que o esperado | **muito alta** | contador |
| A4 | `TRUNCATE TABLE` em produção | média | truncate, privilégio |
| A5 | `DELETE` no pai disparando `ON DELETE CASCADE` bem além do previsto | média, quase invisível | contador (soma o raio total) |
| A6 | `WHERE` colado da linha errada do editor (executou o bloco vizinho) | alta | contador |
| A7 | Executou seleção parcial: marcou até o fim da linha e o `WHERE` ficou fora | alta | contador |
| A8 | `OR` onde se queria `AND`, ou falta de parênteses com `OR` | média | contador, linter |
| A9 | `= NULL` / `!= NULL` / `NOT IN (subquery com NULL)` | média | linter |
| A10 | `UPDATE ... FROM` sem condição de junção (produto cartesiano) | média | contador, linter |
| A11 | `DELETE ... LIMIT n` sem `ORDER BY` em laço de expurgo | baixa | linter |
| A12 | Filtro de data com fuso/formato errado apagando o período errado | média | contador |
| A13 | `WHERE` em coluna não única achando que é única | média | contador |
| A14 | Colunas trocadas no `SET` (gravou telefone no campo de CPF) | média | processo |

Observação sobre A9: na prática `= NULL` costuma afetar zero linhas, então o
prejuízo é "não fez nada" e não "apagou tudo". Fica no catálogo porque gera
incidente de dado desatualizado, mas o risco é menor do que parece.

## B. Destruição de estrutura

| # | Erro | Frequência | Onde pega |
|---|------|-----------|-----------|
| B1 | `DROP TABLE` | média | ddl, privilégio |
| B2 | `DROP SCHEMA ... CASCADE` | baixa, catastrófico | ddl, privilégio |
| B3 | `DROP DATABASE` | baixa, catastrófico | privilégio (event trigger não pega) |
| B4 | `ALTER TABLE ... DROP COLUMN` | média | ddl |
| B5 | Alterar tipo com perda (`varchar(200)` para `varchar(50)`) | média | ddl (alerta), linter |
| B6 | `DROP INDEX` sem recriar, ou recriar fora de transação | média | ddl |
| B7 | Recriar constraint com `DROP` antes do `CREATE` e falhar no meio | baixa | linter (exige transação) |
| B8 | Remover o próprio guard (`DROP TRIGGER`, `DISABLE TRIGGER`) | relevante | ddl |

## C. Ambiente e sessão

| # | Erro | Frequência | Onde pega |
|---|------|-----------|-----------|
| C1 | Rodou em produção pensando que era homologação | **muito alta** | contador + auditoria; mitigação é papel somente leitura |
| C2 | Autocommit ligado, sem chance de `ROLLBACK` | muito alta | o desenho da liberação obriga transação explícita |
| C3 | DDL em MySQL causando commit implícito da transação aberta | média | processo, linter |
| C4 | `SET FOREIGN_KEY_CHECKS=0` / `session_replication_role=replica` e esqueceu de voltar | média | privilégio (ver limitações) |
| C5 | Transação aberta e abandonada segurando lock, aplicação para | alta | monitoramento (`guarda.transacoes_presas`) |
| C6 | Query pesada em horário de pico travando o servidor | alta | fora de escopo, é capacidade e não integridade |
| C7 | Desabilitou triggers para "ir mais rápido" na carga | média | ddl (B8) |

## D. Governança

| # | Problema | Onde resolve |
|---|----------|--------------|
| D1 | Todo mundo usando o mesmo usuário admin, sem rastro de quem fez | papéis nominais + auditoria |
| D2 | `GRANT ALL` para desenvolvedor | receita de privilégios |
| D3 | Backup existe mas nunca foi restaurado de teste | runbook |
| D4 | Alteração direta em produção sem migração versionada | linter + hook de commit |
| D5 | Dado pessoal apagado sem registro de quem apagou (LGPD art. 37) | tabela de auditoria |

## O que este catálogo diz sobre o desenho

O item mais frequente da lista não é A1, é **A3**. `DELETE` sem `WHERE` é o caso
fácil, quase todo cliente gráfico já avisa. O que destrói dados de verdade é o
`WHERE` que o autor achou que filtrava 3 linhas e filtrava 400 mil.

Por isso o núcleo do sistema é limite de linhas afetadas por comando, e não
detecção de sintaxe. Limite de linhas pega A1, A2, A3, A5, A6, A7, A8, A10,
A12 e A13 de uma vez, com uma regra só.
