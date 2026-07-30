/* =====================================================================
   Guarda: SQL Server, etapa 4 de 4: permissões

   Trigger nenhuma segura o que privilégio deveria ter barrado antes.
   Leia e ajuste os nomes antes de executar.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   Papéis
   --------------------------------------------------------------------- */
IF DATABASE_PRINCIPAL_ID('guarda_admin') IS NULL CREATE ROLE guarda_admin;
IF DATABASE_PRINCIPAL_ID('app_leitura')  IS NULL CREATE ROLE app_leitura;
IF DATABASE_PRINCIPAL_ID('app_escrita')  IS NULL CREATE ROLE app_escrita;
GO

/* ---------------------------------------------------------------------
   O guarda precisa ser legível e chamável por quem opera o banco.
   As tabelas de configuração são somente leitura para eles: quem muda
   limite é o DBA.
   --------------------------------------------------------------------- */
GRANT SELECT  ON SCHEMA::guarda TO app_leitura, app_escrita;
GRANT EXECUTE ON SCHEMA::guarda TO app_leitura, app_escrita;

DENY INSERT, UPDATE, DELETE ON guarda.config    TO app_leitura, app_escrita;
DENY INSERT, UPDATE, DELETE ON guarda.politica  TO app_leitura, app_escrita;
DENY UPDATE, DELETE         ON guarda.evento    TO app_leitura, app_escrita;

-- instalar e desinstalar ligam o modo manutenção. Só DBA.
DENY EXECUTE ON guarda.instalar          TO app_leitura, app_escrita;
DENY EXECUTE ON guarda.desinstalar       TO app_leitura, app_escrita;
DENY EXECUTE ON guarda.instalar_banco    TO app_leitura, app_escrita;
DENY EXECUTE ON guarda.desinstalar_banco TO app_leitura, app_escrita;
GO

/* ---------------------------------------------------------------------
   Dados
   --------------------------------------------------------------------- */
GRANT SELECT ON SCHEMA::dbo TO app_leitura;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO app_escrita;

/* Ponto mais importante deste arquivo.

   TRUNCATE TABLE não dispara trigger nenhum no SQL Server, e exige
   permissão ALTER na tabela. Negar ALTER mata TRUNCATE e mata também
   ALTER TABLE DROP COLUMN na origem, sem depender do DDL trigger. */
DENY ALTER ON SCHEMA::dbo TO app_leitura, app_escrita;

/* DDL em geral fica fora */
DENY CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION
    TO app_leitura, app_escrita;
GO

/* ---------------------------------------------------------------------
   Contas nominais

   Login compartilhado destrói a auditoria: guarda.evento passa a dizer
   "foi o usuário app" em todo incidente. Uma conta por pessoa, e escrita
   concedida por cima da leitura.
   --------------------------------------------------------------------- */
-- CREATE USER [DOMINIO\maria.silva] FOR LOGIN [DOMINIO\maria.silva];
-- ALTER ROLE app_leitura ADD MEMBER [DOMINIO\maria.silva];
-- ALTER ROLE app_escrita ADD MEMBER [DOMINIO\maria.silva];

/* ---------------------------------------------------------------------
   Conferências

   O guarda não vale nada para quem é sysadmin ou db_owner: essas contas
   passam por cima de qualquer DENY e podem remover trigger. A lista
   precisa ser curta e conhecida.
   --------------------------------------------------------------------- */
SELECT 'sysadmin' AS papel, sp.name AS login_nome
  FROM sys.server_role_members rm
  JOIN sys.server_principals r  ON r.principal_id = rm.role_principal_id
  JOIN sys.server_principals sp ON sp.principal_id = rm.member_principal_id
 WHERE r.name = 'sysadmin'
UNION ALL
SELECT 'dbcreator', sp.name
  FROM sys.server_role_members rm
  JOIN sys.server_principals r  ON r.principal_id = rm.role_principal_id
  JOIN sys.server_principals sp ON sp.principal_id = rm.member_principal_id
 WHERE r.name = 'dbcreator';
GO

SELECT dp.name AS usuario, r.name AS papel_no_banco
  FROM sys.database_role_members rm
  JOIN sys.database_principals r  ON r.principal_id = rm.role_principal_id
  JOIN sys.database_principals dp ON dp.principal_id = rm.member_principal_id
 WHERE r.name IN ('db_owner', 'db_ddladmin', 'db_datawriter')
 ORDER BY r.name, dp.name;
GO

/* Quem pode desativar trigger no banco todo */
SELECT p.name AS usuario, perm.permission_name, perm.state_desc
  FROM sys.database_permissions perm
  JOIN sys.database_principals p ON p.principal_id = perm.grantee_principal_id
 WHERE perm.permission_name IN ('ALTER', 'ALTER ANY DATABASE DDL TRIGGER', 'CONTROL')
   AND perm.state_desc = 'GRANT';
GO
