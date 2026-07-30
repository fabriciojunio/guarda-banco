-- =====================================================================
-- Guarda: remoção completa. Execute como superusuário.
--
-- Preserva guarda.evento por padrão, porque o histórico de exclusão de
-- dado pessoal tem valor legal (LGPD art. 37). Para apagar tudo mesmo,
-- veja o bloco comentado no fim.
-- =====================================================================

begin;

select guarda.manutencao();

drop event trigger if exists guarda_et_create;
drop event trigger if exists guarda_et_drop;
drop event trigger if exists guarda_et_alter;

do $$
declare
    r record;
begin
    for r in
        select n.nspname as esquema, c.relname as tabela, t.tgname
          from pg_trigger t
          join pg_class c     on c.oid = t.tgrelid
          join pg_namespace n on n.oid = c.relnamespace
         where t.tgname like 'guarda\_%'
           and not t.tgisinternal
    loop
        execute format('drop trigger %I on %I.%I', r.tgname, r.esquema, r.tabela);
    end loop;
end;
$$;

-- confere que não sobrou nada
select n.nspname, c.relname, t.tgname
  from pg_trigger t
  join pg_class c     on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where t.tgname like 'guarda\_%' and not t.tgisinternal;

commit;

-- Guarda o histórico e derruba o resto:
-- create table if not exists public.guarda_evento_arquivo as
--     select * from guarda.evento;
-- drop schema guarda cascade;
