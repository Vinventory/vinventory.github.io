-- Vinventory: gratis scans met een sleutel van de app zelf (via de Edge Function "ai").
-- Plak dit hele bestand in Supabase > SQL Editor en klik op Run. Het is veilig om het opnieuw uit te voeren.
-- Voorwaarde: schema.sql en schema-vrienden.sql zijn al uitgevoerd (dit bestand gebruikt de tellers uit schema-vrienden.sql).
--
-- Ontwerp (zie AI-SLEUTEL-PLAN.md):
--  * Elke gebruiker krijgt 100 gratis scans (alleen het scannen van een etiket telt). Beschrijving en "past goed bij" tellen niet mee.
--  * Tempolimieten tegen misbruik: 10 scans per uur en 30 tekstvragen per dag per gebruiker.
--  * Het tellen en terugboeken gebeurt ALLEEN door de Edge Function (met de service-sleutel). Gebruikers kunnen de teller niet zelf
--    aanpassen: ze mogen alleen hun eigen stand lezen (ai_status).
--  * Wie een eigen Anthropic-sleutel invoert, gebruikt dit niet en kost niets.

create table if not exists public.ai_usage (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  free_total  int not null default 100 check (free_total >= 0),
  scans_used  int not null default 0 check (scans_used >= 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from anon, authenticated;
grant select on public.ai_usage to authenticated;
drop policy if exists "ai-stand lezen" on public.ai_usage;
create policy "ai-stand lezen" on public.ai_usage for select to authenticated using ((select auth.uid()) = user_id);

-- Je eigen stand: hoeveel gratis scans je hebt en hoeveel er over zijn.
create or replace function public.ai_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); u public.ai_usage;
begin
  if uid is null then raise exception 'niet ingelogd' using errcode = '28000'; end if;
  select * into u from public.ai_usage where user_id = uid;
  if not found then
    return jsonb_build_object('free_total', 100, 'used', 0, 'left', 100);
  end if;
  return jsonb_build_object('free_total', u.free_total, 'used', u.scans_used, 'left', greatest(u.free_total - u.scans_used, 0));
end $$;

-- Alleen voor de Edge Function: een scan of tekstvraag afboeken. Antwoorden: ok, limit (tegoed op), rate_limited (te snel).
create or replace function public.ai_consume(p_user uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.ai_usage;
begin
  if p_user is null or p_kind not in ('scan', 'text') or not exists (select 1 from auth.users where id = p_user) then
    return jsonb_build_object('status', 'invalid');
  end if;
  insert into public.ai_usage (user_id) values (p_user) on conflict (user_id) do nothing;
  select * into u from public.ai_usage where user_id = p_user for update;
  if p_kind = 'scan' then
    if private.over_limit(p_user, 'ai_scan', 10, interval '1 hour') then
      return jsonb_build_object('status', 'rate_limited', 'left', greatest(u.free_total - u.scans_used, 0));
    end if;
    if u.scans_used >= u.free_total then
      return jsonb_build_object('status', 'limit', 'left', 0);
    end if;
    perform private.note(p_user, 'ai_scan');
    update public.ai_usage set scans_used = scans_used + 1, updated_at = now() where user_id = p_user;
    return jsonb_build_object('status', 'ok', 'left', greatest(u.free_total - u.scans_used - 1, 0));
  end if;
  -- tekstvraag: kost geen gratis scan, wel een tempolimiet
  if private.over_limit(p_user, 'ai_text', 30, interval '24 hours') then
    return jsonb_build_object('status', 'rate_limited', 'left', greatest(u.free_total - u.scans_used, 0));
  end if;
  perform private.note(p_user, 'ai_text');
  return jsonb_build_object('status', 'ok', 'left', greatest(u.free_total - u.scans_used, 0));
end $$;

-- Alleen voor de Edge Function: een scan terugboeken als Anthropic een fout gaf (de gebruiker kon er niets aan doen).
create or replace function public.ai_refund(p_user uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_kind = 'scan' then
    update public.ai_usage set scans_used = greatest(scans_used - 1, 0), updated_at = now() where user_id = p_user;
    -- ook de tempoteller met één verlagen, zodat een mislukte poging niet meetelt
    delete from private.attempts where ctid = (select ctid from private.attempts where user_id = p_user and kind = 'ai_scan' order by at desc limit 1);
  end if;
  return jsonb_build_object('status', 'ok');
end $$;

revoke all on function public.ai_status() from public, anon, authenticated;
grant execute on function public.ai_status() to authenticated;
-- ai_consume en ai_refund: nooit voor gebruikers of anonieme bezoekers, alleen voor de Edge Function (rol service_role).
revoke all on function public.ai_consume(uuid, text), public.ai_refund(uuid, text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.ai_consume(uuid, text), public.ai_refund(uuid, text) to service_role;
  end if;
end $$;
