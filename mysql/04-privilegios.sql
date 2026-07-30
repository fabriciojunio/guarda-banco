-- =====================================================================
-- Guarda: MySQL, etapa 4 de 4: privilégios
--
-- No MySQL este arquivo é mais importante que nos outros bancos, porque
-- o MySQL não tem trigger de DDL. TRUNCATE, DROP TABLE e DROP DATABASE
-- não passam por trigger nenhum: quem barra é o privilégio.
--
-- Leia e ajuste os nomes antes de executar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Papéis (MySQL 8.0). No MariaDB a sintaxe de CREATE ROLE é parecida,
-- mas confira antes.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS app_leitura, app_escrita, guarda_admin;

-- Troque `loja` pelo seu banco de dados
GRANT SELECT ON loja.* TO app_leitura;
GRANT SELECT, INSERT, UPDATE, DELETE ON loja.* TO app_escrita;

-- O guard precisa ser chamável e legível
GRANT SELECT   ON guarda.*          TO app_leitura, app_escrita;
GRANT EXECUTE  ON guarda.*          TO app_leitura, app_escrita;
GRANT INSERT   ON guarda.evento     TO app_escrita;

-- ---------------------------------------------------------------------
-- Ponto mais importante deste arquivo
--
-- TRUNCATE TABLE exige o privilégio DROP no MySQL, e não dispara
-- trigger nenhum. Nenhum GRANT de DROP para quem opera o dia a dia.
--
-- DROP e ALTER também cobrem DROP TABLE e ALTER TABLE DROP COLUMN, que
-- também não têm trigger. Não conceda.
-- ---------------------------------------------------------------------
REVOKE DROP, ALTER, CREATE, REFERENCES, INDEX ON loja.* FROM app_escrita;
REVOKE DROP, ALTER, CREATE, REFERENCES, INDEX ON loja.* FROM app_leitura;

-- ---------------------------------------------------------------------
-- Contas nominais
--
-- Login compartilhado destrói a auditoria: guarda.evento passa a dizer
-- "foi o usuário app" em todo incidente. Uma conta por pessoa, com
-- escrita concedida por cima da leitura.
-- ---------------------------------------------------------------------
-- CREATE USER 'maria.silva'@'%' IDENTIFIED BY '...' PASSWORD EXPIRE INTERVAL 90 DAY;
-- GRANT app_leitura TO 'maria.silva'@'%';
-- GRANT app_escrita TO 'maria.silva'@'%';
-- SET DEFAULT ROLE app_leitura TO 'maria.silva'@'%';   -- padrão do dia é leitura

FLUSH PRIVILEGES;

-- ---------------------------------------------------------------------
-- Conferências
-- ---------------------------------------------------------------------

-- Quem tem privilégio destrutivo global. A lista precisa ser curta.
SELECT GRANTEE, PRIVILEGE_TYPE
  FROM information_schema.USER_PRIVILEGES
 WHERE PRIVILEGE_TYPE IN ('SUPER', 'DROP', 'ALTER', 'CREATE USER', 'RELOAD',
                          'SHUTDOWN', 'TRIGGER')
 ORDER BY GRANTEE, PRIVILEGE_TYPE;

-- Quem pode criar ou remover trigger, ou seja, quem pode desligar o guard
SELECT GRANTEE, TABLE_SCHEMA, PRIVILEGE_TYPE
  FROM information_schema.SCHEMA_PRIVILEGES
 WHERE PRIVILEGE_TYPE = 'TRIGGER'
 ORDER BY GRANTEE;

-- Contas sem senha ou com host aberto
SELECT user, host, plugin,
       IF(authentication_string = '', 'SEM SENHA', 'ok') AS senha
  FROM mysql.user
 WHERE authentication_string = '' OR host = '%'
 ORDER BY user;

-- Chaves estrangeiras em cascata: ponto cego do guard no MySQL
SELECT * FROM guarda.fks_em_cascata;
