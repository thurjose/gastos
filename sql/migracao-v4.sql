-- Controle de gastos: migração v4 (tags, foto do comprovante, lançar por voz)

-- 1. Tags e comprovante
alter table public.gastos add column if not exists tags text[] not null default '{}';
alter table public.gastos add column if not exists comprovante text;
create index if not exists gastos_tags_idx on public.gastos using gin (tags);

-- 2. Pasta privada das fotos (até 5 MB por foto), só o seu login acessa
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
do $$
declare cond text;
begin
  select qual into cond from pg_policies where schemaname = 'public' and tablename = 'gastos' and policyname = 'somente o dono';
  drop policy if exists "comprovantes do dono" on storage.objects;
  execute format('create policy "comprovantes do dono" on storage.objects for all to authenticated using (bucket_id = %L and %s) with check (bucket_id = %L and %s)', 'comprovantes', cond, 'comprovantes', cond);
end $$;

-- 3. Voz: "gastei 20 reais na padaria", "paguei 35,90 no uber no crédito", "recebi 50 do Pedro"
create or replace function public._inserir_voz(p_texto text, ref text, quando timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  t text := trim(coalesce(p_texto, ''));
  num constant text := '(?:r\$\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:\s*(?:reais|real|contos?|pila))?(?:\s+e\s+(\d{1,2})\s*centavos?)?';
  m text[]; partes text[]; v_valor numeric; v_desc text; v_id uuid;
  v_tipo text := 'saida'; v_meio text := 'pix'; v_banco text; v_quando timestamptz := coalesce(quando, now());
begin
  if t ~* '^(eu\s+)?(recebi|ganhei|entrou|caiu|me pagaram|me pagou)\M' then v_tipo := 'entrada'; end if;
  if t ~* 'cr[eé]dito' then v_meio := 'credito'; elsif t ~* 'd[eé]bito' then v_meio := 'debito'; end if;
  if t ~* '\minter\M' then v_banco := 'inter'; elsif t ~* '\mbradesco\M' then v_banco := 'bradesco'; end if;
  if t ~* '\montem\M' then v_quando := v_quando - interval '1 day'; end if;
  -- tira forma de pagamento, banco e dia do texto
  t := regexp_replace(t, '\s*\m(?:(?:no|na|pelo|pela|do|da|com)\s+)?(?:cart[aã]o\s+(?:de\s+)?)?(?:cr[eé]dito|d[eé]bito|pix|inter|bradesco|cart[aã]o)\M', '', 'gi');
  t := regexp_replace(t, '\s*\m(?:ontem|hoje)\M', '', 'gi');
  m := regexp_match(t, num, 'i');
  if m is not null then
    v_valor := case when m[1] ~ ',' then replace(replace(m[1], '.', ''), ',', '.')::numeric
                    when m[1] ~ '^\d{1,3}(\.\d{3})+$' then replace(m[1], '.', '')::numeric
                    else m[1]::numeric end + coalesce(m[2]::numeric / 100, 0);
    -- descrição: o que vem depois do valor; se não tiver, o que vem antes
    partes := string_to_array(regexp_replace(t, num, '§', 'i'), '§');
    v_desc := regexp_replace(trim(coalesce(partes[2], '')), '^(?:(?:na|no|nas|nos|numa|num|em|de|do|da|dos|das|com|pro|pra|para|pelo|pela)\s+)', '', 'i');
    if trim(both ' .,!?' from v_desc) = '' then
      v_desc := regexp_replace(trim(partes[1]), '^(?:eu\s+)?(?:gastei|paguei|comprei|recebi|ganhei|entrou|caiu|foi|deu|me pagaram|me pagou)\M\s*', '', 'i');
      v_desc := regexp_replace(v_desc, '\s+(?:de|em|no|na|com)$', '', 'i');
    end if;
    v_desc := trim(both ' .,!?' from v_desc);
  end if;
  if v_valor is null or v_valor <= 0 or coalesce(v_desc, '') = '' then
    insert into public.pix_nao_reconhecido (titulo, texto) values ('Não entendi (voz)', p_texto);
    return null;
  end if;
  insert into public.gastos (valor, descricao, meio, tipo, banco, ref_externa, criado_em, origem)
  values (v_valor, upper(left(v_desc, 1)) || substr(v_desc, 2), v_meio, v_tipo, v_banco, nullif(ref, ''), v_quando, 'voz')
  on conflict (ref_externa) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- 4. Regras de categoria ignoram acentos ("Farmácia" bate com a regra FARMACIA)
create or replace function public._sem_acento(t text) returns text
language sql immutable set search_path = '' as $$
  select translate(lower(coalesce(t, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')
$$;
create or replace function public.definir_categoria()
returns trigger language plpgsql security definer set search_path = '' as $$
declare lista jsonb;
begin
  if new.categoria is null then
    if new.descricao ilike '%arthur jos_ das virgens%' then
      new.categoria := 'Transferência';
    elsif new.tipo = 'entrada' then
      new.categoria := 'Entrada';
    else
      select r.categoria into new.categoria from public.regras_categoria r
       where public._sem_acento(new.descricao) like '%' || public._sem_acento(r.padrao) || '%'
       order by length(r.padrao) desc limit 1;
      if new.categoria is null and new.categoria_carteira is not null then
        new.categoria := case
          when new.categoria_carteira ~* '(grocer|supermarket|supermerc|mercado)' then 'Mercado'
          when new.categoria_carteira ~* '(food|drink|restaurant|aliment|restaurante|bebida)' then 'Alimentação'
          when new.categoria_carteira ~* '(fuel|gas station|combust|posto)' then 'Combustível'
          when new.categoria_carteira ~* '(transport|travel|taxi|ride|viage)' then 'Transporte'
          when new.categoria_carteira ~* '(health|pharm|medic|saúde|farm)' then 'Farmácia'
          when new.categoria_carteira ~* '(entertain|game|lazer|entreten)' then 'Lazer'
          else null end;
        select valor::jsonb into lista from public.config where chave = 'categorias';
        if new.categoria is not null and lista is not null and not (lista ? new.categoria) then
          new.categoria := null;
        end if;
      end if;
      new.categoria := coalesce(new.categoria, 'Outros');
    end if;
  end if;
  return new;
end;
$$;

-- 5. A fila aceita itens de voz
create or replace function public._registrar_item(item jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if item->>'tipo' = 'pix' then
    return public._inserir_pix(item->>'titulo', item->>'texto', item->>'banco', item->>'id_local', nullif(item->>'quando', '')::timestamptz);
  end if;
  if item->>'tipo' = 'voz' then
    return public._inserir_voz(item->>'texto', item->>'id_local', nullif(item->>'quando', '')::timestamptz);
  end if;
  insert into public.gastos (valor, descricao, meio, banco, categoria_carteira, ref_externa, criado_em)
  values (public._numero(item->>'valor'), coalesce(nullif(trim(item->>'descricao'), ''), 'Compra no cartão'),
          coalesce(nullif(item->>'meio', ''), 'credito'), lower(nullif(item->>'banco', '')),
          nullif(item->>'categoria_carteira', ''), nullif(item->>'id_local', ''),
          coalesce(nullif(item->>'quando', '')::timestamptz, now()))
  on conflict (ref_externa) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- 6. Fila: na voz, responde o que foi anotado (ou que não entendeu)
create or replace function public.registrar_fila(fila text)
returns text language plpgsql security definer set search_path = '' as $$
declare pedaco text; item jsonb; v_id uuid; g record; aviso text; avisos text[] := '{}';
begin
  foreach pedaco in array string_to_array(coalesce(fila, ''), '@@FIM@@') loop
    pedaco := trim(both E' \n\r\t' from pedaco);
    continue when pedaco = '';
    begin
      item := pedaco::jsonb;
      v_id := public._registrar_item(item);
      if item->>'tipo' = 'voz' then
        if v_id is null then
          -- reenvio de algo já anotado (fila repetida) fica quieto
          if not exists (select 1 from public.gastos where ref_externa = item->>'id_local') then
            avisos := avisos || format('Não entendi "%s". Ficou em Ajustes, em Precisam de revisão.', item->>'texto');
          end if;
        else
          select valor, descricao, categoria, tipo into g from public.gastos where id = v_id;
          avisos := avisos || format('%s: %s em %s (%s).', case when g.tipo = 'entrada' then 'Entrada anotada' else 'Anotado' end,
                                     public._brl(g.valor), g.descricao, g.categoria);
        end if;
      end if;
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

-- 7. Permissões: as auxiliares ficam fechadas; a fila continua liberada só pra chave secreta
revoke execute on function public._inserir_voz(text, text, timestamptz) from public, anon, authenticated;
revoke execute on function public._sem_acento(text) from public, anon, authenticated;
revoke execute on function public.definir_categoria() from public, anon, authenticated;
revoke execute on function public._registrar_item(jsonb) from public, anon, authenticated;
revoke execute on function public.registrar_fila(text) from public, anon, authenticated;
grant execute on function public.registrar_fila(text) to service_role;
