-- =====================================================================
-- Guarda: teste de aceitação
--
-- Rode em HOMOLOGAÇÃO, com as etapas 01 a 04 já aplicadas.
-- Cria o esquema guarda_teste, exercita as proteções e derruba no fim.
--
--   psql -h host -U usuario -d banco -f 90-teste-aceitacao.sql
--
-- Saída esperada: todas as linhas com "OK" e "falhas: 0" no fim.
-- =====================================================================

\set ON_ERROR_STOP off
\timing off

begin;
select guarda.manutencao();
drop schema if exists guarda_teste cascade;
create schema guarda_teste;
commit;

create table guarda_teste.resultado (
    caso     text,
    situacao text,
    detalhe  text
);

-- ---------------------------------------------------------------------
-- Ferramentas do teste
-- ---------------------------------------------------------------------
create or replace function guarda_teste.espera_bloqueio(p_caso text, p_sql text)
returns void
language plpgsql
as $$
begin
    begin
        execute p_sql;
        insert into guarda_teste.resultado
            values (p_caso, 'FALHOU', 'passou e deveria ter sido bloqueado');
    exception when others then
        if sqlerrm like 'GUARDA:%' then
            insert into guarda_teste.resultado
                values (p_caso, 'OK', left(sqlerrm, 90));
        else
            insert into guarda_teste.resultado
                values (p_caso, 'FALHOU', 'erro inesperado: ' || left(sqlerrm, 90));
        end if;
    end;
end;
$$;

create or replace function guarda_teste.espera_sucesso(p_caso text, p_sql text)
returns void
language plpgsql
as $$
begin
    begin
        execute p_sql;
        insert into guarda_teste.resultado values (p_caso, 'OK', 'executou');
    exception when others then
        insert into guarda_teste.resultado
            values (p_caso, 'FALHOU', 'bloqueou sem precisar: ' || left(sqlerrm, 90));
    end;
end;
$$;

create or replace function guarda_teste.rearmar()
returns void
language plpgsql
as $$
begin
    perform set_config('guarda.liberado', 'nao', true);
    perform set_config('guarda.motivo', '', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Cenário: pedido tem itens com ON DELETE CASCADE
-- ---------------------------------------------------------------------
create table guarda_teste.pedido (
    id     integer primary key,
    status text not null default 'aberto'
);

create table guarda_teste.item (
    id        integer primary key,
    pedido_id integer not null references guarda_teste.pedido(id) on delete cascade,
    valor     numeric(10,2) not null default 10
);

insert into guarda_teste.pedido (id)
    select g from generate_series(1, 2000) g;

insert into guarda_teste.item (id, pedido_id)
    select g, ((g - 1) % 2000) + 1 from generate_series(1, 6000) g;

select guarda.instalar('guarda_teste', 'pedido');
select guarda.instalar('guarda_teste', 'item');

insert into guarda.politica (esquema, tabela, limite_delete, limite_update)
values ('guarda_teste', 'pedido', 100, 100),
       ('guarda_teste', 'item',   100, 100)
on conflict (esquema, tabela) do update
   set limite_delete = excluded.limite_delete,
       limite_update = excluded.limite_update;

-- ---------------------------------------------------------------------
-- Testes
-- ---------------------------------------------------------------------
begin;

select guarda_teste.rearmar();

-- A1: DELETE sem WHERE
select guarda_teste.espera_bloqueio(
    'A1 DELETE sem WHERE',
    'delete from guarda_teste.item');

-- A2: UPDATE sem WHERE
select guarda_teste.espera_bloqueio(
    'A2 UPDATE sem WHERE',
    'update guarda_teste.item set valor = 0');

-- A3: WHERE amplo demais
select guarda_teste.espera_bloqueio(
    'A3 WHERE amplo demais',
    'delete from guarda_teste.item where valor > 0');

-- A3b: dentro do limite continua funcionando
select guarda_teste.espera_sucesso(
    'A3b DELETE pequeno passa',
    'delete from guarda_teste.item where id <= 50');

-- A5: CASCADE. Apagar 500 pedidos remove ~1500 itens; o contador é do
-- comando inteiro, então o raio total é que conta.
select guarda_teste.espera_bloqueio(
    'A5 CASCADE além do limite',
    'delete from guarda_teste.pedido where id <= 500');

-- A8: OR onde se queria AND
select guarda_teste.espera_bloqueio(
    'A8 OR no lugar de AND',
    'update guarda_teste.pedido set status = ''cancelado'' '
    || 'where id = 7 or status = ''aberto''');

-- A4: TRUNCATE
select guarda_teste.espera_bloqueio(
    'A4 TRUNCATE',
    'truncate table guarda_teste.item');

-- Liberação explícita destrava
select guarda.liberar('teste de aceitacao do guarda, ticket interno');
select guarda_teste.espera_sucesso(
    'Liberação destrava DELETE grande',
    'delete from guarda_teste.item where valor > 0');

select guarda_teste.espera_sucesso(
    'Liberação destrava TRUNCATE',
    'truncate table guarda_teste.item');

-- Justificativa curta é recusada
select guarda_teste.rearmar();
select guarda_teste.espera_bloqueio(
    'Justificativa curta recusada',
    'select guarda.liberar(''oi'')');

-- B4: ALTER TABLE DROP COLUMN
select guarda_teste.rearmar();
select guarda_teste.espera_bloqueio(
    'B4 DROP COLUMN',
    'alter table guarda_teste.pedido drop column status');

-- B1: DROP TABLE
select guarda_teste.espera_bloqueio(
    'B1 DROP TABLE',
    'drop table guarda_teste.item');

-- B8: remover a própria proteção
select guarda_teste.espera_bloqueio(
    'B8 DROP TRIGGER do guard',
    'drop trigger guarda_conta_delete on guarda_teste.pedido');

select guarda_teste.espera_bloqueio(
    'B8 DISABLE TRIGGER do guard',
    'alter table guarda_teste.pedido disable trigger guarda_conta_delete');

-- Auditoria registrou as liberações
insert into guarda_teste.resultado
select 'Auditoria registrou liberação',
       case when count(*) >= 2 then 'OK' else 'FALHOU' end,
       count(*) || ' evento(s) liberado(s)'
  from guarda.evento
 where esquema = 'guarda_teste' and resultado = 'liberado';

-- Nenhuma tabela do teste ficou sem proteção
insert into guarda_teste.resultado
select 'Cobertura do instalador',
       case when count(*) = 0 then 'OK' else 'FALHOU' end,
       coalesce(string_agg(tabela, ', '), 'nenhuma tabela descoberta')
  from guarda.sem_protecao
 where esquema = 'guarda_teste';

-- Adoção automática de tabela nova
create table guarda_teste.nova (id integer primary key);
insert into guarda_teste.resultado
select 'Tabela nova adotada automaticamente',
       case when count(*) = 0 then 'OK' else 'FALHOU' end,
       'sem_protecao = ' || count(*)
  from guarda.sem_protecao
 where esquema = 'guarda_teste' and tabela = 'nova';

-- COMMIT e não ROLLBACK: a tabela de resultado precisa sobreviver.
-- Os dados alterados não importam, o esquema inteiro cai na limpeza.
commit;

-- ---------------------------------------------------------------------
-- Relatório
-- ---------------------------------------------------------------------
\echo ''
\echo '================ resultado do teste de aceitacao ================'
select caso, situacao, detalhe from guarda_teste.resultado order by caso;

select count(*) filter (where situacao = 'OK')     as ok,
       count(*) filter (where situacao = 'FALHOU') as falhas
  from guarda_teste.resultado;

-- ---------------------------------------------------------------------
-- Limpeza
-- ---------------------------------------------------------------------
begin;
select guarda.manutencao();
delete from guarda.politica where esquema = 'guarda_teste';
delete from guarda.evento   where esquema = 'guarda_teste';
drop schema guarda_teste cascade;
commit;
