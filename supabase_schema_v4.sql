-- PDV COMPLETO V4
create extension if not exists pgcrypto;

create table if not exists public.products(
 id uuid primary key default gen_random_uuid(), barcode text unique, name text not null,
 cost_price numeric(12,2) not null default 0, sale_price numeric(12,2) not null default 0,
 stock numeric(12,3) not null default 0, min_stock numeric(12,3) not null default 0,
 active boolean not null default true, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now());

create table if not exists public.sales(
 id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id),
 total_cost numeric(12,2) not null default 0,total_sale numeric(12,2) not null default 0,
 total_profit numeric(12,2) not null default 0,payment_method text not null,
 cash_received numeric(12,2) not null default 0,change_amount numeric(12,2) not null default 0,
 created_at timestamptz not null default now());

create table if not exists public.sale_items(
 id uuid primary key default gen_random_uuid(),sale_id uuid not null references public.sales(id) on delete cascade,
 product_id uuid not null references public.products(id),product_name text not null,barcode text,
 quantity numeric(12,3) not null,cost_price numeric(12,2) not null,sale_price numeric(12,2) not null,
 profit numeric(12,2) not null,created_at timestamptz not null default now());

create table if not exists public.stock_movements(
 id uuid primary key default gen_random_uuid(),product_id uuid not null references public.products(id),
 type text not null check(type in('entrada','saida','ajuste')),quantity numeric(12,3) not null,
 reason text,sale_id uuid references public.sales(id),user_id uuid references auth.users(id),
 created_at timestamptz not null default now());

alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.stock_movements enable row level security;

drop policy if exists "products authenticated" on public.products;
create policy "products authenticated" on public.products for all to authenticated using(true) with check(true);
drop policy if exists "sales authenticated" on public.sales;
create policy "sales authenticated" on public.sales for all to authenticated using(true) with check(true);
drop policy if exists "sale_items authenticated" on public.sale_items;
create policy "sale_items authenticated" on public.sale_items for all to authenticated using(true) with check(true);
drop policy if exists "stock_movements authenticated" on public.stock_movements;
create policy "stock_movements authenticated" on public.stock_movements for all to authenticated using(true) with check(true);

create or replace function public.add_stock(p_product_id uuid,p_quantity numeric,p_reason text default 'Entrada de estoque')
returns void language plpgsql security definer set search_path=public as $$
begin
 if p_quantity<=0 then raise exception 'Quantidade deve ser maior que zero'; end if;
 update products set stock=stock+p_quantity,updated_at=now() where id=p_product_id;
 if not found then raise exception 'Produto não encontrado'; end if;
 insert into stock_movements(product_id,type,quantity,reason,user_id) values(p_product_id,'entrada',p_quantity,p_reason,auth.uid());
end;$$;
grant execute on function public.add_stock(uuid,numeric,text) to authenticated;

create or replace function public.finalize_sale(p_sale jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare
 v_sale_id uuid;v_user uuid:=auth.uid();v_total_cost numeric:=0;v_total_sale numeric:=0;v_total_profit numeric:=0;
 v_item jsonb;v_product products%rowtype;v_qty numeric;v_profit numeric;
begin
 if jsonb_array_length(coalesce(p_sale->'items','[]'::jsonb))=0 then raise exception 'Venda sem itens'; end if;
 insert into sales(user_id,payment_method,cash_received,change_amount)
 values(v_user,p_sale->>'payment_method',coalesce((p_sale->>'cash_received')::numeric,0),coalesce((p_sale->>'change_amount')::numeric,0))
 returning id into v_sale_id;
 for v_item in select * from jsonb_array_elements(p_sale->'items') loop
  select * into v_product from products where id=(v_item->>'product_id')::uuid and active=true for update;
  if not found then raise exception 'Produto não encontrado'; end if;
  v_qty:=(v_item->>'quantity')::numeric;
  if v_qty<=0 then raise exception 'Quantidade inválida'; end if;
  if v_product.stock<v_qty then raise exception 'Estoque insuficiente para: %',v_product.name; end if;
  v_profit:=(v_product.sale_price-v_product.cost_price)*v_qty;
  update products set stock=stock-v_qty,updated_at=now() where id=v_product.id;
  insert into sale_items(sale_id,product_id,product_name,barcode,quantity,cost_price,sale_price,profit)
  values(v_sale_id,v_product.id,v_product.name,v_product.barcode,v_qty,v_product.cost_price,v_product.sale_price,v_profit);
  insert into stock_movements(product_id,type,quantity,reason,sale_id,user_id)
  values(v_product.id,'saida',v_qty,'Venda',v_sale_id,v_user);
  v_total_cost:=v_total_cost+v_product.cost_price*v_qty;v_total_sale:=v_total_sale+v_product.sale_price*v_qty;v_total_profit:=v_total_profit+v_profit;
 end loop;
 update sales set total_cost=v_total_cost,total_sale=v_total_sale,total_profit=v_total_profit where id=v_sale_id;
 return v_sale_id;
end;$$;
grant execute on function public.finalize_sale(jsonb) to authenticated;
