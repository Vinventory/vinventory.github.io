-- Vinventory: verrassingen (effecten) naar vrienden sturen.
-- Plak dit hele bestand in Supabase > SQL Editor en klik op Run. Het is veilig om het opnieuw uit te voeren.
-- Voorwaarde: schema.sql en schema-vrienden.sql zijn al uitgevoerd.
--
-- Ontwerp (zie EFFECTEN-PLAN.md):
--  * Er gaat alleen de NAAM van een effect mee (uit een vaste lijst), plus een kort bericht. Nooit HTML of code:
--    de animatie zelf zit in de app.
--  * Alleen naar vrienden, niet bij een blokkade. Limieten: 10 per dag, hooguit 3 ongeziene per vriend.
--  * Schrijven gaat alleen via de functies hieronder; gebruikers kunnen hun eigen rijen alleen lezen.
--  * Een nieuw effect toevoegen: zet de naam in private.effect_names() en voer dit bestand opnieuw uit.

create table if not exists public.effects (
  id         uuid primary key default gen_random_uuid(),
  from_user  uuid not null references auth.users (id) on delete cascade,
  to_user    uuid not null references auth.users (id) on delete cascade,
  effect     text not null,
  message    text,
  created_at timestamptz not null default now(),
  seen_at    timestamptz,
  constraint effects_other   check (from_user <> to_user),
  constraint effects_name    check (effect ~ '^[a-z]{1,20}$'),
  constraint effects_message check (message is null or char_length(message) <= 140)
);
create index if not exists effects_to   on public.effects (to_user, seen_at, created_at desc);
create index if not exists effects_from on public.effects (from_user, to_user, seen_at);

alter table public.effects enable row level security;
revoke all on public.effects from anon, authenticated;
grant select on public.effects to authenticated;
drop policy if exists "verrassing lezen" on public.effects;
create policy "verrassing lezen" on public.effects for select to authenticated
  using ((select auth.uid()) = from_user or (select auth.uid()) = to_user);

-- De effecten die de app kent. Alleen deze namen kunnen worden verstuurd.
create or replace function private.effect_names() returns text[]
language sql immutable set search_path = '' as $$ select array['kurk'] $$;

create or replace function public.send_effect(p_to uuid, p_effect text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  if p_effect is null or not (p_effect = any (private.effect_names())) then return jsonb_build_object('status', 'invalid_effect'); end if;
  -- Dezelfde melding voor "geen vrienden" en "geblokkeerd".
  if p_to is null or p_to = uid or not private.are_friends(uid, p_to) or private.is_blocked(uid, p_to) then
    return jsonb_build_object('status', 'not_friends');
  end if;
  if private.over_limit(uid, 'effect', 10, interval '24 hours') then return jsonb_build_object('status', 'rate_limited'); end if;
  if (select count(*) from public.effects where from_user = uid and to_user = p_to and seen_at is null) >= 3 then
    return jsonb_build_object('status', 'too_many_pending');
  end if;
  perform private.note(uid, 'effect');
  -- Opruimen: geziene verrassingen ouder dan 30 dagen hoeven niet bewaard te blijven.
  delete from public.effects where to_user = p_to and seen_at < now() - interval '30 days';
  insert into public.effects (from_user, to_user, effect, message) values (uid, p_to, p_effect, nullif(private.clean(p_message, 140), ''));
  return jsonb_build_object('status', 'ok');
end $$;

-- Ongeziene verrassingen van de laatste 7 dagen, alleen van mensen die nog vriend zijn en niet geblokkeerd.
create or replace function public.my_effects() returns table (id uuid, from_name text, effect text, message text, created_at timestamptz)
language sql security definer stable set search_path = '' as $$
  select e.id, coalesce(p.display_name, '?'), e.effect, e.message, e.created_at
  from public.effects e left join public.profiles p on p.user_id = e.from_user
  where e.to_user = (select auth.uid()) and e.seen_at is null and e.created_at > now() - interval '7 days'
    and private.are_friends(e.to_user, e.from_user) and not private.is_blocked(e.to_user, e.from_user)
  order by e.created_at desc limit 20
$$;

create or replace function public.seen_effect(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  update public.effects set seen_at = now() where id = p_id and to_user = uid and seen_at is null;
  return jsonb_build_object('status', 'ok');
end $$;

revoke all on function private.effect_names() from public, anon, authenticated;
revoke all on function public.send_effect(uuid, text, text), public.my_effects(), public.seen_effect(uuid) from public, anon, authenticated;
grant execute on function public.send_effect(uuid, text, text), public.my_effects(), public.seen_effect(uuid) to authenticated;

-- Live: een verrassing verschijnt meteen bij de ontvanger als de app openstaat.
do $$ begin alter publication supabase_realtime add table public.effects; exception when duplicate_object then null; end $$;
