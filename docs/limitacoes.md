# Limitações e formas de burlar

Esta página existe porque um sistema de proteção em que as pessoas confiam
mais do que ele merece é pior do que não ter sistema nenhum. Leia antes de
dizer para a equipe que "agora o banco está protegido".

## Quem passa por cima de tudo

| Papel | Como passa |
|-------|-----------|
| PostgreSQL: superusuário | pode `SET session_replication_role = replica`, que desliga toda trigger de usuário, e pode remover os event triggers |
| PostgreSQL: dono da tabela | pode `DROP TRIGGER`. O event trigger bloqueia, mas o dono que também for superusuário remove o event trigger primeiro |
| SQL Server: sysadmin, db_owner | ignora `DENY`, remove trigger e DDL trigger |
| MySQL: `SUPER`, ou `TRIGGER` no banco | remove as triggers do guard |

Conclusão prática: o guard protege contra **acidente**, não contra quem
tem privilégio e quer mesmo. A lista de superusuários precisa ser curta, e
o dia a dia não pode acontecer com essas contas. Os scripts de permissões
de cada engine terminam com as consultas que mostram essa lista.

## O que nenhuma engine pega

- **`DROP DATABASE`.** No PostgreSQL, event trigger não dispara para
  objeto do cluster. No SQL Server, precisa de trigger de servidor (está
  em `sqlserver/03-guardas-ddl.sql`, comentado). No MySQL, não existe.
  Defesa: não ter `CREATEDB` / `dbcreator`, e não ser dono do banco.
- **Erro dentro do limite.** `UPDATE cliente SET cpf = telefone WHERE id = 7`
  afeta uma linha e está errado. Nenhum contador de linhas vê isso.
- **Colunas trocadas no `SET`.** Mesmo caso.
- **Perda por falta de backup.** O guard reduz a chance de precisar
  restaurar. Não substitui backup, e muito menos restauração testada.

## PostgreSQL

- `session_replication_role = replica` desliga as triggers do guard. É
  privilégio de superusuário. No PostgreSQL 15 ou superior confira se
  alguém ganhou por `GRANT SET`, a consulta está em `05-papeis.sql`.
- Restauração com `pg_restore --clean` executa `DROP` em série e vai
  bater no event trigger. Rode dentro de `BEGIN; SELECT guarda.manutencao(); ...`
  ou desinstale antes de restaurar.
- **Custo.** Uma trigger `BEFORE ... FOR EACH ROW` roda uma vez por linha
  afetada. Em `DELETE` e `UPDATE` de poucas linhas, o custo é irrelevante.
  Em ETL que apaga milhões de linhas por noite, não é. Nesses casos:
  `guarda.liberar()` no início do job, ou `guarda.politica.ativo = false`
  na tabela de carga, com a observação preenchida.
- Comando dentro de função ou procedure conta como comando aninhado. O
  contador soma o nível todo, o que é o comportamento desejado para
  cascata, mas significa que uma procedure que apaga 200 linhas em 10
  tabelas soma 2000.

## SQL Server

- A trigger é `AFTER`. **O comando executa por inteiro e só então é
  desfeito.** Um `DELETE` de 50 milhões de linhas vai gerar log de
  transação, consumir I/O e talvez travar a tabela, antes de ser
  bloqueado. O guard evita a perda de dados, não o susto nem o consumo.
  Se isso for um risco no seu volume, combine com limite de linhas na
  aplicação e monitoramento de crescimento do log.
- `TRUNCATE TABLE` não dispara trigger nenhum. A defesa é `DENY ALTER`,
  porque `TRUNCATE` exige `ALTER` na tabela.
- `BULK INSERT` e `bcp` não disparam triggers por padrão. Isso afeta
  inserção, não exclusão, então está fora do escopo, mas é bom saber.
- A janela de liberação é por tempo (60 segundos por padrão) e não por
  transação, porque `SESSION_CONTEXT` vale para a conexão inteira. Uma
  liberação esquecida deixa de valer sozinha.

## MySQL e MariaDB

Aqui as limitações são maiores, e é honesto dizer isso antes de instalar.

- **`guarda.liberar()` não passa por cima do `sql_safe_updates`.** São duas
  defesas em série, e a nativa vem primeiro. Depois de liberar, um
  `DELETE FROM tabela` sem `WHERE` continua recusado pelo servidor com o
  erro 1175. Para a operação passar, ela precisa de `WHERE` em coluna com
  chave, ou de `LIMIT`. Na prática isso é bom: força o expurgo a ser em
  lotes. Mas confunde quem liberou e continuou levando erro, então está no
  runbook.
- **`ON DELETE CASCADE` não dispara trigger.** Está na documentação do
  MySQL. Um `DELETE` no pai apaga as filhas sem o guard ver nada. Este é
  o ponto cego mais sério. Mitigações:
  1. `guarda.fks_em_cascata` lista todas as FKs afetadas.
  2. Trocar para `ON DELETE RESTRICT` e apagar as filhas explicitamente,
     onde o negócio permitir.
  3. Limite baixo na tabela pai, já que o raio real é um múltiplo dela.
- **Não existe trigger de DDL.** `TRUNCATE`, `DROP TABLE`, `DROP DATABASE`
  e `ALTER TABLE DROP COLUMN` só são barrados por privilégio. `TRUNCATE`
  exige `DROP`, então revogar `DROP` cobre os dois.
- **Bloqueio não fica registrado em `guarda.evento`.** O `SIGNAL` desfaz
  o statement, e com ele o `INSERT` da auditoria. O MySQL não tem
  transação autônoma. Para ter o rastro de quem tentou, use plugin de
  auditoria: `audit_log` (MySQL Enterprise), `server_audit` (MariaDB) ou
  `audit_log_filter` (Percona). A tabela `guarda.evento` guarda o que
  passou, que ainda é útil para LGPD.
- **O contador depende do `performance_schema`.** Sem trigger de
  statement, a única forma de saber onde um comando termina é o
  `EVENT_ID` do `performance_schema`. Se a instrumentação estiver
  desligada, `guarda.id_comando()` devolve 0 e, no padrão, o guard sai de
  cena e deixa a defesa com `sql_safe_updates`. Para falhar fechado em vez
  de aberto: `exigir_performance_schema = sim`. Rode
  `CALL guarda.diagnostico()` depois de qualquer upgrade do servidor.
- **DML dentro de procedure compartilha o mesmo identificador de
  comando.** Uma procedure que faz vários `DELETE` em laço tem o contador
  somando tudo. Job legítimo de expurgo precisa de `CALL guarda.liberar()`
  no início.
- **MyISAM não tem transação.** Se a tabela for MyISAM, o `SIGNAL` aborta
  o comando mas não desfaz o que já foi apagado. `guarda.diagnostico()`
  avisa se existir tabela fora do InnoDB.
- A mensagem do `SIGNAL` é cortada em 128 caracteres pelo MySQL. Por isso
  a mensagem é curta e as instruções ficam em `guarda.como_liberar`.

## O linter

- É análise de texto, não parser de SQL. Vai errar nas duas direções em
  SQL muito fora do comum, principalmente com `WITH`, subconsultas
  profundas e SQL gerado por ORM.
- Só vê o que está em arquivo. Comando digitado no cliente não passa por
  ele, e é justamente aí que os acidentes acontecem. O linter serve para
  migração versionada, não substitui o guard no banco.
- Silenciar uma regra exige motivo entre parênteses. É proposital: se o
  motivo não caber em uma linha, provavelmente o comando merece revisão.

## Regra geral

O guard é a terceira camada, não a primeira.

1. Credencial de leitura no dia a dia, escrita só quando precisa.
2. Autocommit desligado, para dar tempo de olhar o número de linhas.
3. O guard, para quando os dois primeiros falharem.
4. Backup com PITR, restauração testada, para quando o guard falhar.
