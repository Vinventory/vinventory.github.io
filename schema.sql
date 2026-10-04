-- Vinventory: één tabel met de wijnen van alle gebruikers.
-- Plak dit hele bestand in Supabase > SQL Editor en klik op Run.
--
-- Elke wijn is één rij. De wijn zelf (naam, foto's, logboek, herinneringen, ...) staat als JSON in `data`,
-- precies zoals de app hem nu al gebruikt. De beveiliging (Row Level Security) zorgt ervoor dat
-- iedereen alleen zijn eigen rijen kan zien en wijzigen. Dat dwingt de database zelf af, niet de app.

create table if not exists public.wines (
  user_id    uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  id         text        not null,
  data       jsonb       not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, id),
  -- Eén wijn mag met foto's niet groter zijn dan ongeveer 0,9 MB.
  constraint wines_size check (pg_column_size(data) < 900000)
);

alter table public.wines enable row level security;

drop policy if exists "wijnen lezen"      on public.wines;
drop policy if exists "wijnen toevoegen"  on public.wines;
drop policy if exists "wijnen wijzigen"   on public.wines;
drop policy if exists "wijnen verwijderen" on public.wines;

create policy "wijnen lezen"       on public.wines for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "wijnen toevoegen"   on public.wines for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "wijnen wijzigen"    on public.wines for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "wijnen verwijderen" on public.wines for delete to authenticated
  using ((select auth.uid()) = user_id);

-- Houd `updated_at` automatisch bij.
create or replace function public.wines_touch() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists wines_touch on public.wines;
create trigger wines_touch before update on public.wines
  for each row execute function public.wines_touch();

-- Live bijwerken op andere apparaten van dezelfde gebruiker.
do $$ begin
  alter publication supabase_realtime add table public.wines;
exception when duplicate_object then null; end $$;
