-- The authoritative phone stays in Auth. Consent contains only its revision hash.
create table private.phone_discovery_settings (
  user_id uuid primary key references public.profiles(id),
  phone_revision text check(phone_revision ~ '^[a-f0-9]{64}$'),
  consent_revision uuid not null default gen_random_uuid(),
  enabled_at timestamptz,
  check((phone_revision is null)=(enabled_at is null))
);
create table private.phone_lookup_days (
  user_id uuid not null references public.profiles(id),
  day_utc date not null,
  checks integer not null check(checks between 1 and 1000),
  primary key(user_id,day_utc)
);
alter table private.phone_discovery_settings enable row level security;
alter table private.phone_lookup_days enable row level security;
revoke all on private.phone_discovery_settings,private.phone_lookup_days from public,anon,authenticated;
grant all on private.phone_discovery_settings,private.phone_lookup_days to service_role;

create function private.verified_phone(p_user uuid) returns text
language sql stable security definer set search_path='' as $$
  select regexp_replace(phone,'^[+]','') from auth.users where id=p_user
    and phone_confirmed_at is not null and phone ~ '^[+]?[1-9][0-9]{1,14}$';
$$;
create function private.phone_revision(p_user uuid) returns text
language sql stable security definer set search_path='' as $$
  select encode(sha256(convert_to(private.verified_phone(id)||':'||extract(epoch from phone_confirmed_at)::text,'UTF8')),'hex')
    from auth.users where id=p_user;
$$;
create function private.require_discovery_actor(p_user uuid,p_session uuid) returns void
language plpgsql set search_path='' as $$
begin
  perform 1 from public.profiles where id=p_user and auth_user_id=p_user and deleted_at is null for share;
  perform private.require_member_session(p_user,p_session);
end;
$$;
create function public.phone_discovery_status(p_user uuid,p_session uuid) returns jsonb
language plpgsql set search_path='' as $$
declare phone text; revision text;
begin
  perform private.require_discovery_actor(p_user,p_session);
  phone:=private.verified_phone(p_user);
  revision:=private.phone_revision(p_user);
  return jsonb_build_object('has_verified_phone',phone is not null,'phone_last4',right(phone,4),'phone_revision',revision,
    'consent_revision',(select consent_revision from private.phone_discovery_settings where user_id=p_user),
    'discoverable',revision is not null and exists(select 1 from private.phone_discovery_settings where user_id=p_user and phone_revision=revision));
end;
$$;
create function public.phone_discovery_consent(p_user uuid,p_session uuid,p_enabled boolean,p_expected_revision text default null,p_expected_consent_revision uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare revision text; current_consent uuid;
begin
  perform private.require_discovery_actor(p_user,p_session);
  if p_enabled is null then raise exception 'invalid_request'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,70));
  select consent_revision into current_consent from private.phone_discovery_settings where user_id=p_user for update;
  if p_enabled then
    -- Serialize the consent check with a concurrent Auth phone update.
    perform 1 from auth.users where id=p_user for share;
    revision:=private.phone_revision(p_user);
    if revision is null then raise exception 'phone_verification_required'; end if;
    if revision is distinct from p_expected_revision then raise exception 'phone_changed'; end if;
  end if;
  if current_consent is distinct from p_expected_consent_revision then raise exception 'discovery_state_changed'; end if;
  if p_enabled then
    insert into private.phone_discovery_settings(user_id,phone_revision,enabled_at) values(p_user,revision,clock_timestamp())
      on conflict(user_id) do update set phone_revision=excluded.phone_revision,enabled_at=excluded.enabled_at,consent_revision=gen_random_uuid();
  else
    -- Retain only a revocation fence so an old enable retry cannot undo withdrawal.
    insert into private.phone_discovery_settings(user_id,phone_revision,enabled_at) values(p_user,null,null)
      on conflict(user_id) do update set phone_revision=null,enabled_at=null,consent_revision=gen_random_uuid();
  end if;
  return public.phone_discovery_status(p_user,p_session);
end;
$$;
create function public.phone_discovery_lookup(p_user uuid,p_session uuid,p_phones text[]) returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='8s' as $$
declare today date:=(clock_timestamp() at time zone 'UTC')::date; used integer; matches jsonb;
begin
  perform private.require_discovery_actor(p_user,p_session);
  if private.verified_phone(p_user) is null then raise exception 'phone_verification_required'; end if;
  if p_phones is null or cardinality(p_phones)<1 or cardinality(p_phones)>50
    or exists(select 1 from unnest(p_phones) phone where phone is not null and phone !~ '^[+][1-9][0-9]{1,14}$') then
    raise exception 'invalid_request';
  end if;
  delete from private.phone_lookup_days where user_id=p_user and day_utc<today-1;
  insert into private.phone_lookup_days(user_id,day_utc,checks) values(p_user,today,cardinality(p_phones))
    on conflict(user_id,day_utc) do update set checks=private.phone_lookup_days.checks+excluded.checks
      where private.phone_lookup_days.checks+excluded.checks<=1000 returning checks into used;
  if not found then raise exception 'rate_limited'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('index',selected.position-1,'profile_id',p.id) order by selected.position),'[]'::jsonb)
    into matches from unnest(p_phones) with ordinality selected(phone,position)
    join auth.users u on u.phone in(selected.phone,substring(selected.phone from 2)) and u.phone_confirmed_at is not null
    join public.profiles p on p.id=u.id and p.auth_user_id=u.id and p.profile_kind='member'
    join private.memberships m on m.user_id=p.id
    join private.phone_discovery_settings settings on settings.user_id=u.id and settings.phone_revision=private.phone_revision(u.id)
    where p.id<>p_user and p.deleted_at is null and p.disabled_at is null;
  return jsonb_build_object('matches',matches);
end;
$$;

revoke all on function private.verified_phone(uuid),private.phone_revision(uuid),private.require_discovery_actor(uuid,uuid),
  public.phone_discovery_status(uuid,uuid),public.phone_discovery_consent(uuid,uuid,boolean,text,uuid),public.phone_discovery_lookup(uuid,uuid,text[])
  from public,anon,authenticated;
grant execute on function private.verified_phone(uuid),private.phone_revision(uuid),private.require_discovery_actor(uuid,uuid),
  public.phone_discovery_status(uuid,uuid),public.phone_discovery_consent(uuid,uuid,boolean,text,uuid),public.phone_discovery_lookup(uuid,uuid,text[])
  to service_role;
