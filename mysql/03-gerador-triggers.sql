-- =====================================================================
-- Guarda: MySQL, etapa 3 de 4: verificação e geração das triggers
--
-- O MySQL não aceita CREATE TRIGGER em SQL dinâmico, então não existe
-- procedure "instalar" como no PostgreSQL e no SQL Server. Em vez disso,
-- guarda.gerar() devolve as instruções prontas para você conferir e
-- executar.
--
-- O corpo de cada trigger é um CALL único, sem BEGIN/END. Isso é de
-- propósito: sem ponto e vírgula interno, a saída pode ser canalizada
-- direto para o cliente mysql sem mexer em DELIMITER.
--
--   mysql -N -B -e "CALL guarda.gerar('loja')" | mysql
-- =====================================================================

DELIMITER $$

-- ---------------------------------------------------------------------
-- Coração do sistema: chamado uma vez por linha afetada
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS guarda.checar $$
CREATE PROCEDURE guarda.checar(
    IN p_esquema VARCHAR(64),
    IN p_tabela  VARCHAR(64),
    IN p_comando VARCHAR(10)
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_stmt     BIGINT UNSIGNED;
    DECLARE v_limite   INT;
    DECLARE v_registra INT;
    DECLARE v_liberado TINYINT(1);
    -- MESSAGE_TEXT do SIGNAL é truncado em 128 caracteres pelo MySQL,
    -- então a mensagem é curta e as instruções ficam em guarda.como_liberar
    DECLARE v_msg      VARCHAR(128);

    SET v_stmt = guarda.id_comando();

    IF v_stmt = 0 THEN
        -- Sem performance_schema não há como saber onde termina um comando
        -- e começa o próximo, ou seja, não há como contar linhas por
        -- comando. Por padrão o guard sai de cena e deixa a defesa com
        -- sql_safe_updates. Para falhar fechado em vez de aberto,
        -- ponha exigir_performance_schema = sim.
        IF guarda.txt_config('exigir_performance_schema') = 'sim' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'GUARDA: performance_schema desligado. Rode CALL guarda.diagnostico().';
        END IF;
    ELSE
        IF @guarda_stmt IS NULL OR @guarda_stmt <> v_stmt THEN
            SET @guarda_stmt = v_stmt;
            SET @guarda_linhas = 0;
        END IF;

        SET @guarda_linhas = @guarda_linhas + 1;

        SET v_liberado = guarda.esta_liberado();
        SET v_limite   = guarda.limite(p_esquema, p_tabela, p_comando);

        IF v_liberado = 0 AND v_limite IS NOT NULL AND @guarda_linhas > v_limite THEN
            SET v_msg = CONCAT('GUARDA: ', p_comando, ' em ', p_tabela, ' passou de ',
                               v_limite, ' linhas. Bloqueado. Veja guarda.como_liberar');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        SET v_registra = guarda.num_config('registrar_acima_de', 100);

        -- Uma linha de auditoria por comando. Sem trigger de statement não
        -- se sabe o total final, então grava no cruzamento do limiar e o
        -- campo se chama linhas_ao_menos.
        IF (v_liberado = 1 AND @guarda_linhas = 1)
           OR (v_liberado = 0 AND @guarda_linhas = v_registra) THEN
            INSERT INTO guarda.evento (
                resultado, comando, esquema, tabela, linhas_ao_menos, limite,
                justificativa, ambiente, usuario, aplicacao, host_cliente, conexao
            ) VALUES (
                IF(v_liberado = 1, 'liberado', 'permitido'),
                p_comando, p_esquema, p_tabela, @guarda_linhas, v_limite,
                @guarda_motivo, guarda.txt_config('ambiente'),
                -- SESSION_USER() e não CURRENT_USER(): dentro de trigger o
                -- CURRENT_USER() devolve o DEFINER da trigger, e a auditoria
                -- registraria sempre o root em vez de quem rodou o comando
                SESSION_USER(),
                (SELECT ATTR_VALUE FROM performance_schema.session_connect_attrs
                  WHERE PROCESSLIST_ID = CONNECTION_ID() AND ATTR_NAME = 'program_name'
                  LIMIT 1),
                SUBSTRING_INDEX(USER(), '@', -1),
                CONNECTION_ID()
            );
        END IF;
    END IF;
END $$

-- ---------------------------------------------------------------------
-- Geração das instruções
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS guarda.gerar $$
CREATE PROCEDURE guarda.gerar(IN p_esquema VARCHAR(64))
BEGIN
    SELECT CONCAT(
               'DROP TRIGGER IF EXISTS `', t.TABLE_SCHEMA, '`.`guarda_del_', t.TABLE_NAME, '`;'
           ) AS instrucao, 1 AS ordem, t.TABLE_NAME AS tabela
      FROM information_schema.TABLES t
     WHERE t.TABLE_TYPE = 'BASE TABLE'
       AND t.TABLE_SCHEMA = p_esquema

    UNION ALL
    SELECT CONCAT(
               'DROP TRIGGER IF EXISTS `', t.TABLE_SCHEMA, '`.`guarda_upd_', t.TABLE_NAME, '`;'
           ), 2, t.TABLE_NAME
      FROM information_schema.TABLES t
     WHERE t.TABLE_TYPE = 'BASE TABLE'
       AND t.TABLE_SCHEMA = p_esquema

    UNION ALL
    SELECT CONCAT(
               'CREATE TRIGGER `', t.TABLE_SCHEMA, '`.`guarda_del_', t.TABLE_NAME,
               '` BEFORE DELETE ON `', t.TABLE_SCHEMA, '`.`', t.TABLE_NAME,
               '` FOR EACH ROW CALL guarda.checar(''', t.TABLE_SCHEMA, ''', ''',
               t.TABLE_NAME, ''', ''DELETE'');'
           ), 3, t.TABLE_NAME
      FROM information_schema.TABLES t
     WHERE t.TABLE_TYPE = 'BASE TABLE'
       AND t.TABLE_SCHEMA = p_esquema

    UNION ALL
    SELECT CONCAT(
               'CREATE TRIGGER `', t.TABLE_SCHEMA, '`.`guarda_upd_', t.TABLE_NAME,
               '` BEFORE UPDATE ON `', t.TABLE_SCHEMA, '`.`', t.TABLE_NAME,
               '` FOR EACH ROW CALL guarda.checar(''', t.TABLE_SCHEMA, ''', ''',
               t.TABLE_NAME, ''', ''UPDATE'');'
           ), 4, t.TABLE_NAME
      FROM information_schema.TABLES t
     WHERE t.TABLE_TYPE = 'BASE TABLE'
       AND t.TABLE_SCHEMA = p_esquema

     ORDER BY tabela, ordem;
END $$

DROP PROCEDURE IF EXISTS guarda.gerar_remocao $$
CREATE PROCEDURE guarda.gerar_remocao(IN p_esquema VARCHAR(64))
BEGIN
    SELECT CONCAT('DROP TRIGGER IF EXISTS `', tr.TRIGGER_SCHEMA, '`.`',
                  tr.TRIGGER_NAME, '`;') AS instrucao
      FROM information_schema.TRIGGERS tr
     WHERE tr.TRIGGER_SCHEMA = p_esquema
       AND LEFT(tr.TRIGGER_NAME, 7) = 'guarda_'
     ORDER BY tr.TRIGGER_NAME;
END $$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Nomes de tabela longos: o nome da trigger fica com 11 caracteres a
-- mais que o da tabela, e o limite do MySQL é 64. Confira antes:
-- ---------------------------------------------------------------------
SELECT TABLE_SCHEMA, TABLE_NAME, CHAR_LENGTH(TABLE_NAME) + 11 AS tamanho_do_nome_da_trigger
  FROM information_schema.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE'
   AND CHAR_LENGTH(TABLE_NAME) + 11 > 64
   AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');
