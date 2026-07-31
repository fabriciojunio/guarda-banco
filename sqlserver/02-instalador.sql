/* =====================================================================
   Guarda: SQL Server, etapa 2 de 4: gerador de triggers DML

   No SQL Server o trigger é AFTER: o comando executa, o trigger conta
   as linhas em "deleted" e desfaz. Ou seja, o servidor paga o custo de
   fazer e desfazer. Em troca, a contagem é exata e o ROLLBACK dentro do
   trigger é o que permite gravar a auditoria do bloqueio.
   ===================================================================== */

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE guarda.instalar
    @esquema sysname,
    @tabela  sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(QUOTENAME(@esquema) + '.' + QUOTENAME(@tabela), 'U') IS NULL
    BEGIN
        DECLARE @erro nvarchar(300) = CONCAT('GUARDA: ', @esquema, '.', @tabela, ' não existe.');
        THROW 50020, @erro, 1;
    END

    IF EXISTS (SELECT 1 FROM sys.tables
                WHERE object_id = OBJECT_ID(QUOTENAME(@esquema) + '.' + QUOTENAME(@tabela))
                  AND is_memory_optimized = 1)
    BEGIN
        PRINT CONCAT('GUARDA: ', @esquema, '.', @tabela,
                     ' é memory optimized e não aceita trigger AFTER. Pulada.');
        RETURN;
    END

    DECLARE @trg sysname = LEFT('guarda_dml_' + @tabela, 128);

    DECLARE @tpl nvarchar(max) = N'
CREATE OR ALTER TRIGGER {ESQQ}.{TRGQ} ON {ESQQ}.{TABQ}
AFTER DELETE, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @linhas bigint = (SELECT COUNT_BIG(*) FROM deleted);
    IF @linhas = 0 RETURN;

    DECLARE @comando varchar(10) =
        CASE WHEN EXISTS (SELECT 1 FROM inserted) THEN ''UPDATE'' ELSE ''DELETE'' END;

    DECLARE @limite   int = guarda.limite(N''{ESQ}'', N''{TAB}'', @comando);
    DECLARE @liberado bit = guarda.esta_liberado();

    IF @liberado = 0 AND @limite IS NOT NULL AND @linhas > @limite
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        EXEC guarda.registrar ''bloqueado'', @comando, N''{ESQ}'', N''{TAB}'', @linhas, @limite;

        DECLARE @msg nvarchar(2048) = CONCAT(
            N''GUARDA: '', @comando, N'' em {ESQ}.{TAB} afetaria '', @linhas,
            N'' linhas, limite '', @limite,
            N''. Bloqueado. Causa provavel: WHERE mais amplo do que o pretendido, ''
            + N''ou cascata inesperada. Se a operacao e intencional, chame ''
            + N''guarda.liberar informando o motivo e repita o comando dentro de ''
            + N''BEGIN TRANSACTION, conferindo o total antes do COMMIT.'');

        THROW 50001, @msg, 1;
    END

    IF @liberado = 1 OR @linhas >= guarda.num_config(''registrar_acima_de'', 100)
    BEGIN
        DECLARE @res varchar(10) = CASE WHEN @liberado = 1 THEN ''liberado'' ELSE ''permitido'' END;
        EXEC guarda.registrar @res, @comando, N''{ESQ}'', N''{TAB}'', @linhas, @limite;
    END
END';

    DECLARE @sql nvarchar(max) =
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@tpl,
            '{ESQQ}', QUOTENAME(@esquema)),
            '{TABQ}', QUOTENAME(@tabela)),
            '{TRGQ}', QUOTENAME(@trg)),
            '{ESQ}',  REPLACE(@esquema, '''', '''''')),
            '{TAB}',  REPLACE(@tabela,  '''', ''''''));

    EXEC sys.sp_executesql @sql;
END
GO

/* ---------------------------------------------------------------------
   Remoção por tabela
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE guarda.desinstalar
    @esquema sysname,
    @tabela  sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql nvarchar(max) = N'';

    SELECT @sql = @sql + N'DROP TRIGGER ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name) + N';' + CHAR(10)
      FROM sys.triggers tr
      JOIN sys.tables  t ON t.object_id = tr.parent_id
      JOIN sys.schemas s ON s.schema_id = t.schema_id
     WHERE s.name = @esquema
       AND t.name = @tabela
       AND tr.name LIKE 'guarda[_]dml[_]%';

    IF LEN(@sql) > 0
    BEGIN
        EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = 1;
        EXEC sys.sp_executesql @sql;
        EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = NULL;
    END
END
GO

/* ---------------------------------------------------------------------
   Instalação em lote
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE guarda.instalar_banco
    @esquema sysname = NULL      -- NULL = todos os esquemas de usuário
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @esq sysname, @tab sysname;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.name, t.name
          FROM sys.tables t
          JOIN sys.schemas s ON s.schema_id = t.schema_id
         WHERE t.is_ms_shipped = 0
           AND s.name NOT IN ('guarda', 'sys')
           AND (@esquema IS NULL OR s.name = @esquema)
         ORDER BY s.name, t.name;

    OPEN cur;
    FETCH NEXT FROM cur INTO @esq, @tab;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC guarda.instalar @esq, @tab;
            PRINT CONCAT('protegida: ', @esq, '.', @tab);
        END TRY
        BEGIN CATCH
            PRINT CONCAT('FALHOU: ', @esq, '.', @tab, ' -> ', ERROR_MESSAGE());
        END CATCH

        FETCH NEXT FROM cur INTO @esq, @tab;
    END

    CLOSE cur;
    DEALLOCATE cur;
END
GO

CREATE OR ALTER PROCEDURE guarda.desinstalar_banco
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql nvarchar(max) = N'';

    SELECT @sql = @sql + N'DROP TRIGGER ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name) + N';' + CHAR(10)
      FROM sys.triggers tr
      JOIN sys.tables  t ON t.object_id = tr.parent_id
      JOIN sys.schemas s ON s.schema_id = t.schema_id
     WHERE tr.name LIKE 'guarda[_]dml[_]%';

    EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = 1;
    IF LEN(@sql) > 0 EXEC sys.sp_executesql @sql;
    EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = NULL;
END
GO

/* ---------------------------------------------------------------------
   Verificação e relatórios
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW guarda.sem_protecao
AS
SELECT s.name AS esquema,
       t.name AS tabela,
       (SELECT SUM(ps.row_count)
          FROM sys.dm_db_partition_stats ps
         WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) AS linhas,
       CASE WHEN t.is_memory_optimized = 1 THEN 'memory optimized, não aceita trigger'
            ELSE 'sem trigger do guarda' END AS motivo
  FROM sys.tables  t
  JOIN sys.schemas s ON s.schema_id = t.schema_id
 WHERE t.is_ms_shipped = 0
   AND s.name NOT IN ('guarda', 'sys')
   AND NOT EXISTS (SELECT 1 FROM sys.triggers tr
                    WHERE tr.parent_id = t.object_id
                      AND tr.name LIKE 'guarda[_]dml[_]%');
GO

CREATE OR ALTER VIEW guarda.triggers_desativados
AS
SELECT s.name AS esquema, t.name AS tabela, tr.name AS trigger_nome
  FROM sys.triggers tr
  JOIN sys.tables  t ON t.object_id = tr.parent_id
  JOIN sys.schemas s ON s.schema_id = t.schema_id
 WHERE tr.name LIKE 'guarda[_]dml[_]%'
   AND tr.is_disabled = 1;
GO

CREATE OR ALTER VIEW guarda.painel_30d
AS
SELECT CONVERT(date, ocorrido_em) AS dia,
       resultado,
       comando,
       usuario,
       COUNT_BIG(*) AS ocorrencias,
       SUM(linhas)  AS linhas_afetadas
  FROM guarda.evento
 WHERE ocorrido_em >= DATEADD(DAY, -30, SYSDATETIME())
 GROUP BY CONVERT(date, ocorrido_em), resultado, comando, usuario;
GO

CREATE OR ALTER VIEW guarda.transacoes_presas
AS
SELECT s.session_id,
       s.login_name,
       s.program_name,
       s.host_name,
       s.status,
       t.transaction_begin_time,
       DATEDIFF(SECOND, t.transaction_begin_time, SYSDATETIME()) AS aberta_ha_seg,
       (SELECT TOP 1 SUBSTRING(txt.text, 1, 400)
          FROM sys.dm_exec_requests r
         CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) txt
         WHERE r.session_id = s.session_id) AS ultima_query
  FROM sys.dm_tran_session_transactions st
  JOIN sys.dm_tran_active_transactions  t ON t.transaction_id = st.transaction_id
  JOIN sys.dm_exec_sessions             s ON s.session_id = st.session_id
 WHERE DATEDIFF(SECOND, t.transaction_begin_time, SYSDATETIME()) > 300
   AND s.status = 'sleeping';
GO
