-- AANDARI initial Supabase schema
-- Run this file in Supabase Dashboard > SQL Editor > New query.
-- Customer role is assigned by the database trigger; clients cannot update roles.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text,
  display_name text,
  role text not null default 'customer' check (role in ('customer','carpenter','contractor','admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null,
  description text,
  image_url text,
  sku text unique,
  price_customer numeric(12,2) not null default 0,
  price_carpenter numeric(12,2) not null default 0,
  price_contractor numeric(12,2) not null default 0,
  stock_quantity integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.products enable row level security;

drop policy if exists "Users can read own profile" on public.profiles;
create policy "Users can read own profile"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

drop policy if exists "Anyone can read active products" on public.products;
create policy "Anyone can read active products"
  on public.products for select
  to anon, authenticated
  using (is_active = true);

-- Do not add client insert/update/delete policies for product prices or profile roles.
-- Admin writes must later be implemented through a trusted server-side function.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, phone)
  values (new.id, new.phone)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

grant select on public.profiles to authenticated;
grant select on public.products to anon, authenticated;
