-- Ejecuta este archivo UNA VEZ en Supabase > SQL Editor.
-- IMPORTANTE: usa un proyecto nuevo; este script crea tablas y políticas.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null,
 full_name text not null default '',
 role text not null default 'user' check(role in ('user','admin')),
 status text not null default 'pending' check(status in ('pending','approved','rejected','suspended')),
 privacy_consent_at timestamptz not null,
 created_at timestamptz not null default now()
);
create table if not exists public.transactions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 type text not null check(type in ('income','expense')),
 amount numeric(14,2) not null check(amount > 0 and amount <= 999999999),
 category text not null check(char_length(category) between 1 and 80),
 description text not null default '' check(char_length(description)<=200),
 date date not null,
 created_at timestamptz not null default now()
);
create index if not exists transactions_user_date_idx on public.transactions(user_id,date desc);
create table if not exists public.savings_goals (
 user_id uuid not null references public.profiles(id) on delete cascade,
 month text not null check(month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
 target_amount numeric(14,2) not null check(target_amount >= 0),
 primary key(user_id,month)
);
-- El alta automática se hace solo con consentimiento explícito.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.raw_user_meta_data->>'privacy_consent' is distinct from 'true' then
   raise exception 'Debes aceptar el aviso de privacidad para registrarte';
 end if;
 insert into public.profiles(id,email,full_name,privacy_consent_at)
 values(new.id,coalesce(new.email,''),left(coalesce(new.raw_user_meta_data->>'full_name',''),80),now());
 return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
-- Funciones con security definer para evitar recursión de RLS.
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and role='admin' and status='approved');
$$;
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and status='approved');
$$;
revoke all on function public.is_admin() from public;
revoke all on function public.is_approved() from public;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_approved() to authenticated;
-- Impedir que se desactive la última cuenta administradora o se modifique a sí misma desde el panel.
create or replace function public.guard_profile_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if old.id = (select auth.uid()) and (new.role is distinct from old.role or new.status is distinct from old.status) then
   raise exception 'No puedes modificar tu propio rol o estado desde la aplicación';
 end if;
 if old.privacy_consent_at is distinct from new.privacy_consent_at then
   raise exception 'El consentimiento original no se puede alterar';
 end if;
 return new;
end;$$;
drop trigger if exists guard_profile_update on public.profiles;
create trigger guard_profile_update before update on public.profiles for each row execute function public.guard_profile_update();
alter table public.profiles enable row level security;
alter table public.transactions enable row level security;
alter table public.savings_goals enable row level security;
revoke all on public.profiles, public.transactions, public.savings_goals from anon;
grant select on public.profiles to authenticated;
grant update(status) on public.profiles to authenticated;
grant select,insert,delete on public.transactions to authenticated;
grant select,insert,update,delete on public.savings_goals to authenticated;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (id=(select auth.uid()) or public.is_admin());
drop policy if exists profiles_admin_status on public.profiles;
create policy profiles_admin_status on public.profiles for update to authenticated using(public.is_admin() and id<>(select auth.uid())) with check(public.is_admin() and id<>(select auth.uid()));
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select to authenticated using(public.is_admin() or (user_id=(select auth.uid()) and public.is_approved()));
drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions for insert to authenticated with check(user_id=(select auth.uid()) and public.is_approved());
drop policy if exists transactions_delete on public.transactions;
create policy transactions_delete on public.transactions for delete to authenticated using(user_id=(select auth.uid()) and public.is_approved());
drop policy if exists goals_select on public.savings_goals;
create policy goals_select on public.savings_goals for select to authenticated using(public.is_admin() or (user_id=(select auth.uid()) and public.is_approved()));
drop policy if exists goals_insert on public.savings_goals;
create policy goals_insert on public.savings_goals for insert to authenticated with check(user_id=(select auth.uid()) and public.is_approved());
drop policy if exists goals_update on public.savings_goals;
create policy goals_update on public.savings_goals for update to authenticated using(user_id=(select auth.uid()) and public.is_approved()) with check(user_id=(select auth.uid()) and public.is_approved());
drop policy if exists goals_delete on public.savings_goals;
create policy goals_delete on public.savings_goals for delete to authenticated using(user_id=(select auth.uid()) and public.is_approved());
-- DESPUÉS de crear TU cuenta desde la aplicación, ejecuta MANUALMENTE
-- esta sentencia en SQL Editor, reemplazando el correo:
-- update public.profiles set role='admin', status='approved' where email='TU_CORREO@EJEMPLO.COM';
-- Hazlo ANTES de invitar a otros usuarios. Nunca permitas que usuarios se asignen admin.
