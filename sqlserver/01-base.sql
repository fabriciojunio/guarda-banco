/* =====================================================================
   Guarda: trilhos de segurança contra DML/DDL destrutivo acidental
   SQL Server: etapa 1 de 4: esquema, configuração, auditoria e liberação

   Requer SQL Server 2016 ou superior (usa SESSION_CONTEXT).
   Execute no banco a proteger, com um login que tenha db_owner.
   ===================================================================== */

SET NOCOUNT ON;
GO

IF SCHEMA_ID('guarda') IS NULL EXEC('CREATE SCHEMA guarda');
GO

/* ---------------------------------------------------------------------
   Configuração global
   --------------------------------------------------------------------- */
IF OBJECT_ID('guarda.config') IS NULL
CREATE TABLE guarda.config (
    chave     varchar(60)    NOT NULL PRIMARY KEY,
    valor     nvarchar(200)  NOT NULL,
    descricao nvarchar(400)  NOT NULL
);
GO

MERGE guarda.config AS destino
USING (VALUES
    ('ambiente', N'producao',
     N'producao | homologacao | desenvolvimento. Informativo, aparece na auditoria.'),
    ('limite_delete_padrao', N'500',
     N'Linhas que um DELETE pode remover sem liberação explícita.'),
    ('limite_update_padrao', N'500',
     N'Linhas que um UPDATE pode alterar sem liberação explícita.'),
    ('registrar_acima_de', N'100',
     N'Operações permitidas acima deste número de linhas vão para guarda.evento.'),
    ('exigir_justificativa', N'sim',
     N'Se sim, guarda.liberar exige motivo com no mínimo 15 caracteres.'),
    ('janela_liberacao_seg', N'60',
     N'Segundos de validade da liberação. Curta de propósito.'),
    ('papel_admin', N'guarda_admin',
     N'Papel de banco que faz DDL destrutivo sem passar pela liberação.'),
    ('proteger_ddl', N'sim',
     N'Se não, o DDL trigger para de bloquear e apenas registra.')
) AS origem (chave, valor, descricao)
   ON destino.chave = origem.chave
WHEN NOT MATCHED THEN
    INSERT (chave, valor, descricao) VALUES (origem.chave, origem.valor, origem.descricao);
GO

/* ---------------------------------------------------------------------
   Política por tabela
   --------------------------------------------------------------------- */
IF OBJECT_ID('guarda.politica') IS NULL
CREATE TABLE guarda.politica (
    esquema       sysname NOT NULL,
    tabela        sysname NOT NULL,
    limite_delete int     NULL,
    limite_update int     NULL,
    ativo         bit     NOT NULL CONSTRAINT politica_ativo_padrao DEFAULT (1),
    observacao    nvarchar(400) NULL,
    CONSTRAINT politica_pk PRIMARY KEY (esquema, tabela)
);
GO

/* ---------------------------------------------------------------------
   Auditoria
   --------------------------------------------------------------------- */
IF OBJECT_ID('guarda.evento') IS NULL
BEGIN
    CREATE TABLE guarda.evento (
        id              bigint IDENTITY(1,1) PRIMARY KEY,
        ocorrido_em     datetime2(3)   NOT NULL CONSTRAINT evento_data_padrao DEFAULT SYSDATETIME(),
        resultado       varchar(10)    NOT NULL,
        comando         varchar(30)    NOT NULL,
        esquema         sysname        NULL,
        tabela          sysname        NULL,
        linhas          bigint         NULL,
        limite          int            NULL,
        justificativa   nvarchar(400)  NULL,
        ambiente        nvarchar(40)   NULL,
        usuario         nvarchar(200)  NULL,
        usuario_efetivo nvarchar(200)  NULL,
        aplicacao       nvarchar(200)  NULL,
        host_cliente    nvarchar(100)  NULL,
        sessao          int            NULL,
        comando_texto   nvarchar(max)  NULL,
        CONSTRAINT evento_resultado_ck
            CHECK (resultado IN ('permitido', 'liberado', 'bloqueado', 'configuracao'))
    );

    CREATE INDEX evento_ocorrido_em_ix ON guarda.evento (ocorrido_em DESC);
    CREATE INDEX evento_tabela_ix      ON guarda.evento (esquema, tabela, ocorrido_em DESC);
END
GO

/* ---------------------------------------------------------------------
   Leitura de configuração
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION guarda.txt_config (@chave varchar(60))
RETURNS nvarchar(200)
AS
BEGIN
    RETURN (SELECT valor FROM guarda.config WHERE chave = @chave);
END
GO

CREATE OR ALTER FUNCTION guarda.num_config (@chave varchar(60), @padrao int)
RETURNS int
AS
BEGIN
    RETURN COALESCE(TRY_CONVERT(int, (SELECT valor FROM guarda.config WHERE chave = @chave)),
                    @padrao);
END
GO

/* ---------------------------------------------------------------------
   Limite aplicável. NULL significa sem limite.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION guarda.limite (@esquema sysname, @tabela sysname, @comando varchar(10))
RETURNS int
AS
BEGIN
    DECLARE @ativo bit, @delete int, @update int;

    SELECT @ativo = ativo, @delete = limite_delete, @update = limite_update
      FROM guarda.politica
     WHERE esquema = @esquema AND tabela = @tabela;

    IF @ativo = 0 RETURN NULL;

    IF @comando = 'DELETE'
        RETURN COALESCE(@delete, guarda.num_config('limite_delete_padrao', 500));

    RETURN COALESCE(@update, guarda.num_config('limite_update_padrao', 500));
END
GO

/* ---------------------------------------------------------------------
   Válvula de escape

   SESSION_CONTEXT vale para a conexão inteira, não para a transação.
   Para a liberação não ficar valendo o resto do dia, ela expira em
   poucos segundos: você libera, roda o comando, e a janela fecha.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE guarda.liberar
    @motivo nvarchar(400)
AS
BEGIN
    SET NOCOUNT ON;

    IF guarda.txt_config('exigir_justificativa') = N'sim'
       AND (@motivo IS NULL OR LEN(LTRIM(RTRIM(@motivo))) < 15)
    BEGIN
        THROW 50010, 'GUARDA: informe um motivo com pelo menos 15 caracteres.', 1;
    END

    DECLARE @janela int = guarda.num_config('janela_liberacao_seg', 60);
    DECLARE @ate datetime2(3) = DATEADD(SECOND, @janela, SYSUTCDATETIME());

    EXEC sys.sp_set_session_context @key = N'guarda_liberado_ate', @value = @ate;
    EXEC sys.sp_set_session_context @key = N'guarda_motivo',       @value = @motivo;

    DECLARE @aviso nvarchar(300) = CONCAT(
        N'Liberado por ', @janela, N' segundos. Rode em transação explícita ',
        N'(BEGIN TRANSACTION) e confira o total antes do COMMIT.');
    PRINT @aviso;
END
GO

CREATE OR ALTER PROCEDURE guarda.bloquear
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_set_session_context @key = N'guarda_liberado_ate', @value = NULL;
    EXEC sys.sp_set_session_context @key = N'guarda_motivo',       @value = NULL;
END
GO

CREATE OR ALTER FUNCTION guarda.esta_liberado ()
RETURNS bit
AS
BEGIN
    DECLARE @ate datetime2(3) = TRY_CONVERT(datetime2(3), SESSION_CONTEXT(N'guarda_liberado_ate'));
    IF @ate IS NOT NULL AND @ate > SYSUTCDATETIME() RETURN 1;
    RETURN 0;
END
GO

CREATE OR ALTER FUNCTION guarda.motivo ()
RETURNS nvarchar(400)
AS
BEGIN
    RETURN CONVERT(nvarchar(400), SESSION_CONTEXT(N'guarda_motivo'));
END
GO

CREATE OR ALTER FUNCTION guarda.eh_admin ()
RETURNS bit
AS
BEGIN
    DECLARE @papel sysname = CONVERT(sysname, guarda.txt_config('papel_admin'));
    IF @papel IS NOT NULL AND IS_ROLEMEMBER(@papel) = 1 RETURN 1;
    RETURN 0;
END
GO

/* ---------------------------------------------------------------------
   Registro de auditoria

   Chamado depois do ROLLBACK dentro do trigger. Quando um trigger
   executa ROLLBACK TRANSACTION, o restante do corpo do trigger ainda
   roda, agora fora de transação, então este INSERT persiste mesmo no
   caso bloqueado. É o que permite saber quem tentou.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE guarda.registrar
    @resultado     varchar(10),
    @comando       varchar(30),
    @esquema       sysname       = NULL,
    @tabela        sysname       = NULL,
    @linhas        bigint        = NULL,
    @limite        int           = NULL,
    @comando_texto nvarchar(max) = NULL
WITH EXECUTE AS OWNER      -- para o usuário comum não precisar de INSERT em guarda.evento
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO guarda.evento (
        resultado, comando, esquema, tabela, linhas, limite, justificativa,
        ambiente, usuario, usuario_efetivo, aplicacao, host_cliente, sessao, comando_texto
    )
    VALUES (
        @resultado, @comando, @esquema, @tabela, @linhas, @limite, guarda.motivo(),
        guarda.txt_config('ambiente'),
        ORIGINAL_LOGIN(), USER_NAME(), APP_NAME(),
        CONVERT(nvarchar(100), CONNECTIONPROPERTY('client_net_address')),
        @@SPID, @comando_texto
    );
END
GO
