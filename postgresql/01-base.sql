-- =====================================================================
-- Guarda: trilhos de segurança contra DML/DDL destrutivo acidental
-- Etapa 1 de 5: esquema, configuração, auditoria e válvula de escape
--
-- Execute como superusuário ou dono do banco.
-- Requer PostgreSQL 10 ou superior.
-- =====================================================================

create schema if not exists guarda;
comment on schema guarda is
    'Proteção contra operações destrutivas acidentais. Ver guarda-banco/docs.';

-- ---------------------------------------------------------------------
-- Configuração global
-- ---------------------------------------------------------------------
create table if not exists guarda.config (
    chave     text primary key,
    valor     text not null,
    descricao text not null
);

insert into guarda.config (chave, valor, descricao) values
    ('ambiente',
     'producao',
     'producao | homologacao | desenvolvimento. Só informativo, aparece na auditoria.'),

    ('limite_delete_padrao',
     '500',
     'Linhas que um DELETE pode remover sem liberação explícita.'),

    ('limite_update_padrao',
     '500',
     'Linhas que um UPDATE pode alterar sem liberação explícita.'),

    ('registrar_acima_de',
     '100',
     'Operações permitidas acima deste número de linhas vão para guarda.evento.'),

    ('exigir_justificativa',
     'sim',
     'Se sim, guarda.liberar() exige motivo com no mínimo 15 caracteres.'),

    ('papel_admin',
     'guarda_admin',
     'Papel que pode executar DDL destrutivo sem passar por guarda.liberar().'),

    ('proteger_ddl',
     'sim',
     'Se nao, os event triggers de DDL param de bloquear (continuam registrando).')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- Política por tabela. Tabela sem linha aqui usa os padrões globais.
-- ---------------------------------------------------------------------
create table if not exists guarda.politica (
    esquema           text    not null,
    tabela            text    not null,
    limite_delete     integer,
    limite_update     integer,
    bloquear_truncate boolean not null default true,
    ativo             boolean not null default true,
    observacao        text,
    primary key (esquema, tabela),
    constraint politica_limites_positivos
        check (coalesce(limite_delete, 1) >= 0 and coalesce(limite_update, 1) >= 0)
);

comment on column guarda.politica.ativo is
    'false desliga a proteção nesta tabela de propósito. Preencha observacao.';

-- ---------------------------------------------------------------------
-- Auditoria
-- ---------------------------------------------------------------------
create table if not exists guarda.evento (
    id              bigserial primary key,
    ocorrido_em     timestamptz not null default clock_timestamp(),
    resultado       text        not null
        check (resultado in ('permitido', 'liberado', 'bloqueado', 'configuracao')),
    comando         text        not null,
    esquema         text,
    tabela          text,
    linhas          bigint,
    limite          integer,
    justificativa   text,
    ambiente        text,
    usuario         text        not null,
    usuario_efetivo text        not null,
    aplicacao       text,
    host_cliente    text,
    pid             integer
);

create index if not exists evento_ocorrido_em_idx
    on guarda.evento (ocorrido_em desc);
create index if not exists evento_tabela_idx
    on guarda.evento (esquema, tabela, ocorrido_em desc);

comment on table guarda.evento is
    'Rastro de operações de grande porte. Atende LGPD art. 37 para exclusão de dado pessoal.';

-- ---------------------------------------------------------------------
-- Leitura de configuração
-- ---------------------------------------------------------------------
create or replace function guarda.txt_config(p_chave text)
returns text
language sql
stable
security definer
set search_path = pg_catalog, guarda
as $$
    select valor from guarda.config where chave = p_chave;
$$;

create or replace function guarda.num_config(p_chave text, p_padrao integer)
returns integer
language sql
stable
security definer
set search_path = pg_catalog, guarda
as $$
    select coalesce(
        (select nullif(btrim(valor), '')::integer from guarda.config where chave = p_chave),
        p_padrao
    );
$$;

-- ---------------------------------------------------------------------
-- Válvula de escape
--
-- set_config com is_local = true amarra a liberação à TRANSAÇÃO atual.
-- Isso é de propósito: com autocommit ligado, o SELECT guarda.liberar()
-- vira uma transação sozinha e a liberação morre antes do DELETE chegar.
-- Ou seja, operação em massa só passa dentro de um BEGIN explícito, onde
-- você ainda consegue olhar o número de linhas e dar ROLLBACK.
-- ---------------------------------------------------------------------
create or replace function guarda.liberar(p_motivo text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, guarda
as $$
begin
    if guarda.txt_config('exigir_justificativa') = 'sim'
       and (p_motivo is null or length(btrim(p_motivo)) < 15) then
        raise exception 'GUARDA: informe um motivo com pelo menos 15 caracteres.'
            using hint = 'Exemplo: SELECT guarda.liberar(''expurgo LGPD ticket 4821'');';
    end if;

    perform set_config('guarda.liberado', 'sim', true);
    perform set_config('guarda.motivo', btrim(p_motivo), true);

    return format(
        'Liberado nesta transação por %s. Confira o total de linhas antes do COMMIT.',
        session_user
    );
end;
$$;

comment on function guarda.liberar(text) is
    'Libera operações acima do limite APENAS na transação atual. Use dentro de BEGIN.';

create or replace function guarda.esta_liberado()
returns boolean
language sql
stable
as $$
    select coalesce(current_setting('guarda.liberado', true), 'nao') = 'sim';
$$;

create or replace function guarda.motivo()
returns text
language sql
stable
as $$
    select nullif(current_setting('guarda.motivo', true), '');
$$;

-- ---------------------------------------------------------------------
-- Modo manutenção: permite ao superusuário mexer no próprio guard,
-- para instalar, desinstalar ou corrigir. Escopo de transação.
-- ---------------------------------------------------------------------
create or replace function guarda.manutencao()
returns text
language plpgsql
as $$
begin
    if not exists (select 1 from pg_roles where rolname = session_user and rolsuper) then
        raise exception 'GUARDA: modo manutenção é só para superusuário.';
    end if;
    perform set_config('guarda.manutencao', 'sim', true);
    return 'Modo manutenção ativo nesta transação.';
end;
$$;

create or replace function guarda.em_manutencao()
returns boolean
language sql
stable
as $$
    select coalesce(current_setting('guarda.manutencao', true), 'nao') = 'sim';
$$;

-- ---------------------------------------------------------------------
-- Permissões do próprio esquema: todo mundo executa as funções de
-- consulta e liberação, ninguém mexe nas tabelas direto.
-- ---------------------------------------------------------------------
revoke all on schema guarda from public;
grant usage on schema guarda to public;

revoke all on all tables in schema guarda from public;
grant select on guarda.config, guarda.politica, guarda.evento to public;

grant execute on function guarda.liberar(text)        to public;
grant execute on function guarda.esta_liberado()      to public;
grant execute on function guarda.motivo()             to public;
grant execute on function guarda.txt_config(text)     to public;
grant execute on function guarda.num_config(text, integer) to public;
grant execute on function guarda.em_manutencao()      to public;

-- manutencao() checa superusuário por dentro, mas não é para estar
-- à mão de todo mundo
revoke all on function guarda.manutencao() from public;
