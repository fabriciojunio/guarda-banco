-- =====================================================================
-- Guarda: MySQL, remoção
--
-- Rode primeiro para ver o que vai sair:
--     CALL guarda.gerar_remocao('loja');
-- e execute a saída. Ou, direto:
--     mysql -N -B -e "CALL guarda.gerar_remocao('loja')" | mysql
-- =====================================================================

-- Lista tudo que o guard instalou, em todos os bancos
SELECT CONCAT('DROP TRIGGER IF EXISTS `', TRIGGER_SCHEMA, '`.`', TRIGGER_NAME, '`;') AS instrucao
  FROM information_schema.TRIGGERS
 WHERE LEFT(TRIGGER_NAME, 7) = 'guarda_'
 ORDER BY TRIGGER_SCHEMA, TRIGGER_NAME;

-- Depois de rodar a saída acima, confira que não sobrou nada:
SELECT COUNT(*) AS triggers_restantes
  FROM information_schema.TRIGGERS
 WHERE LEFT(TRIGGER_NAME, 7) = 'guarda_';

-- sql_safe_updates é proteção nativa do MySQL e não faz parte do guard.
-- Só desligue se for realmente a intenção:
-- SET PERSIST sql_safe_updates = OFF;

-- Preserva o histórico e derruba o resto. guarda.evento tem valor legal
-- quando registra exclusão de dado pessoal (LGPD art. 37).
-- CREATE TABLE IF NOT EXISTS guarda_evento_arquivo AS SELECT * FROM guarda.evento;
-- DROP DATABASE guarda;
