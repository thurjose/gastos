-- =====================================================================
-- Controle de gastos — migração v3
-- Lançamentos mensais (repetir até uma data) e categorias configuráveis.
-- =====================================================================

-- Liga os lançamentos de uma mesma repetição mensal
alter table public.gastos add column if not exists recorrencia_grupo uuid;

-- Categoria automática: a categoria vinda da Carteira só vale se existir na sua lista
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
       where new.descricao ilike '%' || r.padrao || '%' order by length(r.padrao) desc limit 1;
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
          new.categoria := null;   -- você removeu/renomeou essa categoria: cai em Outros
        end if;
      end if;
      new.categoria := coalesce(new.categoria, 'Outros');
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.definir_categoria() from public, anon, authenticated;
