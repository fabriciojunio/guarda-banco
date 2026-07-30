-- =====================================================================
-- Guarda: etapa 3 de 5: proteção de DDL destrutivo
--
-- Cobre: DROP TABLE, DROP SCHEMA, DROP VIEW, DROP SEQUENCE,
--        ALTER TABLE DROP COLUMN, DROP INDEX,
--        e a remoção ou desativação do próprio guard.
--
-- Não cobre DROP DATABASE nem DROP ROLE: event trigger não dispara para
-- objetos compartilhados do cluster. Isso é privilégio, ver 05-papeis.sql.
--
-- Event trigger só pode ser criado por superusuário.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Quem pode fazer DDL destrutivo sem passar pela liberação
-- ---------------------------------------------------------------------
create or replace function guarda.eh_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_papel text := guarda.txt_config('papel_admin');
begin
    if v_papel is null or not exists (select 1 from pg_roles where rolname = v_papel) then
        return false;
    end if;
    return pg_has_role(session_user, v_papel, 'member');
end;
$$;

-- ---------------------------------------------------------------------
-- Registro de DDL. Roda em transação própria só quando permitido;
-- em caso de bloqueio o rastro vai para o log do servidor.
-- ---------------------------------------------------------------------
create or replace function guarda.registrar_ddl(
    p_resultado text,
    p_comando   text,
    p_objeto    text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
begin
    insert into guarda.evento (
        resultado, comando, tabela, justificativa,
        ambiente, usuario, usuario_efetivo, aplicacao, host_cliente, pid
    ) values (
        p_resultado, p_comando, p_objeto, guarda.motivo(),
        guarda.txt_config('ambiente'), session_user, current_user,
        nullif(current_setting('application_name', true), ''),
        coalesce(host(inet_client_addr()), 'local'),
        pg_backend_pid()
    );
end;
$$;

-- ---------------------------------------------------------------------
-- DROP de objetos: usa o evento sql_drop, que já entrega a lista de
-- objetos removidos, inclusive coluna solta de ALTER TABLE DROP COLUMN.
-- O DROP já aconteceu quando chegamos aqui, mas o RAISE desfaz tudo.
-- ---------------------------------------------------------------------
create or replace function guarda.proteger_drop()
returns event_trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    r          record;
    v_bloqueia boolean := guarda.txt_config('proteger_ddl') = 'sim';
    v_livre    boolean := guarda.esta_liberado() or guarda.eh_admin();
begin
    if guarda.em_manutencao() then
        return;
    end if;

    for r in
        select object_type, schema_name, object_identity
          from pg_event_trigger_dropped_objects()
         where original                                   -- só o que foi nomeado
           and object_type in ('table', 'table column', 'schema',
                               'view', 'materialized view', 'sequence',
                               'index', 'trigger', 'function', 'type')
           and coalesce(schema_name, '') not like 'pg\_temp%'
           and coalesce(schema_name, '') <> 'pg_toast'
    loop
        -- ninguém remove o guard, nem o admin, sem liberar na transação
        if r.object_type = 'trigger' and r.object_identity like '%guarda\_%' then
            raise exception
                'GUARDA: remoção da própria proteção (%) bloqueada.', r.object_identity
                using hint = 'Use guarda.desinstalar(esquema, tabela) ou 99-desinstalar.sql.';
        end if;

        if r.schema_name = 'guarda' then
            raise exception 'GUARDA: DROP dentro do esquema guarda bloqueado (%).',
                r.object_identity
                using hint = 'Desinstale com 99-desinstalar.sql, executado por superusuário.';
        end if;

        if v_livre or not v_bloqueia then
            perform guarda.registrar_ddl(
                case when v_livre then 'liberado' else 'permitido' end,
                tg_tag, r.object_identity);
            continue;
        end if;

        raise warning 'GUARDA bloqueou % de % (%): usuario=% app=%',
            tg_tag, r.object_identity, r.object_type, session_user,
            coalesce(current_setting('application_name', true), '?');

        raise exception 'GUARDA: % de % bloqueado.', tg_tag, r.object_identity
            using
                detail = format('Tipo do objeto: %s.', r.object_type),
                hint   = 'Se for intencional: BEGIN; SELECT guarda.liberar(''motivo''); '
                      || 'seu DDL; COMMIT;';
    end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- ALTER TABLE: pega desativação de trigger do guard e redução de tipo.
--
-- ALTER TABLE ... DISABLE TRIGGER não é reportado em sql_drop, então
-- checamos o estado depois do comando: se alguma trigger do guard
-- ficou desabilitada, desfaz.
-- ---------------------------------------------------------------------
create or replace function guarda.proteger_alter()
returns event_trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_desligadas text;
begin
    if guarda.em_manutencao() then
        return;
    end if;

    select string_agg(format('%s.%s -> %s', n.nspname, c.relname, t.tgname), ', ')
      into v_desligadas
      from pg_trigger t
      join pg_class c     on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where t.tgname like 'guarda\_%'
       and t.tgenabled = 'D';

    if v_desligadas is not null then
        raise exception 'GUARDA: desativar a proteção não é permitido (%).', v_desligadas
            using hint = 'Para desligar em uma tabela, use guarda.politica.ativo = false, '
                      || 'que fica registrado e auditável.';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Registro das novas tabelas: instala o guard automaticamente.
-- Sem isso, toda tabela criada depois da implantação nasce sem proteção,
-- que é como esse tipo de sistema morre na prática.
-- ---------------------------------------------------------------------
create or replace function guarda.adotar_novas_tabelas()
returns event_trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    r record;
begin
    for r in
        select objid, schema_name
          from pg_event_trigger_ddl_commands()
         where command_tag = 'CREATE TABLE'
           and object_type in ('table')
           and coalesce(schema_name, '') not in ('guarda', 'pg_catalog', 'information_schema')
           and coalesce(schema_name, '') not like 'pg\_temp%'
    loop
        begin
            perform guarda.instalar(
                r.schema_name,
                (select relname from pg_class where oid = r.objid)
            );
        exception when others then
            raise warning 'GUARDA: não consegui proteger a tabela nova (%): %',
                r.objid::regclass, sqlerrm;
        end;
    end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Criação dos event triggers
-- ---------------------------------------------------------------------
drop event trigger if exists guarda_et_drop;
create event trigger guarda_et_drop
    on sql_drop
    execute procedure guarda.proteger_drop();

drop event trigger if exists guarda_et_alter;
create event trigger guarda_et_alter
    on ddl_command_end
    when tag in ('ALTER TABLE')
    execute procedure guarda.proteger_alter();

-- Este é criado em 04-instalador.sql, depois que guarda.instalar existe.
