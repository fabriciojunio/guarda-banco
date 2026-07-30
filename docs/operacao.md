# Operação

Runbook do dia a dia. As instruções mudam por engine, então cada seção
está marcada.

## Preciso apagar mais linhas do que o limite

A ideia é sempre a mesma: declarar a intenção, ver o número real de linhas
e só então confirmar.

### PostgreSQL

```sql
BEGIN;
SELECT guarda.liberar('expurgo de logs anteriores a 2023, OS-4821');

DELETE FROM log_acesso WHERE criado_em < '2023-01-01';
-- olhe o "DELETE 482913" e decida

COMMIT;   -- ou ROLLBACK, se o número não fizer sentido
```

A liberação vale só dentro desta transação. Se o seu cliente estiver com
autocommit ligado, o `SELECT guarda.liberar(...)` roda sozinho, a
liberação morre antes do `DELETE`, e você vai levar o bloqueio de novo.
Isso é de propósito: sem transação você não teria como desfazer.

### SQL Server

```sql
EXEC guarda.liberar N'expurgo de logs anteriores a 2023, OS-4821';

BEGIN TRANSACTION;
DELETE FROM dbo.log_acesso WHERE criado_em < '2023-01-01';
-- olhe as linhas afetadas
COMMIT;   -- ou ROLLBACK
```

A liberação expira em 60 segundos (`janela_liberacao_seg`). Se você parar
para pensar, ela fecha e é só chamar de novo.

### MySQL

```sql
START TRANSACTION;
CALL guarda.liberar('expurgo de logs anteriores a 2023, OS-4821');

DELETE FROM log_acesso WHERE criado_em < '2023-01-01' LIMIT 5000;
-- olhe as linhas afetadas

COMMIT;   -- ou ROLLBACK
```

Repare no `LIMIT`. No MySQL existem duas defesas em série, e a liberação
vale só para a de dentro:

- `sql_safe_updates`, que é do servidor, recusa `UPDATE` e `DELETE` sem
  `WHERE` em coluna com chave e sem `LIMIT`. **`guarda.liberar()` não
  desliga isso**, e o erro que aparece é o 1175.
- o guard, que conta linhas, é o que a liberação destrava.

Ou seja, no MySQL o expurgo grande sempre sai em lote, com `LIMIT` ou com
filtro em chave. Se você liberou e continua levando erro, olhe a mensagem:
se ela fala em "safe update mode", o problema é o comando, não a liberação.

## Melhor ainda: apague em lotes

Expurgo grande em um comando único trava tabela, incha log de transação e
transforma um `ROLLBACK` em meia hora de espera. Lote resolve os três.

```sql
-- PostgreSQL
DO $$
DECLARE
    apagadas integer;
BEGIN
    LOOP
        WITH alvo AS (
            SELECT id FROM log_acesso
             WHERE criado_em < '2023-01-01'
             ORDER BY id
             LIMIT 5000
        )
        DELETE FROM log_acesso
         WHERE id IN (SELECT id FROM alvo);

        GET DIAGNOSTICS apagadas = ROW_COUNT;
        EXIT WHEN apagadas = 0;
        RAISE NOTICE 'lote de % linhas', apagadas;
        COMMIT;               -- precisa de procedure, ou rode o laço no cliente
    END LOOP;
END;
$$;
```

Com lote de 5000 e limite de 500, você ainda precisa liberar. O caminho
mais limpo é subir o limite daquela tabela na política, com observação:

```sql
INSERT INTO guarda.politica (esquema, tabela, limite_delete, observacao)
VALUES ('public', 'log_acesso', 10000, 'tabela de log, expurgo diario em lotes de 5000')
ON CONFLICT (esquema, tabela) DO UPDATE
   SET limite_delete = excluded.limite_delete,
       observacao    = excluded.observacao;
```

## Fui bloqueado e não entendi por quê

A mensagem diz a tabela, o número de linhas e o limite. Na ordem:

1. Rode o mesmo `WHERE` como `SELECT count(*)`. Quase sempre o número
   surpreende, e aí o guard fez o trabalho dele.
2. Se o número faz sentido, veja o limite daquela tabela:
   ```sql
   SELECT * FROM guarda.politica WHERE tabela = 'sua_tabela';
   ```
3. Se o número não faz sentido, procure cascata:
   ```sql
   -- PostgreSQL
   SELECT conrelid::regclass AS filha, confrelid::regclass AS pai, confdeltype
     FROM pg_constraint WHERE contype = 'f' AND confdeltype <> 'a';
   -- MySQL
   SELECT * FROM guarda.fks_em_cascata;
   ```

## Quem tentou apagar a tabela?

**PostgreSQL.** O bloqueio desfaz a transação, e com ela a auditoria. Por
isso o registro vai para o log do servidor como `WARNING`. Confira que o
log está capturando:

```sql
SHOW log_min_messages;    -- precisa ser 'warning' ou mais verboso
```

E para procurar:

```
grep "GUARDA bloqueou" /var/log/postgresql/postgresql-*.log
```

Vale mandar esse padrão para o coletor de logs e criar alerta. Bloqueio
repetido pela mesma pessoa na mesma tabela costuma ser processo errado, não
descuido.

**SQL Server.** O bloqueio fica em `guarda.evento` com `resultado =
'bloqueado'`, porque o `ROLLBACK` dentro do trigger acontece antes do
`INSERT` da auditoria.

```sql
SELECT TOP 50 * FROM guarda.evento WHERE resultado = 'bloqueado'
 ORDER BY ocorrido_em DESC;
```

**MySQL.** Não fica registrado, ver `docs/limitacoes.md`. Precisa de plugin
de auditoria.

## Rotina semanal

```sql
-- 1. nenhuma tabela ficou de fora
SELECT * FROM guarda.sem_protecao;

-- 2. ninguém desativou a proteção
SELECT * FROM guarda.politica WHERE ativo = false;      -- deve ter observacao
SELECT * FROM guarda.triggers_desativados;              -- SQL Server

-- 3. o que passou de grande
SELECT * FROM guarda.painel_30d ORDER BY dia DESC;

-- 4. transação aberta e esquecida segurando lock
SELECT * FROM guarda.transacoes_presas;

-- 5. MySQL: instrumentação continua de pé depois do último upgrade
CALL guarda.diagnostico();
```

O item 1 é o que mais importa. Tabela nova sem proteção é como o sistema
morre: em três meses metade do banco está fora. No PostgreSQL e no SQL
Server a adoção é automática por DDL trigger. No MySQL não existe DDL
trigger, então rode `CALL guarda.gerar('seu_banco')` depois de cada
migração que crie tabela.

## Carga, ETL e restauração

Job legítimo que mexe em muita linha tem três caminhos, do melhor para o
pior:

1. Limite próprio na política daquela tabela. Fica documentado e continua
   protegendo contra o erro humano.
2. `liberar()` no início do job, com motivo que aponte para o job.
3. `politica.ativo = false` naquela tabela, com `observacao` explicando.
   Vale para tabela de staging que é recriada a cada carga.

Restauração de dump é caso à parte: `pg_restore --clean` roda uma
sequência de `DROP` e vai bater no event trigger. Rode dentro de
`BEGIN; SELECT guarda.manutencao();` ou desinstale, restaure e instale de
novo.

## Mudar limite global

```sql
UPDATE guarda.config SET valor = '1000' WHERE chave = 'limite_delete_padrao';
```

Vale imediatamente, sem reiniciar nada, porque o limite é lido a cada
comando. Se você está aumentando o limite global porque "estava atrapalhando",
pare e olhe `guarda.painel_30d` primeiro: o normal é subir limite de uma
tabela específica, não do banco todo.

## Desinstalar

Cada engine tem seu `99-desinstalar.sql`. Todos preservam `guarda.evento`
por padrão, porque o registro de exclusão de dado pessoal tem valor legal
(LGPD art. 37) e some junto com o esquema se você derrubar tudo.
