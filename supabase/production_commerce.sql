-- AANDARI production commerce migration
-- Apply AFTER supabase/schema.sql in Supabase SQL Editor.
-- This migration adds customer-owned addresses, wishlist, orders, order items and quotations.
-- Prices and stock are recalculated/locked by create_customer_order(); browser totals are never trusted.

create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists email text,
  add column if not exists business_name text,
  add column if not exists gstin text,
  add column if not exists role_requested text check (role_requested in ('customer','carpenter','contractor'));

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  recipient_name text not null,
  phone text not null,
  address_line text not null,
  landmark text,
  city text not null,
  state text not null,
  pincode text not null check (pincode ~ '^[0-9]{6}$'),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.wishlist_items (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create table if not exists public.customer_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  user_id uuid not null references auth.users(id) on delete restrict,
  status text not null default 'placed' check (status in ('placed','confirmed','processing','packed','shipped','delivered','cancelled','return_requested','returned')),
  payment_method text not null check (payment_method in ('cod','upi','card','netbanking')),
  payment_status text not null default 'pending' check (payment_status in ('pending','paid','failed','refunded')),
  subtotal numeric(12,2) not null check (subtotal >= 0),
  shipping_fee numeric(12,2) not null default 0 check (shipping_fee >= 0),
  total numeric(12,2) not null check (total >= 0),
  price_tier text not null check (price_tier in ('customer','carpenter','contractor')),
  recipient_name text not null,
  recipient_phone text not null,
  address_line text not null,
  landmark text,
  city text not null,
  state text not null,
  pincode text not null,
  delivery_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.customer_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  sku text,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) not null check (line_total >= 0),
  selected_variant jsonb not null default '{}'::jsonb
);

create table if not exists public.quotation_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  request_number text not null unique,
  status text not null default 'received' check (status in ('received','reviewing','quoted','accepted','declined','closed')),
  customer_name text not null,
  phone text not null,
  business_name text,
  delivery_pincode text,
  notes text,
  items jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists customer_orders_user_created_idx on public.customer_orders(user_id, created_at desc);
create index if not exists customer_order_items_order_idx on public.customer_order_items(order_id);
create index if not exists customer_addresses_user_idx on public.customer_addresses(user_id);
create index if not exists quotation_requests_user_created_idx on public.quotation_requests(user_id, created_at desc);

alter table public.customer_addresses enable row level security;
alter table public.wishlist_items enable row level security;
alter table public.customer_orders enable row level security;
alter table public.customer_order_items enable row level security;
alter table public.quotation_requests enable row level security;

drop policy if exists "Customers manage own addresses" on public.customer_addresses;
create policy "Customers manage own addresses" on public.customer_addresses
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Customers manage own wishlist" on public.wishlist_items;
create policy "Customers manage own wishlist" on public.wishlist_items
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "Customers read own orders" on public.customer_orders;
create policy "Customers read own orders" on public.customer_orders
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "Customers read own order items" on public.customer_order_items;
create policy "Customers read own order items" on public.customer_order_items
  for select to authenticated using (
    exists (select 1 from public.customer_orders o where o.id = order_id and o.user_id = auth.uid())
  );

drop policy if exists "Customers read own quotations" on public.quotation_requests;
create policy "Customers read own quotations" on public.quotation_requests
  for select to authenticated using (auth.uid() = user_id);

grant select, insert, update, delete on public.customer_addresses to authenticated;
grant select, insert, delete on public.wishlist_items to authenticated;
grant select on public.customer_orders, public.customer_order_items, public.quotation_requests to authenticated;

-- Profile self-service is restricted to ordinary profile fields; role cannot be changed by a customer.
grant update (phone, display_name, email, business_name, gstin, role_requested) on public.profiles to authenticated;

create or replace function public.create_customer_order(
  p_items jsonb,
  p_address jsonb,
  p_payment_method text,
  p_delivery_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_role text := 'customer';
  v_subtotal numeric(12,2) := 0;
  v_shipping numeric(12,2) := 0;
  v_total numeric(12,2);
  v_order_id uuid;
  v_order_number text;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_price numeric(12,2);
  v_name text;
  v_phone text;
  v_line text;
  v_city text;
  v_state text;
  v_pin text;
  v_landmark text;
begin
  if v_user is null then raise exception 'Please sign in before placing an order'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty';
  end if;
  if p_payment_method is null or p_payment_method not in ('cod','upi','card','netbanking') then
    raise exception 'Invalid payment method';
  end if;

  select lower(role) into v_role from public.profiles where id = v_user;
  v_role := coalesce(v_role, 'customer');
  if v_role not in ('customer','carpenter','contractor') then v_role := 'customer'; end if;

  v_name := nullif(trim(p_address->>'recipient_name'),'');
  v_phone := nullif(trim(p_address->>'phone'),'');
  v_line := nullif(trim(p_address->>'address_line'),'');
  v_city := nullif(trim(p_address->>'city'),'');
  v_state := nullif(trim(p_address->>'state'),'');
  v_pin := nullif(trim(p_address->>'pincode'),'');
  v_landmark := nullif(trim(p_address->>'landmark'),'');
  if v_name is null or v_phone is null or v_line is null or v_city is null or v_state is null or v_pin is null or v_pin !~ '^[0-9]{6} 'Please provide a complete delivery address and valid 6-digit PIN';
  end if;

  for v_item in select jsonb_build_object('product_id', product_id, 'quantity', sum(quantity)) as value
    from (select (value->>'product_id')::uuid as product_id, (value->>'quantity')::integer as quantity from jsonb_array_elements(p_items)) q
    group by product_id
  loop
    if (v_item->>'product_id') is null then raise exception 'Invalid product in cart'; end if;
    v_qty := greatest(0, least(999, coalesce((v_item->>'quantity')::integer, 0)));
    if v_qty < 1 then raise exception 'Invalid product quantity'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    if not found then raise exception 'A product is unavailable'; end if;
    if v_product.stock_quantity < v_qty then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    if v_price is null or v_price <= 0 then
      raise exception 'Price is not configured for %', v_product.name;
    end if;
    v_subtotal := v_subtotal + (v_price * v_qty);
  end loop;

  v_shipping := case when v_subtotal >= 1999 then 0 else 99 end;
  v_total := v_subtotal + v_shipping;
  v_order_number := 'AAN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.customer_orders (
    order_number,user_id,payment_method,payment_status,subtotal,shipping_fee,total,price_tier,
    recipient_name,recipient_phone,address_line,landmark,city,state,pincode,delivery_note
  ) values (
    v_order_number,v_user,p_payment_method,'pending',v_subtotal,v_shipping,v_total,v_role,
    v_name,v_phone,v_line,v_landmark,v_city,v_state,v_pin,nullif(trim(p_delivery_note),'')
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    insert into public.customer_order_items (
      order_id,product_id,product_name,sku,quantity,unit_price,line_total,selected_variant
    ) values (
      v_order_id,v_product.id,v_product.name,v_product.sku,v_qty,v_price,v_price*v_qty,
      coalesce(v_item->'selected_variant','{}'::jsonb)
    );
  end loop;

  update public.products p set stock_quantity = p.stock_quantity - grouped.quantity
  from (select (value->>'product_id')::uuid as product_id, sum((value->>'quantity')::integer)::integer as quantity
        from jsonb_array_elements(p_items) group by (value->>'product_id')::uuid) grouped
  where p.id = grouped.product_id;

  return jsonb_build_object(
    'id',v_order_id,'order_number',v_order_number,'subtotal',v_subtotal,
    'shipping_fee',v_shipping,'total',v_total,'payment_status','pending'
  );
end;
$$;

revoke all on function public.create_customer_order(jsonb,jsonb,text,text) from public;
grant execute on function public.create_customer_order(jsonb,jsonb,text,text) to authenticated;

-- The customer app cannot mark an order paid, change stock, change role, or set its own order status.
-- Payment webhooks and admin status changes must be added as trusted server-side functions.
 then
    raise exception 'Please provide a complete delivery address and valid 6-digit PIN';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if (v_item->>'product_id') is null then raise exception 'Invalid product in cart'; end if;
    v_qty := greatest(0, least(999, coalesce((v_item->>'quantity')::integer, 0)));
    if v_qty < 1 then raise exception 'Invalid product quantity'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    if not found then raise exception 'A product is unavailable'; end if;
    if v_product.stock_quantity < v_qty then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    if v_price is null or v_price <= 0 then
      raise exception 'Price is not configured for %', v_product.name;
    end if;
    v_subtotal := v_subtotal + (v_price * v_qty);
  end loop;

  v_shipping := case when v_subtotal >= 1999 then 0 else 99 end;
  v_total := v_subtotal + v_shipping;
  v_order_number := 'AAN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.customer_orders (
    order_number,user_id,payment_method,payment_status,subtotal,shipping_fee,total,price_tier,
    recipient_name,recipient_phone,address_line,landmark,city,state,pincode,delivery_note
  ) values (
    v_order_number,v_user,p_payment_method,'pending',v_subtotal,v_shipping,v_total,v_role,
    v_name,v_phone,v_line,v_landmark,v_city,v_state,v_pin,nullif(trim(p_delivery_note),'')
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    insert into public.customer_order_items (
      order_id,product_id,product_name,sku,quantity,unit_price,line_total,selected_variant
    ) values (
      v_order_id,v_product.id,v_product.name,v_product.sku,v_qty,v_price,v_price*v_qty,
      coalesce(v_item->'selected_variant','{}'::jsonb)
    );
    update public.products set stock_quantity = stock_quantity - v_qty where id = v_product.id;
  end loop;

  return jsonb_build_object(
    'id',v_order_id,'order_number',v_order_number,'subtotal',v_subtotal,
    'shipping_fee',v_shipping,'total',v_total,'payment_status','pending'
  );
end;
$$;

revoke all on function public.create_customer_order(jsonb,jsonb,text,text) from public;
grant execute on function public.create_customer_order(jsonb,jsonb,text,text) to authenticated;

-- The customer app cannot mark an order paid, change stock, change role, or set its own order status.
-- Payment webhooks and admin status changes must be added as trusted server-side functions.
 then
    raise exception 'Please provide a complete delivery address and valid 6-digit PIN';
  end if;

  for v_item in select jsonb_build_object('product_id', product_id, 'quantity', sum(quantity)) as value
    from (select (value->>'product_id')::uuid as product_id, (value->>'quantity')::integer as quantity from jsonb_array_elements(p_items)) q
    group by product_id
  loop
    if (v_item->>'product_id') is null then raise exception 'Invalid product in cart'; end if;
    v_qty := greatest(0, least(999, coalesce((v_item->>'quantity')::integer, 0)));
    if v_qty < 1 then raise exception 'Invalid product quantity'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    if not found then raise exception 'A product is unavailable'; end if;
    if v_product.stock_quantity < v_qty then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    if v_price is null or v_price <= 0 then
      raise exception 'Price is not configured for %', v_product.name;
    end if;
    v_subtotal := v_subtotal + (v_price * v_qty);
  end loop;

  v_shipping := case when v_subtotal >= 1999 then 0 else 99 end;
  v_total := v_subtotal + v_shipping;
  v_order_number := 'AAN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.customer_orders (
    order_number,user_id,payment_method,payment_status,subtotal,shipping_fee,total,price_tier,
    recipient_name,recipient_phone,address_line,landmark,city,state,pincode,delivery_note
  ) values (
    v_order_number,v_user,p_payment_method,'pending',v_subtotal,v_shipping,v_total,v_role,
    v_name,v_phone,v_line,v_landmark,v_city,v_state,v_pin,nullif(trim(p_delivery_note),'')
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    insert into public.customer_order_items (
      order_id,product_id,product_name,sku,quantity,unit_price,line_total,selected_variant
    ) values (
      v_order_id,v_product.id,v_product.name,v_product.sku,v_qty,v_price,v_price*v_qty,
      coalesce(v_item->'selected_variant','{}'::jsonb)
    );
  end loop;

  update public.products p set stock_quantity = p.stock_quantity - grouped.quantity
  from (select (value->>'product_id')::uuid as product_id, sum((value->>'quantity')::integer)::integer as quantity
        from jsonb_array_elements(p_items) group by (value->>'product_id')::uuid) grouped
  where p.id = grouped.product_id;

  return jsonb_build_object(
    'id',v_order_id,'order_number',v_order_number,'subtotal',v_subtotal,
    'shipping_fee',v_shipping,'total',v_total,'payment_status','pending'
  );
end;
$$;

revoke all on function public.create_customer_order(jsonb,jsonb,text,text) from public;
grant execute on function public.create_customer_order(jsonb,jsonb,text,text) to authenticated;

-- The customer app cannot mark an order paid, change stock, change role, or set its own order status.
-- Payment webhooks and admin status changes must be added as trusted server-side functions.
 then
    raise exception 'Please provide a complete delivery address and valid 6-digit PIN';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if (v_item->>'product_id') is null then raise exception 'Invalid product in cart'; end if;
    v_qty := greatest(0, least(999, coalesce((v_item->>'quantity')::integer, 0)));
    if v_qty < 1 then raise exception 'Invalid product quantity'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    if not found then raise exception 'A product is unavailable'; end if;
    if v_product.stock_quantity < v_qty then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    if v_price is null or v_price <= 0 then
      raise exception 'Price is not configured for %', v_product.name;
    end if;
    v_subtotal := v_subtotal + (v_price * v_qty);
  end loop;

  v_shipping := case when v_subtotal >= 1999 then 0 else 99 end;
  v_total := v_subtotal + v_shipping;
  v_order_number := 'AAN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.customer_orders (
    order_number,user_id,payment_method,payment_status,subtotal,shipping_fee,total,price_tier,
    recipient_name,recipient_phone,address_line,landmark,city,state,pincode,delivery_note
  ) values (
    v_order_number,v_user,p_payment_method,'pending',v_subtotal,v_shipping,v_total,v_role,
    v_name,v_phone,v_line,v_landmark,v_city,v_state,v_pin,nullif(trim(p_delivery_note),'')
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid and is_active = true
      for update;
    v_price := case v_role
      when 'carpenter' then v_product.price_carpenter
      when 'contractor' then v_product.price_contractor
      else v_product.price_customer
    end;
    insert into public.customer_order_items (
      order_id,product_id,product_name,sku,quantity,unit_price,line_total,selected_variant
    ) values (
      v_order_id,v_product.id,v_product.name,v_product.sku,v_qty,v_price,v_price*v_qty,
      coalesce(v_item->'selected_variant','{}'::jsonb)
    );
    update public.products set stock_quantity = stock_quantity - v_qty where id = v_product.id;
  end loop;

  return jsonb_build_object(
    'id',v_order_id,'order_number',v_order_number,'subtotal',v_subtotal,
    'shipping_fee',v_shipping,'total',v_total,'payment_status','pending'
  );
end;
$$;

revoke all on function public.create_customer_order(jsonb,jsonb,text,text) from public;
grant execute on function public.create_customer_order(jsonb,jsonb,text,text) to authenticated;

-- The customer app cannot mark an order paid, change stock, change role, or set its own order status.
-- Payment webhooks and admin status changes must be added as trusted server-side functions.

-- Security/performance hardening applied after initial deployment.
create index if not exists wishlist_items_product_idx on public.wishlist_items(product_id);
create index if not exists customer_order_items_product_idx on public.customer_order_items(product_id);

drop policy if exists "Users can read own profile" on public.profiles;
create policy "Users can read own profile" on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Account self-service permissions. Keep privileged role fields server-controlled.
drop policy if exists "Users update own profile fields" on public.profiles;
create policy "Users update own profile fields"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

grant update on public.wishlist_items to authenticated;
