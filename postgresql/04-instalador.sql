-- =====================================================================
-- Guarda: etapa 4 de 5: instalador, verificação e relatórios
-- =====================================================================

-- manutencao() e em_manutencao() ficam em 01-base.sql

-- ---------------------------------------------------------------------
-- Instalação por tabela
--
-- relkind 'r' = tabela comum ou partição folha: recebe tudo.
-- relkind 'p' = tabela particionada pai: as linhas são tocadas nas
--               folhas, então aqui só entram as triggers de comando.
-- ---------------------------------------------------------------------
create or replace function guarda.instalar(p_esquema text, p_tabela text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_kind "char";
begin
    select c.relkind into v_kind
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = p_esquema and c.relname = p_tabela;

    if v_kind is null then
        raise exception 'GUARDA: %.% não existe.', p_esquema, p_tabela;
    end if;

    if v_kind not in ('r', 'p') then
        raise exception 'GUARDA: %.% não é tabela (relkind = %).',
            p_esquema, p_tabela, v_kind;
    end if;

    perform guarda.desinstalar(p_esquema, p_tabela);

    -- zera o contador no início de cada comando
    execute format($f$
        create trigger guarda_ini_delete before delete on %I.%I
        for each statement execute procedure guarda.iniciar_comando()$f$,
        p_esquema, p_tabela);

    execute format($f$
        create trigger guarda_ini_update before update on %I.%I
        for each statement execute procedure guarda.iniciar_comando()$f$,
        p_esquema, p_tabela);

    -- auditoria no fim de cada comando
    execute format($f$
        create trigger guarda_fim_delete after delete on %I.%I
        for each statement execute procedure guarda.registrar_comando()$f$,
        p_esquema, p_tabela);

    execute format($f$
        create trigger guarda_fim_update after update on %I.%I
        for each statement execute procedure guarda.registrar_comando()$f$,
        p_esquema, p_tabela);

    -- contagem linha a linha, só onde as linhas realmente passam
    if v_kind = 'r' then
        execute format($f$
            create trigger guarda_conta_delete before delete on %I.%I
            for each row execute procedure guarda.contar_e_checar()$f$,
            p_esquema, p_tabela);

        execute format($f$
            create trigger guarda_conta_update before update on %I.%I
            for each row execute procedure guarda.contar_e_checar()$f$,
            p_esquema, p_tabela);
    end if;

    -- TRUNCATE. Nem toda versão aceita trigger de truncate em tabela
    -- particionada, então aqui a falha é aviso e não erro.
    begin
        execute format($f$
            create trigger guarda_truncate before truncate on %I.%I
            for each statement execute procedure guarda.checar_truncate()$f$,
            p_esquema, p_tabela);
    exception when others then
        -- a string de formato do RAISE tem que ser literal, sem concatenação
        raise warning 'GUARDA: sem proteção de TRUNCATE em %.% (%). Revogue o privilégio TRUNCATE nessa tabela.',
            p_esquema, p_tabela, sqlerrm;
    end;
end;
$$;

-- ---------------------------------------------------------------------
create or replace function guarda.desinstalar(p_esquema text, p_tabela text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_nome      text;
    v_manut_ant text := coalesce(current_setting('guarda.manutencao', true), 'nao');
begin
    -- o event trigger de DDL bloqueia DROP de trigger do guard, inclusive
    -- este. Liga a manutenção só pelo tempo dos drops e devolve o valor
    -- anterior, para não deixar a transação inteira sem proteção.
    perform set_config('guarda.manutencao', 'sim', true);

    for v_nome in
        select t.tgname
          from pg_trigger t
          join pg_class c     on c.oid = t.tgrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = p_esquema
           and c.relname = p_tabela
           and t.tgname like 'guarda\_%'
    loop
        execute format('drop trigger %I on %I.%I', v_nome, p_esquema, p_tabela);
    end loop;

    perform set_config('guarda.manutencao', v_manut_ant, true);
end;
$$;

-- ---------------------------------------------------------------------
-- Instalação em lote
-- ---------------------------------------------------------------------
create or replace function guarda.instalar_esquema(p_esquema text)
returns table (tabela text, situacao text)
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    r record;
begin
    for r in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = p_esquema
           and c.relkind in ('r', 'p')
           and not c.relispartition        -- partições entram no segundo laço
         order by c.relname
    loop
        begin
            perform guarda.instalar(p_esquema, r.relname);
            return query select r.relname::text, 'protegida'::text;
        exception when others then
            return query select r.relname::text, ('falhou: ' || sqlerrm)::text;
        end;
    end loop;

    -- partições folha precisam da trigger de linha, porque é nelas que
    -- a linha é removida de fato
    for r in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = p_esquema
           and c.relkind = 'r'
           and c.relispartition
         order by c.relname
    loop
        begin
            perform guarda.instalar(p_esquema, r.relname);
            return query select r.relname::text, 'protegida (partição)'::text;
        exception when others then
            return query select r.relname::text, ('falhou: ' || sqlerrm)::text;
        end;
    end loop;
end;
$$;

create or replace function guarda.desinstalar_esquema(p_esquema text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    r record;
begin
    for r in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = p_esquema and c.relkind in ('r', 'p')
    loop
        perform guarda.desinstalar(p_esquema, r.relname);
    end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Verificação: o que ficou de fora
-- ---------------------------------------------------------------------
create or replace view guarda.sem_protecao as
select n.nspname  as esquema,
       c.relname  as tabela,
       c.relkind  as tipo,
       coalesce(c.reltuples, -1)::bigint as linhas_estimadas
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r', 'p')
   and n.nspname not in ('guarda', 'pg_catalog', 'information_schema')
   and n.nspname not like 'pg\_%'
   and not exists (
        select 1 from pg_trigger t
         where t.tgrelid = c.oid
           and t.tgname = case when c.relkind = 'r'
                               then 'guarda_conta_delete'
                               else 'guarda_ini_delete' end
   );

comment on view guarda.sem_protecao is
    'Tabelas que não têm o guard instalado. Deve ficar vazia.';

-- ---------------------------------------------------------------------
-- Relatórios operacionais
-- ---------------------------------------------------------------------
create or replace view guarda.painel_30d as
select date_trunc('day', ocorrido_em)::date as dia,
       resultado,
       comando,
       usuario,
       count(*)     as ocorrencias,
       sum(linhas)  as linhas_afetadas
  from guarda.evento
 where ocorrido_em >= now() - interval '30 days'
 group by 1, 2, 3, 4
 order by 1 desc, 6 desc nulls last;

create or replace view guarda.transacoes_presas as
select pid,
       usename                              as usuario,
       coalesce(application_name, '?')      as aplicacao,
       coalesce(host(client_addr), 'local') as host_cliente,
       state,
       now() - xact_start                   as transacao_aberta_ha,
       now() - state_change                 as parada_ha,
       left(coalesce(query, ''), 200)       as ultima_query
  from pg_stat_activity
 where xact_start is not null
   and state in ('idle in transaction', 'idle in transaction (aborted)')
   and now() - xact_start > interval '5 minutes'
 order by xact_start;

comment on view guarda.transacoes_presas is
    'Transação aberta e esquecida segurando lock. Causa comum de "o sistema travou".';

grant select on guarda.sem_protecao, guarda.painel_30d, guarda.transacoes_presas to public;

-- Instalar e desinstalar são SECURITY DEFINER e ligam o modo manutenção.
-- Não podem ficar acessíveis a quem opera o banco no dia a dia.
revoke all on function guarda.instalar(text, text)            from public;
revoke all on function guarda.desinstalar(text, text)         from public;
revoke all on function guarda.instalar_esquema(text)          from public;
revoke all on function guarda.desinstalar_esquema(text)       from public;

-- ---------------------------------------------------------------------
-- Adoção automática de tabelas novas (depende de guarda.instalar)
-- ---------------------------------------------------------------------
drop event trigger if exists guarda_et_create;
create event trigger guarda_et_create
    on ddl_command_end
    when tag in ('CREATE TABLE')
    execute procedure guarda.adotar_novas_tabelas();
