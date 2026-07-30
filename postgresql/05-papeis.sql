-- =====================================================================
-- Guarda: etapa 5 de 5: papéis e privilégios
--
-- Trigger nenhuma segura o que privilégio deveria ter barrado antes.
-- Este arquivo é receita: ajuste os nomes e rode o que fizer sentido
-- no seu ambiente. Leia antes de executar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Papéis de grupo
-- ---------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'guarda_admin') then
        create role guarda_admin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'app_leitura') then
        create role app_leitura;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'app_escrita') then
        create role app_escrita;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'dono_dados') then
        create role dono_dados;
    end if;
end;
$$;

comment on role guarda_admin is 'DBA. Faz DDL destrutivo sem passar por guarda.liberar().';
comment on role app_leitura is 'Somente SELECT. É este o papel do dia a dia.';
comment on role app_escrita is 'SELECT, INSERT, UPDATE, DELETE. Sem TRUNCATE, sem DDL.';
comment on role dono_dados is 'Dono das tabelas. Ninguém faz login com ele.';

-- ---------------------------------------------------------------------
-- Ponto mais importante deste arquivo
--
-- Quem é dono da tabela pode remover trigger dela, inclusive as do
-- guard. Se o desenvolvedor é dono, o guard é decorativo. Passe as
-- tabelas para um papel que não faz login.
-- ---------------------------------------------------------------------
-- Descomente depois de conferir a lista:
--
-- do $$
-- declare r record;
-- begin
--     for r in select schemaname, tablename from pg_tables
--               where schemaname not in ('pg_catalog','information_schema','guarda')
--     loop
--         execute format('alter table %I.%I owner to dono_dados', r.schemaname, r.tablename);
--     end loop;
-- end;
-- $$;

-- ---------------------------------------------------------------------
-- Privilégios por papel (troque 'public' pelo seu esquema)
-- ---------------------------------------------------------------------
\set esquema public

grant usage on schema :"esquema" to app_leitura, app_escrita;

grant select on all tables in schema :"esquema" to app_leitura;
alter default privileges in schema :"esquema"
    grant select on tables to app_leitura;

grant select, insert, update, delete on all tables in schema :"esquema" to app_escrita;
grant usage, select on all sequences in schema :"esquema" to app_escrita;
alter default privileges in schema :"esquema"
    grant select, insert, update, delete on tables to app_escrita;
alter default privileges in schema :"esquema"
    grant usage, select on sequences to app_escrita;

-- TRUNCATE fica de fora de propósito: não passa por trigger de linha,
-- não deixa rastro por linha, e quase nunca é o que a pessoa quer.
revoke truncate on all tables in schema :"esquema" from app_escrita, app_leitura;

-- Ninguém cria objeto solto no esquema
revoke create on schema :"esquema" from public;

-- ---------------------------------------------------------------------
-- Contas nominais
--
-- Login compartilhado destrói a auditoria: guarda.evento passa a dizer
-- "foi o usuário app" em todo incidente. Uma conta por pessoa.
-- ---------------------------------------------------------------------
-- create role maria.silva login password '...' in role app_leitura;
-- create role joao.souza login password '...' in role app_leitura;
--
-- Escrita é concedida por cima da leitura, e a pessoa assume quando
-- precisa, com SET ROLE. Isso deixa o padrão do dia seguro:
-- grant app_escrita to maria.silva;

-- ---------------------------------------------------------------------
-- Coisas que só privilégio resolve, porque nem trigger nem event
-- trigger pegam
-- ---------------------------------------------------------------------

-- DROP DATABASE: event trigger não dispara para objeto do cluster.
-- Defesa é não ter CREATEDB e não ser dono do banco.
-- alter role maria.silva nocreatedb;
-- alter database seu_banco owner to dono_dados;

-- session_replication_role = replica desliga trigger de usuário e passa
-- por cima de todo o guard. É privilégio de superusuário. No PostgreSQL 15+
-- confirme que ninguém ganhou isso por GRANT:
select r.rolname, p.parameter_name
  from pg_catalog.pg_parameter_acl p
 cross join lateral aclexplode(p.paracl) a
  join pg_roles r on r.oid = a.grantee
 where p.parameter_name in ('session_replication_role', 'log_min_messages');

-- Superusuários passam por cima de tudo neste sistema. A lista precisa
-- ser curta e conhecida:
select rolname from pg_roles where rolsuper order by rolname;
