-- =====================================================================
-- Controle de gastos — migração v2
-- Parcelas, contas a receber, categoria da Carteira, importação de extrato,
-- fila offline dos atalhos, avisos (meta, fora do padrão, fatura, resumo) e backup.
-- =====================================================================

-- ---------- 1. Colunas novas na tabela de gastos ----------
alter table public.gastos
  add column if not exists parcela_grupo uuid,              -- liga as parcelas de uma mesma compra
  add column if not exists parcela_num int,                 -- 1, 2, 3...
  add column if not exists parcela_total int,               -- total de parcelas (ex.: 10)
  add column if not exists a_receber numeric(10,2)          -- quanto alguém vai te devolver
    check (a_receber is null or a_receber > 0),
  add column if not exists devedor text,                    -- quem vai devolver
  add column if not exists quitado boolean not null default false, -- já devolveu?
  add column if not exists categoria_carteira text,         -- categoria que a Carteira do iPhone manda
  add column if not exists ref_externa text,                -- id único (fila do atalho ou extrato) p/ não duplicar
  add column if not exists origem text not null default 'auto'; -- auto | manual | importado | parcela

create unique index if not exists gastos_ref_externa_unica on public.gastos (ref_externa);

-- ---------- 2. Configurações (dia de fechamento/vencimento da fatura etc.) ----------
create table if not exists public.config (
  chave text primary key,
  valor text not null
);
alter table public.config enable row level security;
grant select, insert, update, delete on public.config to authenticated;

-- Pendências (itens que a automação não conseguiu entender): o painel lê e apaga
grant select, delete on public.pix_nao_reconhecido to authenticated;

-- Mesma regra de acesso da tabela gastos (só o seu login), sem repetir o e-mail aqui
do $$
declare cond text;
begin
  select qual into cond from pg_policies
   where schemaname = 'public' and tablename = 'gastos' and policyname = 'somente o dono';
  if not exists (select 1 from pg_policies where tablename = 'config' and policyname = 'somente o dono') then
    execute format('create policy "somente o dono" on public.config for all to authenticated using (%s) with check (%s)', cond, cond);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'pix_nao_reconhecido' and policyname = 'somente o dono') then
    execute format('create policy "somente o dono" on public.pix_nao_reconhecido for all to authenticated using (%s) with check (%s)', cond, cond);
  end if;
end $$;

-- ---------- 3. Funções auxiliares ----------
-- Formata dinheiro no padrão brasileiro: 1234.5 -> "R$ 1.234,50"
create or replace function public._brl(x numeric) returns text
language sql immutable set search_path = '' as $$
  select 'R$ ' || translate(to_char(coalesce(x, 0), 'FM999,999,990.00'), ',.', '.,')
$$;

-- Converte "25.9", "25,90" ou "R$ 1.234,56" em número
create or replace function public._numero(t text) returns numeric
language sql immutable set search_path = '' as $$
  select case
    when t ~ ',' then replace(replace(regexp_replace(t, '[^0-9,.-]', '', 'g'), '.', ''), ',', '.')::numeric
    else regexp_replace(t, '[^0-9.-]', '', 'g')::numeric
  end
$$;

-- Dia X do mês de uma data (ajusta pra meses curtos: dia 31 em fevereiro vira 28/29)
create or replace function public._dia_no_mes(base date, dia int) returns date
language sql immutable set search_path = '' as $$
  select make_date(extract(year from base)::int, extract(month from base)::int,
    least(dia, extract(day from (date_trunc('month', base) + interval '1 month - 1 day'))::int))
$$;

-- ---------- 4. Categoria automática (agora também usa a categoria da Carteira) ----------
create or replace function public.definir_categoria()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.categoria is null then
    if new.descricao ilike '%arthur jos_ das virgens%' then
      new.categoria := 'Transferência';              -- dinheiro entre as suas contas
    elsif new.tipo = 'entrada' then
      new.categoria := 'Entrada';
    else
      -- 1º: suas regras (a mais específica ganha)
      select r.categoria into new.categoria
        from public.regras_categoria r
       where new.descricao ilike '%' || r.padrao || '%'
       order by length(r.padrao) desc
       limit 1;
      -- 2º: categoria que a Carteira do iPhone mandou
      if new.categoria is null and new.categoria_carteira is not null then
        new.categoria := case
          when new.categoria_carteira ~* '(grocer|supermarket|supermerc|mercado)' then 'Mercado'
          when new.categoria_carteira ~* '(food|drink|restaurant|aliment|restaurante|bebida)' then 'Alimentação'
          when new.categoria_carteira ~* '(fuel|gas station|combust|posto)' then 'Combustível'
          when new.categoria_carteira ~* '(transport|travel|taxi|ride|viage)' then 'Transporte'
          when new.categoria_carteira ~* '(health|pharm|medic|saúde|farm)' then 'Farmácia'
          when new.categoria_carteira ~* '(entertain|game|lazer|entreten)' then 'Lazer'
          else null
        end;
      end if;
      new.categoria := coalesce(new.categoria, 'Outros');
    end if;
  end if;
  return new;
end;
$$;

-- ---------- 5. Pix: lê a notificação e grava (usado pela fila e pela função antiga) ----------
create or replace function public._inserir_pix(titulo text, texto text, banco text, ref text, quando timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_tipo text; v_valor numeric; v_nome text; v_id uuid;
begin
  if titulo ilike '%pix enviado%' then v_tipo := 'saida';
  elsif titulo ilike '%pix recebido%' then v_tipo := 'entrada';
  else return null;                                   -- outra notificação: ignora
  end if;

  v_valor := replace(replace((regexp_match(texto, 'R\$\D{0,3}([\d.]+,\d{2})'))[1], '.', ''), ',', '.')::numeric;
  if v_tipo = 'saida' then
    v_nome := (regexp_match(texto, '\s(?:para|pra)\s(.+)$'))[1];          -- Inter "para" / Bradesco "pra"
  else
    v_nome := coalesce((regexp_match(texto, '^(.+)\s+te enviou'))[1],    -- Inter
                       (regexp_match(texto, 'R\$\D{0,3}[\d.]+,\d{2}\s+de\s+(.+)$'))[1]); -- Bradesco
  end if;
  v_nome := rtrim(trim(v_nome), '.');

  if v_valor is null or v_nome is null then
    insert into public.pix_nao_reconhecido (titulo, texto) values (titulo, texto);
    return null;
  end if;

  insert into public.gastos (valor, descricao, meio, tipo, banco, ref_externa, criado_em)
  values (v_valor, v_nome, 'pix', v_tipo, lower(nullif(banco, '')), nullif(ref, ''), coalesce(quando, now()))
  on conflict (ref_externa) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- A função antiga continua funcionando (atalhos ainda não migrados)
create or replace function public.registrar_pix(titulo text, texto text, banco text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._inserir_pix(titulo, texto, banco, null, now());
end;
$$;

-- ---------- 6. Um item da fila (cartão ou Pix) ----------
create or replace function public._registrar_item(item jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if item->>'tipo' = 'pix' then
    return public._inserir_pix(item->>'titulo', item->>'texto', item->>'banco', item->>'id_local',
                               nullif(item->>'quando', '')::timestamptz);
  end if;
  insert into public.gastos (valor, descricao, meio, banco, categoria_carteira, ref_externa, criado_em)
  values (public._numero(item->>'valor'),
          coalesce(nullif(trim(item->>'descricao'), ''), 'Compra no cartão'),
          coalesce(nullif(item->>'meio', ''), 'credito'),
          lower(nullif(item->>'banco', '')),
          nullif(item->>'categoria_carteira', ''),
          nullif(item->>'id_local', ''),
          coalesce(nullif(item->>'quando', '')::timestamptz, now()))
  on conflict (ref_externa) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- 7. Avisos logo depois de um gasto (meta e fora do padrão) ----------
create or replace function public._avisos_do_gasto(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  g record; ini timestamptz; fim timestamptz;
  total numeric; total_cat numeric; meta numeric; meta_cat numeric;
  media numeric; n int; msgs text[] := '{}';
begin
  select * into g from public.gastos where id = p_id;
  if g.id is null or g.tipo <> 'saida' or g.categoria = 'Transferência' then return null; end if;

  ini := date_trunc('month', g.criado_em at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  fim := ini + interval '1 month';
  select coalesce(sum(valor - coalesce(a_receber, 0)), 0) into total from public.gastos
   where tipo = 'saida' and categoria is distinct from 'Transferência' and criado_em >= ini and criado_em < fim;
  select coalesce(sum(valor - coalesce(a_receber, 0)), 0) into total_cat from public.gastos
   where tipo = 'saida' and categoria = g.categoria and criado_em >= ini and criado_em < fim;
  select valor into meta from public.metas where escopo = 'total';
  select valor into meta_cat from public.metas where escopo = g.categoria;

  -- Só avisa quando ESTE gasto cruzou 80% ou 100% (não repete a cada compra)
  if meta is not null then
    if total >= meta and total - g.valor < meta then
      msgs := msgs || format('Meta do mês estourada: %s de %s.', public._brl(total), public._brl(meta));
    elsif total >= 0.8 * meta and total - g.valor < 0.8 * meta then
      msgs := msgs || format('Você já usou %s%% da meta do mês (%s de %s).', round(total / meta * 100), public._brl(total), public._brl(meta));
    end if;
  end if;
  if meta_cat is not null then
    if total_cat >= meta_cat and total_cat - g.valor < meta_cat then
      msgs := msgs || format('Meta de %s estourada: %s de %s.', g.categoria, public._brl(total_cat), public._brl(meta_cat));
    elsif total_cat >= 0.8 * meta_cat and total_cat - g.valor < 0.8 * meta_cat then
      msgs := msgs || format('%s: %s%% da meta (%s de %s).', g.categoria, round(total_cat / meta_cat * 100), public._brl(total_cat), public._brl(meta_cat));
    end if;
  end if;

  -- Fora do padrão: pelo menos 3x a média dos últimos 90 dias da categoria (com 5+ gastos de base)
  select avg(valor), count(*) into media, n from public.gastos
   where tipo = 'saida' and categoria = g.categoria and id <> g.id and parcela_total is null
     and criado_em >= g.criado_em - interval '90 days' and criado_em < g.criado_em;
  if n >= 5 and g.valor >= 3 * media and g.valor - media >= 50 then
    msgs := msgs || format('Gasto fora do padrão: %s em %s. A média em %s é %s.',
                           public._brl(g.valor), g.descricao, g.categoria, public._brl(media));
  end if;

  return nullif(array_to_string(msgs, E'\n'), '');
end;
$$;

-- ---------- 8. Fila do atalho: recebe vários itens separados por @@FIM@@ ----------
-- Nunca dá erro: item com problema vai pras pendências, pra fila do iPhone sempre esvaziar.
-- Responde "OK" (+ avisos, se houver). O atalho só limpa a fila se vier "OK".
create or replace function public.registrar_fila(fila text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  pedaco text; v_id uuid; aviso text; avisos text[] := '{}';
begin
  foreach pedaco in array string_to_array(coalesce(fila, ''), '@@FIM@@') loop
    pedaco := trim(both E' \n\r\t' from pedaco);
    continue when pedaco = '';
    begin
      v_id := public._registrar_item(pedaco::jsonb);
      if v_id is not null then
        aviso := public._avisos_do_gasto(v_id);
        if aviso is not null then avisos := avisos || aviso; end if;
      end if;
    exception when others then
      insert into public.pix_nao_reconhecido (titulo, texto) values ('Erro: ' || sqlerrm, left(pedaco, 2000));
    end;
  end loop;
  return 'OK' || coalesce(E'\n' || nullif(array_to_string(avisos, E'\n'), ''), '');
end;
$$;

-- ---------- 9. Avisos do dia: lembrete da fatura + resumo semanal ----------
create or replace function public.avisos_do_dia()
returns text language plpgsql security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  f int; v int; dias_lembrete int; dia_resumo int;
  venc date; fech date; fech_ant date; total_fatura numeric;
  sem_ini timestamptz; mes_ini timestamptz; total_sem numeric; n_sem int;
  cat_top text; val_top numeric; total_mes numeric; meta numeric;
  msgs text[] := '{}';
begin
  select valor::int into f from public.config where chave = 'fatura_fechamento';
  select valor::int into v from public.config where chave = 'fatura_vencimento';
  dias_lembrete := coalesce((select valor::int from public.config where chave = 'lembrete_dias'), 3);
  dia_resumo := coalesce((select valor::int from public.config where chave = 'resumo_dia_semana'), 0); -- 0 = domingo

  -- Lembrete da fatura: X dias antes e no dia do vencimento
  if f is not null and v is not null then
    venc := public._dia_no_mes(hoje, v);
    if venc < hoje then venc := public._dia_no_mes((hoje + interval '1 month')::date, v); end if;
    if venc - hoje = dias_lembrete or venc = hoje then
      fech := public._dia_no_mes(venc, f);
      if fech >= venc then fech := public._dia_no_mes((venc - interval '1 month')::date, f); end if;
      fech_ant := public._dia_no_mes((fech - interval '1 month')::date, f);
      select coalesce(sum(valor), 0) into total_fatura from public.gastos
       where meio = 'credito' and tipo = 'saida'
         and (criado_em at time zone 'America/Sao_Paulo')::date >= fech_ant
         and (criado_em at time zone 'America/Sao_Paulo')::date < fech;
      msgs := msgs || case when venc = hoje
        then format('A fatura do cartão vence hoje: %s.', public._brl(total_fatura))
        else format('A fatura do cartão vence em %s dias (%s): %s.', venc - hoje, to_char(venc, 'DD/MM'), public._brl(total_fatura)) end;
    end if;
  end if;

  -- Resumo semanal (últimos 7 dias)
  if extract(dow from hoje) = dia_resumo then
    sem_ini := (hoje - 6)::timestamp at time zone 'America/Sao_Paulo';
    mes_ini := date_trunc('month', hoje)::timestamp at time zone 'America/Sao_Paulo';
    select coalesce(sum(valor - coalesce(a_receber, 0)), 0), count(*) into total_sem, n_sem from public.gastos
     where tipo = 'saida' and categoria is distinct from 'Transferência' and criado_em >= sem_ini and criado_em <= now();
    select categoria, sum(valor - coalesce(a_receber, 0)) into cat_top, val_top from public.gastos
     where tipo = 'saida' and categoria is distinct from 'Transferência' and criado_em >= sem_ini and criado_em <= now()
     group by categoria order by 2 desc limit 1;
    select coalesce(sum(valor - coalesce(a_receber, 0)), 0) into total_mes from public.gastos
     where tipo = 'saida' and categoria is distinct from 'Transferência' and criado_em >= mes_ini and criado_em <= now();
    select valor into meta from public.metas where escopo = 'total';
    if n_sem = 0 then
      msgs := msgs || 'Resumo da semana: nenhum gasto registrado.';
    else
      msgs := msgs || format('Resumo da semana: %s em %s gastos. Mais pesou: %s (%s). No mês: %s%s.',
        public._brl(total_sem), n_sem, cat_top, public._brl(val_top), public._brl(total_mes),
        case when meta is not null then format(' (%s%% da meta)', round(total_mes / meta * 100)) else '' end);
    end if;
  end if;

  return array_to_string(msgs, E'\n');
end;
$$;

-- ---------- 10. Backup: tudo em um JSON ----------
create or replace function public.exportar_tudo()
returns jsonb language sql security definer set search_path = '' as $$
  select jsonb_build_object(
    'gerado_em', now(),
    'gastos',  coalesce((select jsonb_agg(g order by g.criado_em) from public.gastos g), '[]'::jsonb),
    'metas',   coalesce((select jsonb_agg(m) from public.metas m), '[]'::jsonb),
    'regras',  coalesce((select jsonb_agg(r) from public.regras_categoria r), '[]'::jsonb),
    'config',  coalesce((select jsonb_agg(c) from public.config c), '[]'::jsonb))
$$;

-- ---------- 11. Permissões das funções ----------
-- O Postgres libera funções novas pra todo mundo por padrão: fecha tudo e libera só o necessário.
do $$
declare fn text;
begin
  foreach fn in array array[
    'public._brl(numeric)', 'public._numero(text)', 'public._dia_no_mes(date, integer)',
    'public._inserir_pix(text, text, text, text, timestamptz)', 'public.registrar_pix(text, text, text)',
    'public._registrar_item(jsonb)', 'public._avisos_do_gasto(uuid)', 'public.registrar_fila(text)',
    'public.avisos_do_dia()', 'public.exportar_tudo()', 'public.definir_categoria()'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', fn);
  end loop;
end $$;
grant execute on function public.registrar_fila(text) to service_role;
grant execute on function public.registrar_pix(text, text, text) to service_role;
grant execute on function public.avisos_do_dia() to service_role;
grant execute on function public.exportar_tudo() to service_role;
