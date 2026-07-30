-- =====================================================================
-- Guarda: MySQL, teste de aceitação
--
-- Rode em HOMOLOGAÇÃO, com as etapas 01 a 03 já aplicadas.
--
--   mysql -h host -u usuario -p < 90-teste-aceitacao.sql
--
-- Saída esperada: todas as linhas com OK e falhas = 0.
-- =====================================================================

DROP DATABASE IF EXISTS guarda_teste;
CREATE DATABASE guarda_teste;

CREATE TABLE guarda_teste.resultado (
    caso     VARCHAR(60)  NOT NULL,
    situacao VARCHAR(10)  NOT NULL,
    detalhe  VARCHAR(400) NULL
) ENGINE = InnoDB;

CREATE TABLE guarda_teste.pedido (
    id     INT NOT NULL PRIMARY KEY,
    status VARCHAR(20) NOT NULL DEFAULT 'aberto'
) ENGINE = InnoDB;

CREATE TABLE guarda_teste.item (
    id        INT NOT NULL PRIMARY KEY,
    pedido_id INT NOT NULL,
    valor     DECIMAL(10,2) NOT NULL DEFAULT 10,
    KEY item_pedido_ix (pedido_id),
    -- RESTRICT de propósito: com CASCADE o MySQL apagaria as filhas sem
    -- disparar trigger, e o guard não veria nada. Ver docs/limitacoes.md
    CONSTRAINT item_pedido_fk FOREIGN KEY (pedido_id)
        REFERENCES guarda_teste.pedido(id) ON DELETE RESTRICT
) ENGINE = InnoDB;

-- massa de teste
INSERT INTO guarda_teste.pedido (id)
SELECT n FROM (
    SELECT (a.i + b.i * 10 + c.i * 100 + d.i * 1000 + 1) AS n
      FROM (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
            UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
           (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
            UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
           (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
            UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
           (SELECT 0 i UNION SELECT 1) d
) g WHERE n <= 2000;

INSERT INTO guarda_teste.item (id, pedido_id)
SELECT id, id FROM guarda_teste.pedido;

-- triggers do guard (escritas na mão porque o MySQL não aceita
-- CREATE TRIGGER em SQL dinâmico)
CREATE TRIGGER guarda_teste.guarda_del_pedido BEFORE DELETE ON guarda_teste.pedido
FOR EACH ROW CALL guarda.checar('guarda_teste', 'pedido', 'DELETE');

CREATE TRIGGER guarda_teste.guarda_upd_pedido BEFORE UPDATE ON guarda_teste.pedido
FOR EACH ROW CALL guarda.checar('guarda_teste', 'pedido', 'UPDATE');

CREATE TRIGGER guarda_teste.guarda_del_item BEFORE DELETE ON guarda_teste.item
FOR EACH ROW CALL guarda.checar('guarda_teste', 'item', 'DELETE');

CREATE TRIGGER guarda_teste.guarda_upd_item BEFORE UPDATE ON guarda_teste.item
FOR EACH ROW CALL guarda.checar('guarda_teste', 'item', 'UPDATE');

DELETE FROM guarda.politica WHERE esquema = 'guarda_teste';
INSERT INTO guarda.politica (esquema, tabela, limite_delete, limite_update) VALUES
    ('guarda_teste', 'pedido', 100, 100),
    ('guarda_teste', 'item',   100, 100);

DELIMITER $$

-- Aceita bloqueio de qualquer camada, e diz qual pegou.
--
-- No MySQL existem duas defesas em série, e a de fora pega primeiro: o
-- sql_safe_updates recusa DELETE/UPDATE sem WHERE com chave antes de a
-- trigger ser chamada. Exigir a mensagem do guard nesses casos seria
-- reprovar o sistema por estar protegido demais.
CREATE PROCEDURE guarda_teste.espera_bloqueio(IN p_caso VARCHAR(60), IN p_sql TEXT)
BEGIN
    DECLARE v_erro TINYINT DEFAULT 0;
    DECLARE v_msg  TEXT DEFAULT '';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_erro = 1;
    END;

    SET @sql_do_teste = p_sql;
    PREPARE st FROM @sql_do_teste;
    EXECUTE st;
    DEALLOCATE PREPARE st;

    IF v_erro = 1 AND v_msg LIKE 'GUARDA:%' THEN
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'OK', CONCAT('guard: ', LEFT(v_msg, 180)));
    ELSEIF v_erro = 1 AND v_msg LIKE '%safe update%' THEN
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'OK', 'sql_safe_updates pegou antes da trigger');
    ELSEIF v_erro = 1 THEN
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'FALHOU', CONCAT('erro inesperado: ', LEFT(v_msg, 200)));
    ELSE
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'FALHOU', 'passou e deveria ter sido bloqueado');
    END IF;
END $$

-- Exige que o bloqueio tenha vindo do contador de linhas do guard, e não
-- do sql_safe_updates. Para isso o comando de teste precisa passar pela
-- defesa nativa, o que se consegue com LIMIT ou com WHERE em chave.
CREATE PROCEDURE guarda_teste.espera_bloqueio_guarda(IN p_caso VARCHAR(60), IN p_sql TEXT)
BEGIN
    DECLARE v_erro TINYINT DEFAULT 0;
    DECLARE v_msg  TEXT DEFAULT '';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_erro = 1;
    END;

    SET @sql_do_teste = p_sql;
    PREPARE st FROM @sql_do_teste;
    EXECUTE st;
    DEALLOCATE PREPARE st;

    IF v_erro = 1 AND v_msg LIKE 'GUARDA:%' THEN
        INSERT INTO guarda_teste.resultado VALUES (p_caso, 'OK', LEFT(v_msg, 200));
    ELSEIF v_erro = 1 THEN
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'FALHOU', CONCAT('quem bloqueou nao foi o guard: ', LEFT(v_msg, 170)));
    ELSE
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'FALHOU', 'passou e deveria ter sido bloqueado');
    END IF;
END $$

CREATE PROCEDURE guarda_teste.espera_sucesso(IN p_caso VARCHAR(60), IN p_sql TEXT)
BEGIN
    DECLARE v_erro TINYINT DEFAULT 0;
    DECLARE v_msg  TEXT DEFAULT '';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_erro = 1;
    END;

    SET @sql_do_teste = p_sql;
    PREPARE st FROM @sql_do_teste;
    EXECUTE st;
    DEALLOCATE PREPARE st;

    IF v_erro = 1 THEN
        INSERT INTO guarda_teste.resultado
            VALUES (p_caso, 'FALHOU', CONCAT('bloqueou sem precisar: ', LEFT(v_msg, 200)));
    ELSE
        INSERT INTO guarda_teste.resultado VALUES (p_caso, 'OK', 'executou');
    END IF;
END $$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Testes
-- ---------------------------------------------------------------------
CALL guarda.bloquear();

-- Estes dois são pegos pelo sql_safe_updates, que vem antes da trigger
CALL guarda_teste.espera_bloqueio('A1 DELETE sem WHERE',
    'DELETE FROM guarda_teste.item');

CALL guarda_teste.espera_bloqueio('A2 UPDATE sem WHERE',
    'UPDATE guarda_teste.item SET valor = 0');

-- Daqui para baixo, com LIMIT para passar pelo sql_safe_updates e chegar
-- na trigger, quem tem que bloquear é o contador de linhas do guard
CALL guarda_teste.espera_bloqueio_guarda('A3 WHERE amplo demais',
    'DELETE FROM guarda_teste.item WHERE valor > 0 LIMIT 2000');

CALL guarda_teste.espera_sucesso('A3b DELETE pequeno passa',
    'DELETE FROM guarda_teste.item WHERE id <= 50');

CALL guarda_teste.espera_bloqueio_guarda('A8 OR no lugar de AND',
    'UPDATE guarda_teste.pedido SET status = ''cancelado''
      WHERE id = 7 OR status = ''aberto'' LIMIT 2000');

CALL guarda_teste.espera_bloqueio('Justificativa curta recusada',
    'CALL guarda.liberar(''oi'')');

CALL guarda.liberar('teste de aceitacao do guarda, ticket interno');

CALL guarda_teste.espera_sucesso('Liberacao destrava DELETE grande',
    'DELETE FROM guarda_teste.item WHERE valor > 0 LIMIT 2000');

-- Pegadinha operacional que vale ter fixada em teste: a liberação vale
-- para o guard, não para o sql_safe_updates. Mesmo liberado, comando sem
-- WHERE com chave e sem LIMIT continua recusado pelo servidor.
CALL guarda.liberar('conferindo que liberar nao passa por cima do safe updates');
CALL guarda_teste.espera_bloqueio('Liberacao nao burla o sql_safe_updates',
    'DELETE FROM guarda_teste.item');

CALL guarda.bloquear();

-- sql_safe_updates: a defesa que sobra quando o performance_schema cai
INSERT INTO guarda_teste.resultado
SELECT 'sql_safe_updates ligado',
       IF(@@GLOBAL.sql_safe_updates = 1, 'OK', 'FALHOU'),
       'defesa nativa contra DELETE/UPDATE sem WHERE';

-- id_comando funcionando: sem isso o contador por comando não existe
INSERT INTO guarda_teste.resultado
SELECT 'performance_schema identifica comando',
       IF(guarda.id_comando() > 0, 'OK', 'FALHOU'),
       CONCAT('id_comando() = ', guarda.id_comando());

-- auditoria das liberações
INSERT INTO guarda_teste.resultado
SELECT 'Auditoria registrou liberacao',
       IF(COUNT(*) >= 1, 'OK', 'FALHOU'),
       CONCAT(COUNT(*), ' evento(s) liberado(s)')
  FROM guarda.evento
 WHERE esquema = 'guarda_teste' AND resultado = 'liberado';

-- TRUNCATE e DROP: aqui não existe trigger, a defesa é privilégio
INSERT INTO guarda_teste.resultado
SELECT 'A4/B1 TRUNCATE e DROP dependem de privilegio',
       'ATENCAO',
       CONCAT('MySQL nao tem trigger de DDL. Confira guarda.quem_pode_truncate: ',
              (SELECT COUNT(*) FROM guarda.quem_pode_truncate), ' concessao(oes) de DROP');

-- ---------------------------------------------------------------------
-- Relatório
-- ---------------------------------------------------------------------
SELECT caso, situacao, detalhe FROM guarda_teste.resultado ORDER BY caso;

SELECT SUM(situacao = 'OK')      AS ok,
       SUM(situacao = 'FALHOU')  AS falhas,
       SUM(situacao = 'ATENCAO') AS atencao
  FROM guarda_teste.resultado;

-- ---------------------------------------------------------------------
-- Limpeza
-- ---------------------------------------------------------------------
DELETE FROM guarda.politica WHERE esquema = 'guarda_teste';
DELETE FROM guarda.evento   WHERE esquema = 'guarda_teste';
DROP PROCEDURE IF EXISTS guarda_teste.espera_bloqueio;
DROP PROCEDURE IF EXISTS guarda_teste.espera_bloqueio_guarda;
DROP PROCEDURE IF EXISTS guarda_teste.espera_sucesso;
DROP DATABASE guarda_teste;
