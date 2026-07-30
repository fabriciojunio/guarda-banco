/* =====================================================================
   Guarda: SQL Server, teste de aceitação

   Rode em HOMOLOGAÇÃO, com as etapas 01 a 03 já aplicadas.
   Cria o esquema guarda_teste, exercita as proteções e derruba no fim.

     sqlcmd -S servidor -d banco -i 90-teste-aceitacao.sql

   Saída esperada: todas as linhas com OK e falhas = 0.
   ===================================================================== */

SET NOCOUNT ON;
GO

EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = 1;
GO

IF OBJECT_ID('guarda_teste.item')      IS NOT NULL DROP TABLE guarda_teste.item;
IF OBJECT_ID('guarda_teste.pedido')    IS NOT NULL DROP TABLE guarda_teste.pedido;
IF OBJECT_ID('guarda_teste.nova')      IS NOT NULL DROP TABLE guarda_teste.nova;
IF OBJECT_ID('guarda_teste.resultado') IS NOT NULL DROP TABLE guarda_teste.resultado;
IF SCHEMA_ID('guarda_teste') IS NULL EXEC('CREATE SCHEMA guarda_teste');
GO

EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = NULL;
GO

CREATE TABLE guarda_teste.resultado (
    caso     varchar(60)   NOT NULL,
    situacao varchar(10)   NOT NULL,
    detalhe  nvarchar(400) NULL
);
GO

/* ---------------------------------------------------------------------
   Ferramentas do teste
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE guarda_teste.espera_bloqueio
    @caso varchar(60),
    @sql  nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
        INSERT INTO guarda_teste.resultado
            VALUES (@caso, 'FALHOU', N'passou e deveria ter sido bloqueado');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_MESSAGE() LIKE 'GUARDA:%'
            INSERT INTO guarda_teste.resultado
                VALUES (@caso, 'OK', LEFT(ERROR_MESSAGE(), 120));
        ELSE
            INSERT INTO guarda_teste.resultado
                VALUES (@caso, 'FALHOU', N'erro inesperado: ' + LEFT(ERROR_MESSAGE(), 120));
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE guarda_teste.espera_sucesso
    @caso varchar(60),
    @sql  nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
        INSERT INTO guarda_teste.resultado VALUES (@caso, 'OK', N'executou');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT INTO guarda_teste.resultado
            VALUES (@caso, 'FALHOU', N'bloqueou sem precisar: ' + LEFT(ERROR_MESSAGE(), 120));
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   Cenário: pedido tem itens com ON DELETE CASCADE

   Limite alto no pedido e baixo no item de propósito: assim o teste
   prova que a cascata é vista pela proteção da tabela filha.
   --------------------------------------------------------------------- */
CREATE TABLE guarda_teste.pedido (
    id     int NOT NULL PRIMARY KEY,
    status varchar(20) NOT NULL CONSTRAINT pedido_status_padrao DEFAULT ('aberto')
);

CREATE TABLE guarda_teste.item (
    id        int NOT NULL PRIMARY KEY,
    pedido_id int NOT NULL
        CONSTRAINT item_pedido_fk REFERENCES guarda_teste.pedido(id) ON DELETE CASCADE,
    valor     decimal(10,2) NOT NULL CONSTRAINT item_valor_padrao DEFAULT (10)
);
GO

WITH numeros AS (
    SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
      FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO guarda_teste.pedido (id) SELECT n FROM numeros WHERE n <= 2000;
GO

WITH numeros AS (
    SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
      FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO guarda_teste.item (id, pedido_id) SELECT n, ((n - 1) % 2000) + 1 FROM numeros;
GO

EXEC guarda.instalar 'guarda_teste', 'pedido';
EXEC guarda.instalar 'guarda_teste', 'item';
GO

DELETE FROM guarda.politica WHERE esquema = 'guarda_teste';
INSERT INTO guarda.politica (esquema, tabela, limite_delete, limite_update)
VALUES ('guarda_teste', 'pedido', 1000, 1000),
       ('guarda_teste', 'item',    100,  100);
GO

/* ---------------------------------------------------------------------
   Testes
   --------------------------------------------------------------------- */
EXEC guarda.bloquear;
GO

EXEC guarda_teste.espera_bloqueio 'A1 DELETE sem WHERE',
     N'DELETE FROM guarda_teste.item';

EXEC guarda_teste.espera_bloqueio 'A2 UPDATE sem WHERE',
     N'UPDATE guarda_teste.item SET valor = 0';

EXEC guarda_teste.espera_bloqueio 'A3 WHERE amplo demais',
     N'DELETE FROM guarda_teste.item WHERE valor > 0';

EXEC guarda_teste.espera_sucesso  'A3b DELETE pequeno passa',
     N'DELETE FROM guarda_teste.item WHERE id <= 50';

EXEC guarda_teste.espera_bloqueio 'A5 CASCADE alem do limite',
     N'DELETE FROM guarda_teste.pedido WHERE id <= 500';

EXEC guarda_teste.espera_bloqueio 'A8 OR no lugar de AND',
     N'UPDATE guarda_teste.pedido SET status = ''cancelado''
        WHERE id = 7 OR status = ''aberto''';

EXEC guarda_teste.espera_bloqueio 'B4 DROP COLUMN',
     N'ALTER TABLE guarda_teste.pedido DROP COLUMN status';

EXEC guarda_teste.espera_bloqueio 'B1 DROP TABLE',
     N'DROP TABLE guarda_teste.item';

EXEC guarda_teste.espera_bloqueio 'B8 DROP TRIGGER do guarda',
     N'DROP TRIGGER guarda_teste.guarda_dml_pedido';

EXEC guarda_teste.espera_bloqueio 'B8 DISABLE TRIGGER do guarda',
     N'ALTER TABLE guarda_teste.pedido DISABLE TRIGGER guarda_dml_pedido';

EXEC guarda_teste.espera_bloqueio 'Justificativa curta recusada',
     N'EXEC guarda.liberar N''oi''';
GO

/* liberação destrava, e só pela janela combinada */
EXEC guarda.liberar N'teste de aceitacao do guarda, ticket interno';
GO

EXEC guarda_teste.espera_sucesso 'Liberacao destrava DELETE grande',
     N'DELETE FROM guarda_teste.item WHERE valor > 0';

EXEC guarda_teste.espera_sucesso 'Liberacao destrava DROP COLUMN',
     N'ALTER TABLE guarda_teste.pedido DROP COLUMN status';
GO

EXEC guarda.bloquear;
GO

/* TRUNCATE: aqui a defesa é permissão, não trigger. O teste confere
   que o script de permissões negou ALTER, que é o que TRUNCATE exige. */
INSERT INTO guarda_teste.resultado
SELECT 'A4 TRUNCATE depende de permissao',
       CASE WHEN EXISTS (
            SELECT 1 FROM sys.database_permissions
             WHERE permission_name = 'ALTER' AND state_desc = 'DENY'
       ) THEN 'OK' ELSE 'FALHOU' END,
       N'TRUNCATE nao dispara trigger no SQL Server. Precisa de DENY ALTER, ver 04-permissoes.sql';
GO

/* adoção automática de tabela nova */
CREATE TABLE guarda_teste.nova (id int NOT NULL PRIMARY KEY);
GO

INSERT INTO guarda_teste.resultado
SELECT 'Tabela nova adotada automaticamente',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FALHOU' END,
       CONCAT('sem_protecao = ', COUNT(*))
  FROM guarda.sem_protecao
 WHERE esquema = 'guarda_teste' AND tabela = 'nova';
GO

/* auditoria gravou o bloqueio, mesmo com o ROLLBACK */
INSERT INTO guarda_teste.resultado
SELECT 'Auditoria registrou bloqueio',
       CASE WHEN COUNT(*) >= 3 THEN 'OK' ELSE 'FALHOU' END,
       CONCAT(COUNT(*), ' evento(s) bloqueado(s)')
  FROM guarda.evento
 WHERE esquema = 'guarda_teste' AND resultado = 'bloqueado';
GO

/* ---------------------------------------------------------------------
   Relatório
   --------------------------------------------------------------------- */
SELECT caso, situacao, detalhe FROM guarda_teste.resultado ORDER BY caso;

SELECT SUM(CASE WHEN situacao = 'OK'     THEN 1 ELSE 0 END) AS ok,
       SUM(CASE WHEN situacao = 'FALHOU' THEN 1 ELSE 0 END) AS falhas
  FROM guarda_teste.resultado;
GO

/* ---------------------------------------------------------------------
   Limpeza
   --------------------------------------------------------------------- */
EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = 1;
GO
DELETE FROM guarda.politica WHERE esquema = 'guarda_teste';
DELETE FROM guarda.evento   WHERE esquema = 'guarda_teste';
DROP TABLE guarda_teste.item;
DROP TABLE guarda_teste.pedido;
DROP TABLE guarda_teste.nova;
DROP TABLE guarda_teste.resultado;
DROP PROCEDURE guarda_teste.espera_bloqueio;
DROP PROCEDURE guarda_teste.espera_sucesso;
DROP SCHEMA guarda_teste;
GO
EXEC sys.sp_set_session_context @key = N'guarda_manutencao', @value = NULL;
GO
