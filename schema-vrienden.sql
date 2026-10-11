-- Vinventory: vrienden en tips.
-- Plak dit hele bestand in Supabase > SQL Editor en klik op Run. Het is veilig om het opnieuw uit te voeren.
-- Voorwaarde: schema.sql is al uitgevoerd (de tabel `wines` bestaat).
--
-- Ontwerp (zie VRIENDEN-PLAN.md):
--  * Vrienden maak je alleen met een uitnodigingscode. Er is geen zoekfunctie en geen openbare ledenlijst.
--  * Alles wat iets verandert gaat via functies hieronder, die zelf controleren en limieten bewaken.
--    De tabellen geven ingelogde gebruikers alleen leesrechten op hun eigen rijen.
--  * Een tip is een kopie met een vaste lijst velden, door de server uit je eigen wijn gemaakt.
--    Prijs, logboek, herinneringen, winkel en "gekregen van" gaan nooit mee.
--  * Alle functies hebben `set search_path = ''`, schrijven alle namen voluit en zijn niet uitvoerbaar voor `anon`.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------- Tabellen ----------

-- Wat vrienden van je zien: alleen een naam. Geen e-mailadres.
create table if not exists public.profiles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint profiles_name check (char_length(btrim(display_name)) between 1 and 40 and display_name !~ '[[:cntrl:]]')
);

-- Eén rij per vriendenpaar, altijd met user_a < user_b, zodat er geen dubbelen zijn.
create table if not exists public.friendships (
  user_a     uuid not null references auth.users (id) on delete cascade,
  user_b     uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  constraint friendships_order check (user_a < user_b)
);
create index if not exists friendships_user_b on public.friendships (user_b);

-- Eenmalige uitnodigingen: willekeurige code van 24 hexadecimale tekens (96 bits), 7 dagen geldig.
create table if not exists public.invites (
  code       text primary key check (code ~ '^[0-9a-f]{24}$'),
  owner      uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  used_by    uuid references auth.users (id) on delete set null,
  used_at    timestamptz
);
create index if not exists invites_owner on public.invites (owner);

-- Een tip is een KOPIE van een paar velden, geen verwijzing naar de wijn van de afzender.
create table if not exists public.gifts (
  id          uuid primary key default gen_random_uuid(),
  from_user   uuid not null references auth.users (id) on delete cascade,
  to_user     uuid not null references auth.users (id) on delete cascade,
  payload     jsonb not null,
  message     text,
  status      text not null default 'sent',
  created_at  timestamptz not null default now(),
  answered_at timestamptz,
  constraint gifts_other check (from_user <> to_user),
  constraint gifts_status check (status in ('sent', 'saved', 'declined')),
  constraint gifts_size check (pg_column_size(payload) < 100000),
  constraint gifts_message check (message is null or char_length(message) <= 280)
);
create index if not exists gifts_to   on public.gifts (to_user, status, created_at desc);
create index if not exists gifts_from on public.gifts (from_user, created_at desc);

create table if not exists public.blocks (
  blocker    uuid not null references auth.users (id) on delete cascade,
  blocked    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  constraint blocks_other check (blocker <> blocked)
);
create index if not exists blocks_blocked on public.blocks (blocked);

-- Meldingen over misbruik. Gebruikers kunnen alleen melden (via submit_report), nooit lezen.
-- Jij leest ze in het Supabase-dashboard (Table Editor > reports).
create table if not exists public.reports (
  id         uuid primary key default gen_random_uuid(),
  reporter   uuid not null references auth.users (id) on delete cascade,
  reported   uuid not null references auth.users (id) on delete cascade,
  gift_id    uuid,
  reason     text not null check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);

-- Telt pogingen voor de limieten (niet bereikbaar via de API).
create table if not exists private.attempts (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind    text not null,
  at      timestamptz not null default now()
);
create index if not exists attempts_lookup on private.attempts (user_id, kind, at);

-- ---------- Rechten en regels (RLS) ----------
-- Extra slot op de bestaande tabel: anonieme bezoekers krijgen geen enkel recht op `wines`.
-- (De regels per rij hielden hen al tegen; dit haalt ook het tabelrecht weg.)
revoke all on public.wines from anon;

alter table public.profiles    enable row level security;
alter table public.friendships enable row level security;
alter table public.invites     enable row level security;
alter table public.gifts       enable row level security;
alter table public.blocks      enable row level security;
alter table public.reports     enable row level security;

revoke all on public.profiles, public.friendships, public.invites, public.gifts, public.blocks, public.reports from anon, authenticated;
grant select, insert, update on public.profiles    to authenticated;
grant select                 on public.friendships to authenticated;
grant select, delete         on public.invites     to authenticated;
grant select                 on public.gifts       to authenticated;
grant select                 on public.blocks      to authenticated;
-- reports: geen enkel recht voor gebruikers.

drop policy if exists "profiel lezen"      on public.profiles;
drop policy if exists "profiel maken"      on public.profiles;
drop policy if exists "profiel wijzigen"   on public.profiles;
drop policy if exists "vriendschap lezen"  on public.friendships;
drop policy if exists "uitnodiging lezen"  on public.invites;
drop policy if exists "uitnodiging intrekken" on public.invites;
drop policy if exists "tip lezen"          on public.gifts;
drop policy if exists "blokkade lezen"     on public.blocks;

-- Je eigen profiel. Andermans naam krijg je alleen te zien via my_friends() en my_gifts().
create policy "profiel lezen"    on public.profiles for select to authenticated using ((select auth.uid()) = user_id);
create policy "profiel maken"    on public.profiles for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "profiel wijzigen" on public.profiles for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "vriendschap lezen" on public.friendships for select to authenticated
  using ((select auth.uid()) = user_a or (select auth.uid()) = user_b);
create policy "uitnodiging lezen" on public.invites for select to authenticated using ((select auth.uid()) = owner);
create policy "uitnodiging intrekken" on public.invites for delete to authenticated
  using ((select auth.uid()) = owner and used_by is null);
create policy "tip lezen" on public.gifts for select to authenticated
  using ((select auth.uid()) = from_user or (select auth.uid()) = to_user);
create policy "blokkade lezen" on public.blocks for select to authenticated using ((select auth.uid()) = blocker);

create or replace function private.touch() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function private.touch();

-- ---------- Hulpfuncties (privé) ----------
create or replace function private.clean(t text, n int) returns text
language sql immutable set search_path = '' as $$
  select left(btrim(regexp_replace(coalesce(t, ''), '[[:cntrl:]]', ' ', 'g')), n)
$$;

-- true als de gebruiker het maximum aantal pogingen van dit soort in het tijdvak al heeft bereikt.
create or replace function private.over_limit(p_user uuid, p_kind text, p_max int, p_window interval) returns boolean
language sql stable set search_path = '' as $$
  select count(*) >= p_max from private.attempts where user_id = p_user and kind = p_kind and at > now() - p_window
$$;

create or replace function private.note(p_user uuid, p_kind text) returns void
language plpgsql set search_path = '' as $$
begin
  insert into private.attempts (user_id, kind) values (p_user, p_kind);
  delete from private.attempts where user_id = p_user and at < now() - interval '2 days';
end $$;

create or replace function private.are_friends(a uuid, b uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.friendships where user_a = least(a, b) and user_b = greatest(a, b))
$$;

create or replace function private.is_blocked(a uuid, b uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

-- ---------- Functies die de app aanroept ----------
-- Verwachte mislukkingen geven een status terug (geen fout), zodat de teller van een mislukte poging bewaard blijft.

create or replace function public.create_invite() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); n int; c text;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where user_id = uid) then return jsonb_build_object('status', 'needs_profile'); end if;
  select count(*) into n from public.invites where owner = uid and used_by is null and expires_at > now();
  if n >= 10 then return jsonb_build_object('status', 'too_many'); end if;
  c := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12) || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  insert into public.invites (code, owner) values (c, uid);
  return jsonb_build_object('status', 'ok', 'code', c);
end $$;

-- Laat de ontvanger zien van wie een uitnodiging komt, zonder haar te gebruiken.
create or replace function public.peek_invite(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); inv public.invites; nm text;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if private.over_limit(uid, 'invite', 20, interval '1 hour') then return jsonb_build_object('status', 'rate_limited'); end if;
  select * into inv from public.invites where code = p_code;
  if not found or inv.used_by is not null or inv.expires_at <= now() or inv.owner = uid or private.is_blocked(uid, inv.owner) then
    perform private.note(uid, 'invite');
    return jsonb_build_object('status', 'invalid');
  end if;
  select display_name into nm from public.profiles where user_id = inv.owner;
  if nm is null then return jsonb_build_object('status', 'invalid'); end if;
  return jsonb_build_object('status', 'ok', 'name', nm, 'already', private.are_friends(uid, inv.owner));
end $$;

create or replace function public.accept_invite(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); inv public.invites; nm text;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if private.over_limit(uid, 'invite', 20, interval '1 hour') then return jsonb_build_object('status', 'rate_limited'); end if;
  if not exists (select 1 from public.profiles where user_id = uid) then return jsonb_build_object('status', 'needs_profile'); end if;
  select * into inv from public.invites where code = p_code for update;
  if not found or inv.used_by is not null or inv.expires_at <= now() or inv.owner = uid or private.is_blocked(uid, inv.owner) then
    perform private.note(uid, 'invite');
    return jsonb_build_object('status', 'invalid');
  end if;
  insert into public.friendships (user_a, user_b) values (least(uid, inv.owner), greatest(uid, inv.owner)) on conflict do nothing;
  update public.invites set used_by = uid, used_at = now() where code = inv.code;
  select display_name into nm from public.profiles where user_id = inv.owner;
  return jsonb_build_object('status', 'ok', 'friend_id', inv.owner, 'name', nm);
end $$;

create or replace function public.my_friends() returns table (friend_id uuid, display_name text, since timestamptz)
language sql security definer stable set search_path = '' as $$
  select o.id, p.display_name, f.created_at
  from public.friendships f
  cross join lateral (select case when f.user_a = (select auth.uid()) then f.user_b else f.user_a end as id) o
  join public.profiles p on p.user_id = o.id
  where (select auth.uid()) is not null and (select auth.uid()) in (f.user_a, f.user_b)
  order by lower(p.display_name), f.created_at
$$;

create or replace function public.my_blocks() returns table (blocked_id uuid, display_name text, since timestamptz)
language sql security definer stable set search_path = '' as $$
  select b.blocked, coalesce(p.display_name, '?'), b.created_at
  from public.blocks b left join public.profiles p on p.user_id = b.blocked
  where b.blocker = (select auth.uid())
  order by b.created_at desc
$$;

create or replace function public.send_gift(p_to uuid, p_wine_id text, p_message text, p_rating boolean, p_photo boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); w jsonb; payload jsonb; msg text; thumb text; rt int;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  -- Dezelfde melding voor "geen vrienden" en "geblokkeerd": de afzender hoeft niet te weten welke van de twee.
  if p_to is null or p_to = uid or not private.are_friends(uid, p_to) or private.is_blocked(uid, p_to) then
    return jsonb_build_object('status', 'not_friends');
  end if;
  if private.over_limit(uid, 'gift', 20, interval '24 hours') then return jsonb_build_object('status', 'rate_limited'); end if;
  if (select count(*) from public.gifts where from_user = uid and to_user = p_to and status = 'sent') >= 5 then
    return jsonb_build_object('status', 'too_many_pending');
  end if;
  select data into w from public.wines where user_id = uid and id = p_wine_id;
  if w is null then return jsonb_build_object('status', 'no_wine'); end if;

  thumb := w->>'thumb';
  if not (coalesce(p_photo, false) and thumb is not null and left(thumb, 23) = 'data:image/jpeg;base64,'
          and char_length(thumb) <= 90000 and substr(thumb, 24) ~ '^[A-Za-z0-9+/]*={0,2}$') then
    thumb := null;
  end if;
  rt := case when coalesce(p_rating, false) and (w->>'rating') ~ '^([1-9]|10)$' then (w->>'rating')::int end;
  -- Vaste lijst velden. Alles wat hier niet staat, gaat niet mee.
  payload := jsonb_strip_nulls(jsonb_build_object(
    'name',        private.clean(w->>'name', 200),
    'producer',    private.clean(w->>'producer', 200),
    'vintage',     case when (w->>'vintage') ~ '^[0-9]{4}$' then (w->>'vintage')::int end,
    'region',      private.clean(w->>'region', 200),
    'country',     private.clean(w->>'country', 100),
    'grape',       private.clean(w->>'grape', 200),
    'color',       case when w->>'color' in ('rood', 'wit', 'rosé', 'mousserend', 'dessert', 'versterkt') then w->>'color' else 'rood' end,
    'description', private.clean(w->>'description', 2000),
    'pairing',     private.clean(w->>'pairing', 500),
    'friendRating', rt,
    'thumb',       thumb));
  msg := nullif(private.clean(p_message, 280), '');
  perform private.note(uid, 'gift');
  insert into public.gifts (from_user, to_user, payload, message) values (uid, p_to, payload, msg);
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.my_gifts() returns table (id uuid, from_id uuid, from_name text, payload jsonb, message text, created_at timestamptz)
language sql security definer stable set search_path = '' as $$
  select g.id, g.from_user, coalesce(p.display_name, '?'), g.payload, g.message, g.created_at
  from public.gifts g left join public.profiles p on p.user_id = g.from_user
  where g.to_user = (select auth.uid()) and g.status = 'sent'
  order by g.created_at desc limit 100
$$;

create or replace function public.answer_gift(p_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); g public.gifts; nm text;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if p_action not in ('saved', 'declined') then return jsonb_build_object('status', 'invalid'); end if;
  select * into g from public.gifts where id = p_id and to_user = uid and status = 'sent' for update;
  if not found then return jsonb_build_object('status', 'invalid'); end if;
  if p_action = 'saved' then
    select display_name into nm from public.profiles where user_id = g.from_user;
    -- De tip komt als wishlist-wijn in je eigen kelderlijst (eigen kopie, met een vaste id per tip).
    insert into public.wines (user_id, id, data)
    values (uid, 'g' || replace(g.id::text, '-', ''),
            (g.payload - 'friendRating') || jsonb_build_object(
              'wish', true, 'quantity', 0, 'createdAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
              'fromFriend', coalesce(nm, '?'), 'friendRating', g.payload->'friendRating'))
    on conflict (user_id, id) do nothing;
  end if;
  update public.gifts set status = p_action, answered_at = now() where id = g.id;
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.remove_friend(p_friend uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  delete from public.friendships where user_a = least(uid, p_friend) and user_b = greatest(uid, p_friend);
  delete from public.gifts where status = 'sent' and ((from_user = uid and to_user = p_friend) or (from_user = p_friend and to_user = uid));
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.block_user(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if p_user is null or p_user = uid or not exists (select 1 from auth.users where id = p_user) then return jsonb_build_object('status', 'invalid'); end if;
  insert into public.blocks (blocker, blocked) values (uid, p_user) on conflict do nothing;
  delete from public.friendships where user_a = least(uid, p_user) and user_b = greatest(uid, p_user);
  delete from public.gifts where status = 'sent' and ((from_user = uid and to_user = p_user) or (from_user = p_user and to_user = uid));
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.unblock_user(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  delete from public.blocks where blocker = uid and blocked = p_user;
  return jsonb_build_object('status', 'ok');
end $$;

-- Melden kan alleen over iemand met wie je een band hebt: een vriend, een afzender van een tip of iemand die je blokkeerde.
create or replace function public.submit_report(p_reported uuid, p_gift uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if private.over_limit(uid, 'report', 10, interval '24 hours') then return jsonb_build_object('status', 'rate_limited'); end if;
  if p_reported is null or p_reported = uid or not (
       private.are_friends(uid, p_reported)
    or exists (select 1 from public.gifts where from_user = p_reported and to_user = uid)
    or exists (select 1 from public.blocks where blocker = uid and blocked = p_reported)) then
    return jsonb_build_object('status', 'invalid');
  end if;
  perform private.note(uid, 'report');
  insert into public.reports (reporter, reported, gift_id, reason) values (uid, p_reported, p_gift, private.clean(p_reason, 500));
  return jsonb_build_object('status', 'ok');
end $$;

-- Alleen ingelogde gebruikers mogen de functies aanroepen, nooit anonieme bezoekers.
revoke all on function public.create_invite(), public.peek_invite(text), public.accept_invite(text), public.my_friends(), public.my_blocks(),
  public.send_gift(uuid, text, text, boolean, boolean), public.my_gifts(), public.answer_gift(uuid, text), public.remove_friend(uuid),
  public.block_user(uuid), public.unblock_user(uuid), public.submit_report(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.create_invite(), public.peek_invite(text), public.accept_invite(text), public.my_friends(), public.my_blocks(),
  public.send_gift(uuid, text, text, boolean, boolean), public.my_gifts(), public.answer_gift(uuid, text), public.remove_friend(uuid),
  public.block_user(uuid), public.unblock_user(uuid), public.submit_report(uuid, uuid, text) to authenticated;

-- Live bijwerken: een nieuwe tip of vriend verschijnt meteen op de apparaten van de ontvanger.
do $$ begin alter publication supabase_realtime add table public.gifts;       exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.friendships; exception when duplicate_object then null; end $$;
