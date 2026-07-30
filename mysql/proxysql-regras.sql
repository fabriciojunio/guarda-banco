-- =====================================================================
-- Guarda: regras de ProxySQL (opcional, só MySQL)
--
-- Serve para o que trigger não alcança no MySQL: TRUNCATE, DROP e
-- ALTER, que não têm trigger nenhum. Como o ProxySQL fica na frente do
-- servidor, vale para qualquer cliente sem instalar nada na máquina de
-- ninguém.
--
-- Cuidado: regra por expressão regular erra em dois sentidos. Deixa
-- passar variação que você não previu, e barra comando legítimo que casa
-- por acidente. Use como camada extra, nunca como camada única.
--
-- Aplique no admin do ProxySQL (porta 6032).
-- =====================================================================

-- DELETE sem WHERE
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9001, 1,
     '(?i)^\s*delete\s+(?:low_priority\s+|quick\s+|ignore\s+)*from\s+[`\w\.]+\s*;?\s*$',
     'GUARDA: DELETE sem WHERE bloqueado pelo proxy.',
     1, 'guarda: A1');

-- UPDATE sem WHERE
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9002, 1,
     '(?i)^\s*update\s+(?:low_priority\s+|ignore\s+)*[`\w\.]+\s+set\s+(?:(?!\bwhere\b).)*;?\s*$',
     'GUARDA: UPDATE sem WHERE bloqueado pelo proxy.',
     1, 'guarda: A2');

-- TRUNCATE
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9003, 1,
     '(?i)^\s*truncate\s+',
     'GUARDA: TRUNCATE bloqueado pelo proxy. Use DELETE em lotes.',
     1, 'guarda: A4');

-- DROP TABLE / DATABASE / SCHEMA
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9004, 1,
     '(?i)^\s*drop\s+(table|database|schema)\s+',
     'GUARDA: DROP bloqueado pelo proxy. Abra mudanca com o DBA.',
     1, 'guarda: B1 B2 B3');

-- ALTER TABLE ... DROP COLUMN
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9005, 1,
     '(?i)^\s*alter\s+table\s+[`\w\.]+\s+drop\s+(column\s+)?[`\w]+',
     'GUARDA: DROP COLUMN bloqueado pelo proxy.',
     1, 'guarda: B4');

-- Desligar trigger é tentativa de burlar o guard
INSERT INTO mysql_query_rules
    (rule_id, active, match_pattern, error_msg, apply, comment)
VALUES
    (9006, 1,
     '(?i)(drop\s+trigger|set\s+(session\s+)?foreign_key_checks\s*=\s*0)',
     'GUARDA: desativar protecao ou checagem de FK nao e permitido por aqui.',
     1, 'guarda: B8 C4');

LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;

-- Confira o que ficou ativo
SELECT rule_id, active, match_pattern, error_msg, comment
  FROM runtime_mysql_query_rules
 WHERE rule_id BETWEEN 9000 AND 9099
 ORDER BY rule_id;

-- Depois de uma semana, veja se alguma regra está barrando coisa
-- legítima. hits alto em regra de bloqueio quase sempre é falso positivo:
-- SELECT rule_id, hits FROM stats_mysql_query_rules WHERE rule_id BETWEEN 9000 AND 9099;
