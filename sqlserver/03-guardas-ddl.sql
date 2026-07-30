/* =====================================================================
   Guarda: SQL Server, etapa 3 de 4: proteção de DDL

   Cobre DROP TABLE, DROP SCHEMA, DROP VIEW, DROP INDEX, DROP TRIGGER,
   ALTER TABLE DROP COLUMN e a desativação do próprio guarda.

   TRUNCATE não dispara trigger nenhum no SQL Server. A única defesa é
   privilégio: TRUNCATE exige ALTER na tabela, então basta não conceder
   ALTER a quem opera o banco. Ver 04-permissoes.sql.

   DROP DATABASE precisa de trigger de servidor, no fim do arquivo.
   ===================================================================== */

SET NOCOUNT ON;
GO

CREATE OR ALTER TRIGGER guarda_ddl ON DATABASE
FOR DROP_TABLE, DROP_SCHEMA, DROP_VIEW, DROP_INDEX, DROP_TRIGGER,
    DROP_PROCEDURE, DROP_FUNCTION, ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRY_CONVERT(int, SESSION_CONTEXT(N'guarda_manutencao')) = 1 RETURN;

    DECLARE @dados xml = EVENTDATA();
    DECLARE @evento  varchar(60)   = @dados.value('(/EVENT_INSTANCE/EventType)[1]', 'varchar(60)');
    DECLARE @esquema sysname       = @dados.value('(/EVENT_INSTANCE/SchemaName)[1]', 'sysname');
    DECLARE @objeto  sysname       = @dados.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname');
    DECLARE @texto   nvarchar(max) = @dados.value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', 'nvarchar(max)');

    DECLARE @liberado  bit = guarda.esta_liberado();
    DECLARE @admin     bit = guarda.eh_admin();
    DECLARE @bloqueia  bit = CASE WHEN guarda.txt_config('proteger_ddl') = N'sim' THEN 1 ELSE 0 END;
    DECLARE @motivo_bloqueio nvarchar(400) = NULL;

    /* 1. o próprio guarda nunca é removido por acidente */
    IF @esquema = N'guarda'
        SET @motivo_bloqueio = N'objeto do esquema guarda';

    IF @evento = 'DROP_TRIGGER' AND @objeto LIKE 'guarda[_]dml[_]%'
        SET @motivo_bloqueio = N'trigger de protecao do guarda';

    IF @evento = 'ALTER_TABLE' AND @texto LIKE '%DISABLE%TRIGGER%'
        SET @motivo_bloqueio = N'desativacao de trigger';

    /* 2. DDL destrutivo comum */
    IF @motivo_bloqueio IS NULL AND @bloqueia = 1 AND @liberado = 0 AND @admin = 0
    BEGIN
        IF @evento IN ('DROP_TABLE', 'DROP_SCHEMA', 'DROP_VIEW', 'DROP_INDEX',
                       'DROP_PROCEDURE', 'DROP_FUNCTION', 'DROP_TRIGGER')
            SET @motivo_bloqueio = N'DDL destrutivo sem liberacao';

        IF @evento = 'ALTER_TABLE' AND @texto LIKE '%DROP%COLUMN%'
            SET @motivo_bloqueio = N'remocao de coluna sem liberacao';
    END

    IF @motivo_bloqueio IS NOT NULL
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        EXEC guarda.registrar 'bloqueado', @evento, @esquema, @objeto, NULL, NULL, @texto;

        DECLARE @msg nvarchar(2048) = CONCAT(
            N'GUARDA: ', @evento, N' em ', @esquema, N'.', @objeto,
            N' bloqueado (', @motivo_bloqueio,
            N'). Se for intencional, chame guarda.liberar informando o motivo ',
            N'e repita o comando em seguida.');

        THROW 50002, @msg, 1;
    END

    /* 3. passou: fica o rastro */
    DECLARE @res varchar(10) = CASE WHEN @liberado = 1 THEN 'liberado' ELSE 'permitido' END;

    IF @evento <> 'ALTER_TABLE' OR @texto LIKE '%DROP%COLUMN%' OR @texto LIKE '%ALTER%COLUMN%'
        EXEC guarda.registrar @res, @evento, @esquema, @objeto, NULL, NULL, @texto;
END
GO

/* ---------------------------------------------------------------------
   Adoção automática de tabelas novas

   Sem isso, toda tabela criada depois da implantação nasce sem proteção,
   que é como esse tipo de sistema morre na prática.
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER guarda_ddl_create ON DATABASE
FOR CREATE_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dados xml = EVENTDATA();
    DECLARE @esquema sysname = @dados.value('(/EVENT_INSTANCE/SchemaName)[1]', 'sysname');
    DECLARE @objeto  sysname = @dados.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname');

    IF @esquema = N'guarda' RETURN;

    BEGIN TRY
        EXEC guarda.instalar @esquema, @objeto;
    END TRY
    BEGIN CATCH
        PRINT CONCAT('GUARDA: nao consegui proteger a tabela nova ',
                     @esquema, '.', @objeto, ' -> ', ERROR_MESSAGE());
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   DROP DATABASE

   Precisa de trigger no nível do servidor e de permissão CONTROL SERVER
   para criar. Rode conectado ao master, com um login sysadmin.
   Se você não tem esse acesso, a defesa é não ter dbcreator nem ser
   dono do banco. Ver 04-permissoes.sql.
   --------------------------------------------------------------------- */
/*
USE master;
GO

CREATE OR ALTER TRIGGER guarda_srv_drop_database ON ALL SERVER
FOR DROP_DATABASE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dados xml = EVENTDATA();
    DECLARE @banco sysname = @dados.value('(/EVENT_INSTANCE/DatabaseName)[1]', 'sysname');

    -- ajuste a lista: bancos que não podem ser removidos assim
    IF @banco IN (N'producao', N'financeiro', N'rh')
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @msg nvarchar(600) = CONCAT(
            N'GUARDA: DROP DATABASE de ', @banco, N' bloqueado. ',
            N'Remova a protecao no trigger guarda_srv_drop_database primeiro.');
        THROW 50003, @msg, 1;
    END
END
GO
*/
