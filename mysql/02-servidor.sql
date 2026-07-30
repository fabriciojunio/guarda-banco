-- =====================================================================
-- Guarda: MySQL, etapa 2 de 4: variáveis de servidor e diagnóstico
-- =====================================================================

-- ---------------------------------------------------------------------
-- Proteção nativa do MySQL contra DELETE e UPDATE sem WHERE
--
-- Recusa UPDATE/DELETE que não usem chave no WHERE nem tenham LIMIT.
-- Erro 1175. Vale para conexões novas, e é a defesa que continua de pé
-- mesmo se o performance_schema estiver desligado.
--
-- SET PERSIST exige MySQL 8.0. No MariaDB, coloque em my.cnf:
--     [mysqld]
--     sql_safe_updates = ON
-- ---------------------------------------------------------------------
SET PERSIST sql_safe_updates = ON;

-- Instrumentação usada pelo contador de linhas por comando
UPDATE performance_schema.setup_consumers
   SET ENABLED = 'YES'
 WHERE NAME IN ('events_statements_current', 'global_instrumentation', 'thread_instrumentation');

-- ---------------------------------------------------------------------
-- Views de verificação
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW guarda.sem_protecao AS
SELECT t.TABLE_SCHEMA AS esquema,
       t.TABLE_NAME   AS tabela,
       t.TABLE_ROWS   AS linhas_estimadas,
       t.ENGINE       AS engine
  FROM information_schema.TABLES t
 WHERE t.TABLE_TYPE = 'BASE TABLE'
   AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema',
                              'sys', 'guarda')
   AND NOT EXISTS (
        SELECT 1 FROM information_schema.TRIGGERS tr
         WHERE tr.EVENT_OBJECT_SCHEMA = t.TABLE_SCHEMA
           AND tr.EVENT_OBJECT_TABLE  = t.TABLE_NAME
           AND LEFT(tr.TRIGGER_NAME, 7) = 'guarda_'
   );

-- Ponto cego conhecido: o MySQL não dispara trigger em ação de chave
-- estrangeira. Tudo que estiver nesta lista sai do alcance do guard.
CREATE OR REPLACE VIEW guarda.fks_em_cascata AS
SELECT rc.CONSTRAINT_SCHEMA     AS esquema,
       rc.TABLE_NAME            AS tabela_filha,
       rc.REFERENCED_TABLE_NAME AS tabela_pai,
       rc.DELETE_RULE           AS regra_delete,
       rc.UPDATE_RULE           AS regra_update
  FROM information_schema.REFERENTIAL_CONSTRAINTS rc
 WHERE rc.DELETE_RULE IN ('CASCADE', 'SET NULL')
    OR rc.UPDATE_RULE IN ('CASCADE', 'SET NULL');

-- Quem pode dar TRUNCATE: no MySQL, TRUNCATE exige o privilégio DROP
CREATE OR REPLACE VIEW guarda.quem_pode_truncate AS
SELECT GRANTEE, TABLE_SCHEMA, PRIVILEGE_TYPE
  FROM information_schema.SCHEMA_PRIVILEGES
 WHERE PRIVILEGE_TYPE = 'DROP'
UNION ALL
SELECT GRANTEE, 'todos os bancos', PRIVILEGE_TYPE
  FROM information_schema.USER_PRIVILEGES
 WHERE PRIVILEGE_TYPE IN ('DROP', 'SUPER');

CREATE OR REPLACE VIEW guarda.transacoes_presas AS
SELECT t.trx_mysql_thread_id AS conexao,
       p.USER               AS usuario,
       p.HOST               AS host_cliente,
       t.trx_started        AS aberta_desde,
       TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) AS aberta_ha_seg,
       t.trx_rows_locked    AS linhas_travadas,
       LEFT(IFNULL(t.trx_query, p.INFO), 200) AS ultima_query
  FROM information_schema.INNODB_TRX t
  LEFT JOIN information_schema.PROCESSLIST p
         ON p.ID = t.trx_mysql_thread_id
 WHERE TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) > 300;

CREATE OR REPLACE VIEW guarda.como_liberar AS
SELECT 'START TRANSACTION;' AS passo_1,
       "CALL guarda.liberar('motivo com pelo menos 15 caracteres');" AS passo_2,
       'seu comando aqui;' AS passo_3,
       'confira o numero de linhas afetadas' AS passo_4,
       'COMMIT; ou ROLLBACK;' AS passo_5;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Diagnóstico: rode antes de instalar e depois de cada atualização
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS guarda.diagnostico $$
CREATE PROCEDURE guarda.diagnostico()
BEGIN
    SELECT 'performance_schema' AS item,
           IF(@@performance_schema = 1, 'OK', 'PROBLEMA') AS situacao,
           IF(@@performance_schema = 1,
              'ligado',
              'desligado: o contador de linhas por comando nao funciona') AS detalhe
    UNION ALL
    SELECT 'events_statements_current',
           IF((SELECT ENABLED FROM performance_schema.setup_consumers
                WHERE NAME = 'events_statements_current') = 'YES', 'OK', 'PROBLEMA'),
           'consumidor usado por guarda.id_comando()'
    UNION ALL
    SELECT 'id_comando responde',
           IF(guarda.id_comando() > 0, 'OK', 'PROBLEMA'),
           CONCAT('valor atual: ', guarda.id_comando())
    UNION ALL
    SELECT 'sql_safe_updates',
           IF(@@GLOBAL.sql_safe_updates = 1, 'OK', 'PROBLEMA'),
           'defesa nativa contra DELETE/UPDATE sem WHERE'
    UNION ALL
    SELECT 'autocommit da sua sessao',
           IF(@@autocommit = 1, 'ATENCAO', 'OK'),
           IF(@@autocommit = 1,
              'ligado: sem chance de ROLLBACK depois de ver o resultado',
              'desligado')
    UNION ALL
    SELECT 'tabelas sem protecao',
           IF((SELECT COUNT(*) FROM guarda.sem_protecao) = 0, 'OK', 'ATENCAO'),
           CONCAT((SELECT COUNT(*) FROM guarda.sem_protecao), ' tabela(s). Veja guarda.sem_protecao')
    UNION ALL
    SELECT 'FKs em cascata (ponto cego)',
           IF((SELECT COUNT(*) FROM guarda.fks_em_cascata) = 0, 'OK', 'ATENCAO'),
           CONCAT((SELECT COUNT(*) FROM guarda.fks_em_cascata),
                  ' FK(s). MySQL nao dispara trigger em cascata de FK. Veja guarda.fks_em_cascata')
    UNION ALL
    SELECT 'engine das tabelas',
           IF((SELECT COUNT(*) FROM information_schema.TABLES
                WHERE TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB'
                  AND TABLE_SCHEMA NOT IN ('mysql','information_schema',
                                           'performance_schema','sys')) = 0, 'OK', 'ATENCAO'),
           'tabela MyISAM nao tem transacao: bloqueio nao desfaz o que ja foi feito';
END $$

DELIMITER ;

CALL guarda.diagnostico();
