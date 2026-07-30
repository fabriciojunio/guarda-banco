-- Migração de exemplo, cheia de erros de propósito.
-- Serve para conferir que o guarda-lint está funcionando:
--
--   python guarda_lint.py exemplos/0042_limpeza_clientes.sql
--
-- Esperado: 5 erros e 4 avisos.

-- ok, filtro fechado e com data explícita
delete from cliente
 where ativo = false
   and ultimo_acesso < '2024-01-01';

-- erro: marcou até o fim da linha e o WHERE ficou fora da seleção
update cliente
   set email = null;

-- erro: comparação com NULL casa zero linhas em silêncio
delete from contato
 where email = null;

-- erro: AND tem precedência sobre OR, isso pega todo mundo com status aberto
delete from pedido
 where cliente_id = 42 and status = 'rascunho' or status = 'aberto';

-- erro: produto cartesiano, cada pedido recebe um valor arbitrário
update pedido
   set total = item.valor
  from item;

-- aviso: NOT IN devolve vazio se a subconsulta trouxer NULL
delete from cliente
 where id not in (select cliente_id from pedido);

-- aviso: sem ORDER BY, o lote apaga linhas imprevisíveis
delete from fila_email where enviado = true limit 1000;

-- aviso: TRUNCATE não deixa rastro por linha
truncate table staging_importacao;

-- silenciado com motivo, não deve aparecer no relatório
-- guarda-lint: ignorar delete-sem-where (tabela de staging recriada a cada carga, OS-4821)
delete from staging_temporario;
