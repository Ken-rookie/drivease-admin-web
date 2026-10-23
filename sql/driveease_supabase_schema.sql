-- ============================================================
-- DriveEase Car Rental App — Supabase starter schema
-- Paste this entire script into Supabase SQL Editor and Run.
-- Currency defaults to PHP (₱), matching the supplied UI mockup.
--
-- Includes: profiles, vehicle catalog, locations, add-ons, bookings,
-- booking add-ons, payments, agreements, reviews, policies, RLS,
-- booking overlap protection, timestamps, and storage bucket setup.
--
-- Notes:
-- 1) Supabase Auth handles passwords, email verification and recovery.
--    Never store plaintext passwords in public tables.
-- 2) Payment records here track payment state; connect a real payment
--    provider before accepting real money.
-- 3) This script creates schema/policies, not production vehicle data.
-- ============================================================

begin;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------- ENUMS ----------
do $$ begin
  create type public.user_role as enum ('customer', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.vehicle_status as enum ('available', 'maintenance', 'inactive');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.booking_status as enum (
    'pending', 'confirmed', 'ongoing', 'completed', 'cancelled', 'rejected'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_status as enum (
    'pending', 'processing', 'paid', 'failed', 'refunded', 'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_method as enum (
    'gcash', 'card', 'paypal', 'cash_on_pickup', 'bank_transfer'
  );
exception when duplicate_object then null; end $$;

-- ---------- COMMON UPDATED_AT TRIGGER ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- USER PROFILES ----------
-- The auth.users row is the actual login account.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  avatar_url text,
  role public.user_role not null default 'customer',
  preferred_language text not null default 'English',
  dark_mode boolean not null default false,
  notifications_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      ''
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- ---------- VEHICLE CATEGORIES ----------
create table if not exists public.vehicle_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  description text,
  created_at timestamptz not null default now()
);

-- ---------- VEHICLES ----------
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand text not null,
  model text not null,
  year integer check (year between 1950 and 2100),
  category_id uuid references public.vehicle_categories(id) on delete set null,
  transmission text not null default 'Automatic'
    check (transmission in ('Automatic', 'Manual')),
  seats integer not null default 5 check (seats between 1 and 60),
  fuel_type text not null default 'Gasoline',
  luggage_capacity integer check (luggage_capacity is null or luggage_capacity >= 0),
  plate_number text unique,
  description text,
  image_url text,
  image_urls text[] not null default '{}',
  price_per_day numeric(12,2) not null check (price_per_day >= 0),
  security_deposit numeric(12,2) not null default 0 check (security_deposit >= 0),
  status public.vehicle_status not null default 'available',
  is_featured boolean not null default false,
  rating numeric(2,1) not null default 0 check (rating between 0 and 5),
  review_count integer not null default 0 check (review_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists vehicles_status_idx on public.vehicles(status);
create index if not exists vehicles_category_idx on public.vehicles(category_id);
create index if not exists vehicles_price_idx on public.vehicles(price_per_day);

-- ---------- PICKUP / RETURN LOCATIONS ----------
create table if not exists public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  city text not null,
  region text,
  country text not null default 'Philippines',
  location_type text not null default 'city'
    check (location_type in ('airport', 'city', 'branch', 'hotel', 'other')),
  instructions text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists locations_active_idx on public.locations(is_active);

-- ---------- OPTIONAL EXTRAS ----------
create table if not exists public.add_ons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  price_per_day numeric(12,2) not null default 0 check (price_per_day >= 0),
  price_per_booking numeric(12,2) not null default 0 check (price_per_booking >= 0),
  image_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (price_per_day = 0 or price_per_booking = 0)
);

-- ---------- BOOKINGS ----------
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_code text not null unique
    default ('DE-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  user_id uuid not null references public.profiles(id) on delete restrict,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  pickup_location_id uuid not null references public.locations(id) on delete restrict,
  return_location_id uuid not null references public.locations(id) on delete restrict,
  pickup_at timestamptz not null,
  return_at timestamptz not null,
  status public.booking_status not null default 'pending',
  rental_days integer generated always as
    (greatest(1, ceil(extract(epoch from (return_at - pickup_at)) / 86400.0)::integer)) stored,
  daily_rate numeric(12,2) not null check (daily_rate >= 0),
  add_ons_total numeric(12,2) not null default 0 check (add_ons_total >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  security_deposit numeric(12,2) not null default 0 check (security_deposit >= 0),
  total_amount numeric(12,2) not null check (total_amount >= 0),
  currency text not null default 'PHP' check (currency ~ '^[A-Z]{3}$'),
  customer_notes text,
  cancellation_reason text,
  cancelled_at timestamptz,
  confirmed_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (return_at > pickup_at),
  check (discount_amount <= (daily_rate * greatest(1, ceil(extract(epoch from (return_at - pickup_at)) / 86400.0)::integer) + add_ons_total))
);

create index if not exists bookings_user_idx on public.bookings(user_id, created_at desc);
create index if not exists bookings_vehicle_dates_idx on public.bookings(vehicle_id, pickup_at, return_at);
create index if not exists bookings_status_idx on public.bookings(status);

-- Prevent overlapping active reservations for the same vehicle.
-- Pending, confirmed and ongoing bookings block the vehicle.
-- A cancelled/completed/rejected booking does not block it.
do $$ begin
  alter table public.bookings
    add constraint bookings_no_overlapping_vehicle_times
    exclude using gist (
      vehicle_id with =,
      tstzrange(pickup_at, return_at, '[)') with &&
    )
    where (status in ('pending', 'confirmed', 'ongoing'));
exception
  when duplicate_object then null;
  when duplicate_table then null;
end $$;

-- ---------- SELECTED ADD-ONS FOR A BOOKING ----------
create table if not exists public.booking_add_ons (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  add_on_id uuid not null references public.add_ons(id) on delete restrict,
  quantity integer not null default 1 check (quantity between 1 and 20),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  pricing_type text not null check (pricing_type in ('per_day', 'per_booking')),
  created_at timestamptz not null default now(),
  unique (booking_id, add_on_id)
);

-- ---------- PAYMENTS ----------
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  method public.payment_method not null,
  status public.payment_status not null default 'pending',
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null default 'PHP' check (currency ~ '^[A-Z]{3}$'),
  provider text,
  provider_transaction_id text,
  receipt_url text,
  failure_reason text,
  paid_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payments_booking_idx on public.payments(booking_id);
create index if not exists payments_user_idx on public.payments(user_id, created_at desc);

-- ---------- RENTAL AGREEMENTS ----------
create table if not exists public.rental_agreements (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  version text not null default '1.0',
  agreement_text text,
  document_url text,
  accepted boolean not null default false,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (
    (accepted = false and accepted_at is null)
    or (accepted = true and accepted_at is not null)
  )
);

-- ---------- VEHICLE REVIEWS ----------
create table if not exists public.vehicle_reviews (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete set null,
  rating integer not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  unique (user_id, booking_id)
);

-- ---------- RENTAL POLICIES ----------
create table if not exists public.rental_policies (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  body text not null default '',
  sort_order integer not null default 0,
  is_published boolean not null default true,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- APP SETTINGS ----------
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  description text,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- ---------- UPDATED_AT TRIGGERS ----------
do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'vehicles', 'locations', 'add_ons', 'bookings',
    'payments', 'rental_policies'
  ]
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format(
      'create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      t
    );
  end loop;
end $$;

-- ---------- SECURITY HELPER ----------
-- Admin status is read from the protected profile row.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Users can edit their own basic profile fields, but not their role.
create or replace function public.protect_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'Only an admin can change a profile role';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_role_trigger on public.profiles;
create trigger protect_profile_role_trigger
before update on public.profiles
for each row execute function public.protect_profile_role();

-- ---------- ROW LEVEL SECURITY ----------
alter table public.profiles enable row level security;
alter table public.vehicle_categories enable row level security;
alter table public.vehicles enable row level security;
alter table public.locations enable row level security;
alter table public.add_ons enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_add_ons enable row level security;
alter table public.payments enable row level security;
alter table public.rental_agreements enable row level security;
alter table public.vehicle_reviews enable row level security;
alter table public.rental_policies enable row level security;
alter table public.app_settings enable row level security;

-- Profiles
drop policy if exists "Profiles: read own or admin" on public.profiles;
create policy "Profiles: read own or admin"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.is_admin());

drop policy if exists "Profiles: update own or admin" on public.profiles;
create policy "Profiles: update own or admin"
on public.profiles for update to authenticated
using (id = (select auth.uid()) or public.is_admin())
with check (id = (select auth.uid()) or public.is_admin());

-- Public catalog reads; only admins can mutate catalog data
drop policy if exists "Categories: public read" on public.vehicle_categories;
create policy "Categories: public read"
on public.vehicle_categories for select to anon, authenticated using (true);
drop policy if exists "Categories: admin manage" on public.vehicle_categories;
create policy "Categories: admin manage"
on public.vehicle_categories for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Vehicles: public read active" on public.vehicles;
create policy "Vehicles: public read active"
on public.vehicles for select to anon, authenticated
using (status = 'available' or public.is_admin());
drop policy if exists "Vehicles: admin manage" on public.vehicles;
create policy "Vehicles: admin manage"
on public.vehicles for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Locations: public read active" on public.locations;
create policy "Locations: public read active"
on public.locations for select to anon, authenticated
using (is_active or public.is_admin());
drop policy if exists "Locations: admin manage" on public.locations;
create policy "Locations: admin manage"
on public.locations for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Add-ons: public read active" on public.add_ons;
create policy "Add-ons: public read active"
on public.add_ons for select to anon, authenticated
using (is_active or public.is_admin());
drop policy if exists "Add-ons: admin manage" on public.add_ons;
create policy "Add-ons: admin manage"
on public.add_ons for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- A customer can create/read their own bookings. Admins can manage all.
drop policy if exists "Bookings: read own or admin" on public.bookings;
create policy "Bookings: read own or admin"
on public.bookings for select to authenticated
using (user_id = (select auth.uid()) or public.is_admin());

drop policy if exists "Bookings: customer create own" on public.bookings;
create policy "Bookings: customer create own"
on public.bookings for insert to authenticated
with check (user_id = (select auth.uid()) and status = 'pending');

drop policy if exists "Bookings: customer cancel own pending" on public.bookings;
create policy "Bookings: customer cancel own pending"
on public.bookings for update to authenticated
using (user_id = (select auth.uid()) and status = 'pending')
with check (user_id = (select auth.uid()) and status in ('pending', 'cancelled'));

drop policy if exists "Bookings: admin manage" on public.bookings;
create policy "Bookings: admin manage"
on public.bookings for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Booking add-ons are visible only to booking owner/admin.
drop policy if exists "Booking add-ons: read own or admin" on public.booking_add_ons;
create policy "Booking add-ons: read own or admin"
on public.booking_add_ons for select to authenticated
using (
  exists (
    select 1 from public.bookings b
    where b.id = booking_id
      and (b.user_id = (select auth.uid()) or public.is_admin())
  )
);
drop policy if exists "Booking add-ons: add to own pending booking" on public.booking_add_ons;
create policy "Booking add-ons: add to own pending booking"
on public.booking_add_ons for insert to authenticated
with check (
  exists (
    select 1 from public.bookings b
    where b.id = booking_id
      and b.user_id = (select auth.uid())
      and b.status = 'pending'
  )
);
drop policy if exists "Booking add-ons: admin manage" on public.booking_add_ons;
create policy "Booking add-ons: admin manage"
on public.booking_add_ons for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Payments: customers can read/create their own payment intent rows;
-- only admins can update payment status. Real payment status must be
-- confirmed by a trusted server/webhook, not directly by a client.
drop policy if exists "Payments: read own or admin" on public.payments;
create policy "Payments: read own or admin"
on public.payments for select to authenticated
using (user_id = (select auth.uid()) or public.is_admin());
drop policy if exists "Payments: create own pending" on public.payments;
create policy "Payments: create own pending"
on public.payments for insert to authenticated
with check (
  user_id = (select auth.uid())
  and status = 'pending'
  and exists (
    select 1 from public.bookings b
    where b.id = booking_id and b.user_id = (select auth.uid())
  )
);
drop policy if exists "Payments: admin manage" on public.payments;
create policy "Payments: admin manage"
on public.payments for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Rental agreements
drop policy if exists "Agreements: read own or admin" on public.rental_agreements;
create policy "Agreements: read own or admin"
on public.rental_agreements for select to authenticated
using (user_id = (select auth.uid()) or public.is_admin());
drop policy if exists "Agreements: create own" on public.rental_agreements;
create policy "Agreements: create own"
on public.rental_agreements for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.bookings b
    where b.id = booking_id and b.user_id = (select auth.uid())
  )
);
drop policy if exists "Agreements: admin manage" on public.rental_agreements;
create policy "Agreements: admin manage"
on public.rental_agreements for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Reviews: public can read; signed-in users can write as themselves.
drop policy if exists "Reviews: public read" on public.vehicle_reviews;
create policy "Reviews: public read"
on public.vehicle_reviews for select to anon, authenticated using (true);
drop policy if exists "Reviews: create own" on public.vehicle_reviews;
create policy "Reviews: create own"
on public.vehicle_reviews for insert to authenticated
with check (
  user_id = (select auth.uid())
  and (
    booking_id is null
    or exists (
      select 1 from public.bookings b
      where b.id = booking_id and b.user_id = (select auth.uid())
        and b.vehicle_id = vehicle_id
        and b.status = 'completed'
    )
  )
);
drop policy if exists "Reviews: owner or admin delete" on public.vehicle_reviews;
create policy "Reviews: owner or admin delete"
on public.vehicle_reviews for delete to authenticated
using (user_id = (select auth.uid()) or public.is_admin());

-- Policies and settings
drop policy if exists "Policies: public read published" on public.rental_policies;
create policy "Policies: public read published"
on public.rental_policies for select to anon, authenticated
using (is_published or public.is_admin());
drop policy if exists "Policies: admin manage" on public.rental_policies;
create policy "Policies: admin manage"
on public.rental_policies for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Settings: public read" on public.app_settings;
create policy "Settings: public read"
on public.app_settings for select to anon, authenticated using (true);
drop policy if exists "Settings: admin manage" on public.app_settings;
create policy "Settings: admin manage"
on public.app_settings for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- ---------- TABLE PRIVILEGES ----------
grant usage on schema public to anon, authenticated;
grant select on public.vehicle_categories, public.vehicles, public.locations,
  public.add_ons, public.rental_policies, public.app_settings,
  public.vehicle_reviews to anon, authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.vehicle_categories, public.vehicles,
  public.locations, public.add_ons, public.rental_policies, public.app_settings
  to authenticated;

grant select, insert, update on public.bookings to authenticated;
grant select, insert, update, delete on public.booking_add_ons to authenticated;
grant select, insert on public.payments to authenticated;
grant select, insert, update on public.rental_agreements to authenticated;
grant select, insert, delete on public.vehicle_reviews to authenticated;

-- ---------- STORAGE BUCKET FOR VEHICLE IMAGES ----------
-- Public read for catalog photos; uploads/changes should be admin-only.
insert into storage.buckets (id, name, public)
values ('vehicle-images', 'vehicle-images', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "Vehicle images: public read" on storage.objects;
create policy "Vehicle images: public read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'vehicle-images');

drop policy if exists "Vehicle images: admin upload" on storage.objects;
create policy "Vehicle images: admin upload"
on storage.objects for insert to authenticated
with check (bucket_id = 'vehicle-images' and public.is_admin());

drop policy if exists "Vehicle images: admin update" on storage.objects;
create policy "Vehicle images: admin update"
on storage.objects for update to authenticated
using (bucket_id = 'vehicle-images' and public.is_admin())
with check (bucket_id = 'vehicle-images' and public.is_admin());

drop policy if exists "Vehicle images: admin delete" on storage.objects;
create policy "Vehicle images: admin delete"
on storage.objects for delete to authenticated
using (bucket_id = 'vehicle-images' and public.is_admin());

-- ---------- STARTER CATALOG VALUES ----------
insert into public.vehicle_categories (name, slug, description) values
  ('Economy', 'economy', 'Affordable and fuel-efficient vehicles'),
  ('SUV', 'suv', 'Roomy vehicles for families and groups'),
  ('Luxury', 'luxury', 'Premium vehicles for special trips'),
  ('Van', 'van', 'Extra space for passengers and luggage')
on conflict (slug) do nothing;

insert into public.add_ons (name, description, price_per_day, price_per_booking)
values
  ('GPS Navigation', 'Portable or built-in GPS navigation', 200, 0),
  ('Child Seat', 'Child safety seat', 150, 0),
  ('Additional Driver', 'Register an additional authorized driver', 300, 0),
  ('Full Insurance', 'Optional additional insurance coverage', 250, 0)
on conflict (name) do nothing;

insert into public.rental_policies (slug, title, body, sort_order) values
  ('rental-requirements', 'Rental Requirements', 'Add your driver license, age, and identification requirements here.', 1),
  ('insurance-coverage', 'Insurance Coverage', 'Describe included insurance and optional coverage here.', 2),
  ('cancellation-policy', 'Cancellation Policy', 'Describe cancellation windows, fees, and refund rules here.', 3),
  ('fuel-policy', 'Fuel Policy', 'Describe the fuel level and refueling policy here.', 4),
  ('late-return-policy', 'Late Return Policy', 'Describe grace periods and late return charges here.', 5),
  ('damage-and-loss', 'Damage & Loss', 'Describe damage reporting, liability, and loss procedures here.', 6)
on conflict (slug) do nothing;

insert into public.app_settings (key, value, description) values
  ('default_currency', '"PHP"'::jsonb, 'Three-letter currency code used by the app'),
  ('support_email', '""'::jsonb, 'Customer support email address'),
  ('support_phone', '""'::jsonb, 'Customer support phone number'),
  ('booking_cancellation_enabled', 'true'::jsonb, 'Whether customers can cancel pending bookings')
on conflict (key) do nothing;

commit;

-- ============================================================
-- AFTER RUNNING THIS SCRIPT
-- ============================================================
-- 1) In Supabase Dashboard > Authentication > Providers, configure
--    Email and decide whether email confirmation is required.
-- 2) Register your own account through the app or Authentication > Users.
-- 3) Promote your account to admin using SQL Editor, replacing the email:
--
-- update public.profiles
-- set role = 'admin'
-- where id = (
--   select id from auth.users where email = 'YOUR_EMAIL@example.com'
-- );
--
-- 4) Add vehicles and locations in Table Editor or your admin panel.
-- 5) Set your frontend to use Supabase URL + anon/publishable key only.
--    NEVER put the service_role key in a mobile app or browser frontend.
-- 6) Booking prices should be calculated/validated on a trusted server or
--    database function; do not trust totals sent by the client.
-- 7) The overlap constraint intentionally treats pending bookings as
--    blocking inventory. If you later add expiring holds, implement an
--    atomic booking RPC that releases expired holds safely.
