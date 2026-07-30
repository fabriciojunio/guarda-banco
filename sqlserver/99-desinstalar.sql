/* =====================================================================
   Guarda: SQL Server, remoção completa

   Preserva guarda.evento por padrão: o histórico de exclusão de dado
   pessoal tem valor legal (LGPD art. 37). O bloco final, comentado,
   derruba tudo.
   ===================================================================== */

SET NOCOUNT ON;
GO

EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = 1;
GO

IF OBJECT_ID('guarda.desinstalar_banco') IS NOT NULL EXEC guarda.desinstalar_banco;
GO

IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'guarda_ddl' AND parent_class_desc = 'DATABASE')
    DROP TRIGGER guarda_ddl ON DATABASE;

IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'guarda_ddl_create' AND parent_class_desc = 'DATABASE')
    DROP TRIGGER guarda_ddl_create ON DATABASE;
GO

-- confere que não sobrou trigger do guarda
SELECT s.name AS esquema, t.name AS tabela, tr.name AS trigger_nome
  FROM sys.triggers tr
  JOIN sys.tables  t ON t.object_id = tr.parent_id
  JOIN sys.schemas s ON s.schema_id = t.schema_id
 WHERE tr.name LIKE 'guarda[_]dml[_]%';
GO

EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = NULL;
GO

/* No servidor, se o trigger de DROP DATABASE foi criado:
USE master;
DROP TRIGGER guarda_srv_drop_database ON ALL SERVER;
GO
*/

/* Guarda o histórico e derruba o resto:
SELECT * INTO dbo.guarda_evento_arquivo FROM guarda.evento;
GO
DROP VIEW  guarda.sem_protecao;
DROP VIEW  guarda.triggers_desativados;
DROP VIEW  guarda.painel_30d;
DROP VIEW  guarda.transacoes_presas;
DROP PROCEDURE guarda.instalar;
DROP PROCEDURE guarda.desinstalar;
DROP PROCEDURE guarda.instalar_banco;
DROP PROCEDURE guarda.desinstalar_banco;
DROP PROCEDURE guarda.liberar;
DROP PROCEDURE guarda.bloquear;
DROP PROCEDURE guarda.registrar;
DROP FUNCTION  guarda.limite;
DROP FUNCTION  guarda.esta_liberado;
DROP FUNCTION  guarda.motivo;
DROP FUNCTION  guarda.eh_admin;
DROP FUNCTION  guarda.txt_config;
DROP FUNCTION  guarda.num_config;
DROP TABLE     guarda.evento;
DROP TABLE     guarda.politica;
DROP TABLE     guarda.config;
DROP SCHEMA    guarda;
GO
*/
