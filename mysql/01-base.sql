-- =====================================================================
-- Guarda: trilhos de segurança contra DML destrutivo acidental
-- MySQL 8.0 / MariaDB 10.5+: etapa 1 de 4
--
-- Execute com um usuário que tenha SUPER (ou SYSTEM_VARIABLES_ADMIN),
-- CREATE ROUTINE, TRIGGER e SELECT em performance_schema.
--
-- Use o cliente mysql ou uma ferramenta que respeite DELIMITER.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS guarda
    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- ---------------------------------------------------------------------
-- Configuração global
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guarda.config (
    chave     VARCHAR(60)  NOT NULL PRIMARY KEY,
    valor     VARCHAR(200) NOT NULL,
    descricao VARCHAR(400) NOT NULL
) ENGINE = InnoDB;

INSERT INTO guarda.config (chave, valor, descricao) VALUES
    ('ambiente', 'producao',
     'producao | homologacao | desenvolvimento. Informativo, aparece na auditoria.'),
    ('limite_delete_padrao', '500',
     'Linhas que um DELETE pode remover sem liberação explícita.'),
    ('limite_update_padrao', '500',
     'Linhas que um UPDATE pode alterar sem liberação explícita.'),
    ('registrar_acima_de', '100',
     'Operações permitidas acima deste número de linhas vão para guarda.evento.'),
    ('exigir_justificativa', 'sim',
     'Se sim, guarda.liberar exige motivo com no mínimo 15 caracteres.'),
    ('janela_liberacao_seg', '60',
     'Segundos de validade da liberação. Curta de propósito.'),
    ('exigir_performance_schema', 'nao',
     'sim = bloqueia DML se não conseguir identificar o comando. Leia docs/limitacoes.md antes de ligar.')
ON DUPLICATE KEY UPDATE chave = chave;

-- ---------------------------------------------------------------------
-- Política por tabela
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guarda.politica (
    esquema       VARCHAR(64) NOT NULL,
    tabela        VARCHAR(64) NOT NULL,
    limite_delete INT NULL,
    limite_update INT NULL,
    ativo         TINYINT(1) NOT NULL DEFAULT 1,
    observacao    VARCHAR(400) NULL,
    PRIMARY KEY (esquema, tabela)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Auditoria
--
-- Atenção: quando o guard bloqueia, ele usa SIGNAL, e o SIGNAL desfaz o
-- statement, inclusive o INSERT nesta tabela. Então aqui ficam as
-- operações que PASSARAM. Para ter o rastro das tentativas bloqueadas,
-- é preciso plugin de auditoria (ver docs/limitacoes.md), porque o MySQL
-- não tem transação autônoma nem log de aplicação para rotina.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guarda.evento (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    ocorrido_em     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    resultado       ENUM('permitido', 'liberado', 'configuracao') NOT NULL,
    comando         VARCHAR(30) NOT NULL,
    esquema         VARCHAR(64) NULL,
    tabela          VARCHAR(64) NULL,
    linhas_ao_menos BIGINT NULL,
    limite          INT NULL,
    justificativa   VARCHAR(400) NULL,
    ambiente        VARCHAR(40) NULL,
    usuario         VARCHAR(200) NULL,
    aplicacao       VARCHAR(200) NULL,
    host_cliente    VARCHAR(255) NULL,
    conexao         BIGINT UNSIGNED NULL,
    KEY evento_ocorrido_em_ix (ocorrido_em),
    KEY evento_tabela_ix (esquema, tabela, ocorrido_em)
) ENGINE = InnoDB;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Leitura de configuração
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS guarda.txt_config $$
CREATE FUNCTION guarda.txt_config(p_chave VARCHAR(60))
RETURNS VARCHAR(200)
READS SQL DATA
SQL SECURITY INVOKER
BEGIN
    DECLARE v VARCHAR(200);
    SELECT valor INTO v FROM guarda.config WHERE chave = p_chave;
    RETURN v;
END $$

DROP FUNCTION IF EXISTS guarda.num_config $$
CREATE FUNCTION guarda.num_config(p_chave VARCHAR(60), p_padrao INT)
RETURNS INT
READS SQL DATA
SQL SECURITY INVOKER
BEGIN
    DECLARE v INT;
    SELECT CAST(valor AS SIGNED) INTO v FROM guarda.config WHERE chave = p_chave;
    RETURN IFNULL(v, p_padrao);
END $$

-- ---------------------------------------------------------------------
-- Limite aplicável. NULL = sem limite.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS guarda.limite $$
CREATE FUNCTION guarda.limite(p_esquema VARCHAR(64), p_tabela VARCHAR(64), p_comando VARCHAR(10))
RETURNS INT
READS SQL DATA
SQL SECURITY INVOKER
BEGIN
    DECLARE v_ativo TINYINT(1) DEFAULT 1;
    DECLARE v_del INT DEFAULT NULL;
    DECLARE v_upd INT DEFAULT NULL;

    SELECT ativo, limite_delete, limite_update
      INTO v_ativo, v_del, v_upd
      FROM guarda.politica
     WHERE esquema = p_esquema AND tabela = p_tabela;

    IF v_ativo = 0 THEN
        RETURN NULL;
    END IF;

    IF p_comando = 'DELETE' THEN
        RETURN IFNULL(v_del, guarda.num_config('limite_delete_padrao', 500));
    END IF;

    RETURN IFNULL(v_upd, guarda.num_config('limite_update_padrao', 500));
END $$

-- ---------------------------------------------------------------------
-- Identificação do comando em execução
--
-- O MySQL não tem trigger de statement, só de linha. Para saber quando
-- um comando termina e outro começa, usamos o EVENT_ID do statement de
-- primeiro nível no performance_schema. Sem ele, não há como distinguir
-- "500 linhas em um DELETE" de "500 DELETEs de uma linha".
--
-- Retorna 0 quando a instrumentação está desligada.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS guarda.id_comando $$
CREATE FUNCTION guarda.id_comando()
RETURNS BIGINT UNSIGNED
READS SQL DATA
SQL SECURITY DEFINER   -- para o usuário comum não precisar de SELECT em performance_schema
BEGIN
    DECLARE v BIGINT UNSIGNED DEFAULT 0;

    SELECT IFNULL(MIN(EVENT_ID), 0) INTO v
      FROM performance_schema.events_statements_current
     WHERE THREAD_ID = (SELECT THREAD_ID
                          FROM performance_schema.threads
                         WHERE PROCESSLIST_ID = CONNECTION_ID())
       AND NESTING_EVENT_ID IS NULL;

    RETURN v;
END $$

-- ---------------------------------------------------------------------
-- Válvula de escape
--
-- Variável de sessão vale para a conexão inteira, então a liberação
-- expira em poucos segundos: você libera, roda o comando, e a janela
-- fecha sozinha.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS guarda.liberar $$
CREATE PROCEDURE guarda.liberar(IN p_motivo VARCHAR(400))
SQL SECURITY INVOKER
BEGIN
    DECLARE v_janela INT;

    IF guarda.txt_config('exigir_justificativa') = 'sim'
       AND (p_motivo IS NULL OR CHAR_LENGTH(TRIM(p_motivo)) < 15) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'GUARDA: informe um motivo com pelo menos 15 caracteres.';
    END IF;

    SET v_janela = guarda.num_config('janela_liberacao_seg', 60);
    SET @guarda_liberado_ate = NOW(6) + INTERVAL v_janela SECOND;
    SET @guarda_motivo = TRIM(p_motivo);

    SELECT CONCAT('Liberado por ', v_janela, ' segundos. Rode dentro de START TRANSACTION ',
                  'e confira o total antes do COMMIT.') AS aviso;
END $$

DROP PROCEDURE IF EXISTS guarda.bloquear $$
CREATE PROCEDURE guarda.bloquear()
SQL SECURITY INVOKER
BEGIN
    SET @guarda_liberado_ate = NULL;
    SET @guarda_motivo = NULL;
END $$

DROP FUNCTION IF EXISTS guarda.esta_liberado $$
CREATE FUNCTION guarda.esta_liberado()
RETURNS TINYINT(1)
NO SQL
SQL SECURITY INVOKER
BEGIN
    IF @guarda_liberado_ate IS NOT NULL AND @guarda_liberado_ate > NOW(6) THEN
        RETURN 1;
    END IF;
    RETURN 0;
END $$

DELIMITER ;
