-- =====================================================================
-- Guarda: etapa 2 de 5: funções de trigger para DELETE, UPDATE e TRUNCATE
--
-- Desenho: contador de linhas por comando, guardado em GUC de sessão
-- com escopo de transação.
--
--   BEFORE ... FOR EACH STATEMENT  -> zera o contador
--   BEFORE ... FOR EACH ROW        -> incrementa e aborta ao passar do limite
--   AFTER  ... FOR EACH STATEMENT  -> registra na auditoria
--
-- Abortar em BEFORE ROW é melhor que contar no fim: falha na linha
-- limite + 1, sem materializar milhões de linhas na memória, e sem
-- depender de transition table (que não existe em toda versão nem em
-- toda forma de particionamento).
--
-- O contador é por comando (DELETE/UPDATE) e não por tabela. Isso faz
-- um DELETE que dispara ON DELETE CASCADE somar o raio de destruição
-- inteiro, que é exatamente o que interessa medir.
-- =====================================================================

create or replace function guarda.chave_contador(p_comando text)
returns text
language sql
immutable
as $$
    select case upper(p_comando)
               when 'DELETE' then 'guarda.linhas_delete'
               else               'guarda.linhas_update'
           end;
$$;

create or replace function guarda.chave_nivel(p_comando text)
returns text
language sql
immutable
as $$
    select case upper(p_comando)
               when 'DELETE' then 'guarda.nivel_delete'
               else               'guarda.nivel_update'
           end;
$$;

create or replace function guarda.ler_contador(p_chave text)
returns bigint
language sql
stable
as $$
    select coalesce(nullif(current_setting(p_chave, true), ''), '0')::bigint;
$$;

-- ---------------------------------------------------------------------
-- Limite aplicável. NULL significa "sem limite" (proteção desligada
-- de propósito naquela tabela).
-- ---------------------------------------------------------------------
create or replace function guarda.limite(p_esquema text, p_tabela text, p_comando text)
returns integer
language plpgsql
stable
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_pol guarda.politica;
begin
    select * into v_pol
      from guarda.politica
     where esquema = p_esquema and tabela = p_tabela;

    if found and not v_pol.ativo then
        return null;
    end if;

    if upper(p_comando) = 'DELETE' then
        return coalesce(v_pol.limite_delete,
                        guarda.num_config('limite_delete_padrao', 500));
    else
        return coalesce(v_pol.limite_update,
                        guarda.num_config('limite_update_padrao', 500));
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- BEFORE STATEMENT: zera o contador, mas só no comando de primeiro nível
--
-- Um DELETE com ON DELETE CASCADE dispara um DELETE interno na tabela
-- filha, e esse comando interno tem as mesmas triggers. Sem controle de
-- nível, a filha zeraria o contador do pai a cada linha em cascata e o
-- limite nunca seria alcançado. Contando o nível, tudo que a cascata
-- remove entra na mesma conta, que é o raio de destruição real.
-- ---------------------------------------------------------------------
create or replace function guarda.iniciar_comando()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_nivel_chave text := guarda.chave_nivel(tg_op);
    v_nivel       bigint;
begin
    v_nivel := guarda.ler_contador(v_nivel_chave) + 1;
    perform set_config(v_nivel_chave, v_nivel::text, true);

    if v_nivel = 1 then
        perform set_config(guarda.chave_contador(tg_op), '0', true);
    end if;

    return null;
end;
$$;

-- ---------------------------------------------------------------------
-- BEFORE ROW: conta e decide
-- ---------------------------------------------------------------------
create or replace function guarda.contar_e_checar()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_chave   text := guarda.chave_contador(tg_op);
    v_linhas  bigint;
    v_limite  integer;
    v_retorno record;
begin
    if tg_op = 'DELETE' then
        v_retorno := old;
    else
        v_retorno := new;
    end if;

    v_linhas := guarda.ler_contador(v_chave) + 1;
    perform set_config(v_chave, v_linhas::text, true);

    if guarda.esta_liberado() then
        return v_retorno;
    end if;

    v_limite := guarda.limite(tg_table_schema, tg_table_name, tg_op);
    if v_limite is null or v_linhas <= v_limite then
        return v_retorno;
    end if;

    -- O RAISE EXCEPTION abaixo desfaz a transação inteira, e com ela
    -- qualquer INSERT que fizéssemos em guarda.evento. Por isso o
    -- registro do bloqueio vai para o log do servidor, que não é
    -- transacional. Ver docs/operacao.md para coletar isso.
    raise warning
        'GUARDA bloqueou % em %.%: % linhas, limite %. usuario=% app=% host=% pid=%',
        tg_op, tg_table_schema, tg_table_name, v_linhas, v_limite,
        session_user,
        coalesce(current_setting('application_name', true), '?'),
        coalesce(host(inet_client_addr()), 'local'),
        pg_backend_pid();

    raise exception
        'GUARDA: % em %.% passou de % linhas e foi bloqueado.',
        tg_op, tg_table_schema, tg_table_name, v_limite
        using
            errcode = 'P0001',
            detail  = 'Provável WHERE mais amplo do que o pretendido, ou CASCADE inesperado.',
            hint    = 'Se for intencional: BEGIN; SELECT guarda.liberar(''motivo''); '
                   || 'seu comando; -- confira as linhas e então COMMIT ou ROLLBACK;';
end;
$$;

-- ---------------------------------------------------------------------
-- AFTER STATEMENT: auditoria do que passou
-- ---------------------------------------------------------------------
create or replace function guarda.registrar_comando()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_nivel_chave text := guarda.chave_nivel(tg_op);
    v_nivel       bigint;
    v_linhas      bigint;
    v_limite      integer;
begin
    v_nivel := guarda.ler_contador(v_nivel_chave);
    perform set_config(v_nivel_chave, greatest(v_nivel - 1, 0)::text, true);

    -- só o comando de primeiro nível registra, senão uma cascata geraria
    -- um evento por tabela filha
    if v_nivel <> 1 then
        return null;
    end if;

    v_linhas := guarda.ler_contador(guarda.chave_contador(tg_op));

    if v_linhas = 0 then
        return null;
    end if;

    v_limite := guarda.limite(tg_table_schema, tg_table_name, tg_op);

    -- Registra o que foi liberado na mão, e o que foi grande mesmo
    -- estando dentro do limite. O resto seria só ruído.
    if not guarda.esta_liberado()
       and v_linhas < guarda.num_config('registrar_acima_de', 100) then
        return null;
    end if;

    insert into guarda.evento (
        resultado, comando, esquema, tabela, linhas, limite, justificativa,
        ambiente, usuario, usuario_efetivo, aplicacao, host_cliente, pid
    ) values (
        case when guarda.esta_liberado() then 'liberado' else 'permitido' end,
        tg_op, tg_table_schema, tg_table_name, v_linhas, v_limite, guarda.motivo(),
        guarda.txt_config('ambiente'), session_user, current_user,
        nullif(current_setting('application_name', true), ''),
        coalesce(host(inet_client_addr()), 'local'),
        pg_backend_pid()
    );

    return null;
end;
$$;

-- ---------------------------------------------------------------------
-- BEFORE TRUNCATE
--
-- TRUNCATE não passa por trigger de linha, então precisa de guarda
-- própria. Também não é interceptado por event trigger de DDL.
-- ---------------------------------------------------------------------
create or replace function guarda.checar_truncate()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
declare
    v_bloquear boolean;
begin
    select coalesce(bool_and(bloquear_truncate and ativo), true) into v_bloquear
      from guarda.politica
     where esquema = tg_table_schema and tabela = tg_table_name;

    if not v_bloquear then
        return null;
    end if;

    if guarda.esta_liberado() then
        insert into guarda.evento (
            resultado, comando, esquema, tabela, justificativa,
            ambiente, usuario, usuario_efetivo, aplicacao, host_cliente, pid
        ) values (
            'liberado', 'TRUNCATE', tg_table_schema, tg_table_name, guarda.motivo(),
            guarda.txt_config('ambiente'), session_user, current_user,
            nullif(current_setting('application_name', true), ''),
            coalesce(host(inet_client_addr()), 'local'),
            pg_backend_pid()
        );
        return null;
    end if;

    raise warning
        'GUARDA bloqueou TRUNCATE em %.%: usuario=% app=% host=%',
        tg_table_schema, tg_table_name, session_user,
        coalesce(current_setting('application_name', true), '?'),
        coalesce(host(inet_client_addr()), 'local');

    raise exception 'GUARDA: TRUNCATE em %.% bloqueado.',
        tg_table_schema, tg_table_name
        using
            detail = 'TRUNCATE não é transacionalmente reversível em toda situação '
                  || 'e não deixa rastro linha a linha.',
            hint   = 'Prefira DELETE em lotes. Se TRUNCATE é mesmo necessário: '
                  || 'BEGIN; SELECT guarda.liberar(''motivo''); TRUNCATE ...; COMMIT;';
end;
$$;
