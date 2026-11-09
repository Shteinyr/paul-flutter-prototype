-- Only the Edge function's service role can issue or redeem invitations.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create table private.memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  activated_at timestamptz not null default clock_timestamp()
);
alter table private.memberships enable row level security;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 100),
  occupation text not null check (length(btrim(occupation)) between 1 and 150),
  summary text not null check (length(btrim(summary)) between 1 and 500),
  skills text[] not null,
  searching_skills text[] not null default '{}',
  avatar_path text,
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.profiles enable row level security;

create table public.connections (
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_low, user_high),
  check (user_low < user_high)
);
create index connections_user_high_idx on public.connections(user_high);
alter table public.connections enable row level security;

create table private.invitations (
  id uuid primary key default gen_random_uuid(),
  issuer_id uuid references public.profiles(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
  code_hash text unique check (code_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  max_uses integer check (max_uses > 0),
  uses integer not null default 0 check (uses >= 0),
  check (expires_at = created_at + interval '15 minutes'),
  check (max_uses is null or uses <= max_uses)
);
create index invitations_issuer_created_idx on private.invitations(issuer_id, created_at);
alter table private.invitations enable row level security;

create table private.invite_redemptions (
  invitation_id uuid not null references private.invitations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  redeemed_at timestamptz not null default clock_timestamp(),
  primary key (invitation_id, user_id)
);
create index invite_redemptions_user_idx on private.invite_redemptions(user_id);
alter table private.invite_redemptions enable row level security;

create table private.request_limits (
  bucket text primary key,
  window_started_at timestamptz not null,
  requests integer not null
);
alter table private.request_limits enable row level security;

-- Internal RLS predicates read protected tables without recursive policies.
create function private.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from private.memberships where user_id = (select auth.uid()));
$$;
create function private.can_read_profile(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member() and (
    target = (select auth.uid()) or exists (
      select 1 from public.connections
      where user_low = least(target, (select auth.uid()))
        and user_high = greatest(target, (select auth.uid()))
    )
  );
$$;
revoke all on function private.is_member(), private.can_read_profile(uuid) from public, anon;
grant execute on function private.is_member(), private.can_read_profile(uuid) to authenticated;

create policy profiles_read on public.profiles for select to authenticated
  using (private.can_read_profile(id));
create policy connections_read on public.connections for select to authenticated
  using ((select private.is_member()) and (user_low = (select auth.uid()) or user_high = (select auth.uid())));
revoke all on public.profiles, public.connections from anon, authenticated;
grant select on public.profiles, public.connections to authenticated;
grant all on public.profiles, public.connections to service_role;
grant all on all tables in schema private to service_role;

create function private.valid_skills(items text[], required boolean) returns boolean
language sql immutable set search_path = '' as $$
  select items is not null and cardinality(items) between (case when required then 1 else 0 end) and 100
    and not exists(select 1 from unnest(items) s where s is null or length(btrim(s)) not between 1 and 64);
$$;

create function private.save_profile(member_id uuid, draft jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  offered text[];
  searching text[];
  avatar text;
begin
  if jsonb_typeof(draft->'skills') is distinct from 'array'
    or jsonb_typeof(draft->'searching_skills') is distinct from 'array' then
    raise exception 'invalid_profile';
  end if;
  offered := array(select jsonb_array_elements_text(draft->'skills'));
  searching := array(select jsonb_array_elements_text(draft->'searching_skills'));
  if not private.valid_skills(offered, true) or not private.valid_skills(searching, false) then
    raise exception 'invalid_profile';
  end if;
  avatar := nullif(draft->>'avatar_path', '');
  if avatar is not null and avatar <> member_id::text || '/avatar.png' then
    raise exception 'invalid_profile';
  end if;
  insert into public.profiles(id, name, occupation, summary, skills, searching_skills, avatar_path)
  values(member_id, btrim(draft->>'name'), btrim(draft->>'occupation'), btrim(draft->>'summary'), offered, searching, avatar)
  on conflict(id) do update set name = excluded.name, occupation = excluded.occupation,
    summary = excluded.summary, skills = excluded.skills, searching_skills = excluded.searching_skills,
    avatar_path = excluded.avatar_path, updated_at = clock_timestamp();
end;
$$;

-- The caller identity is verified by Auth in the Edge function. These RPCs
-- reject browser roles, including authenticated accounts without membership.
create function public.invite_request_limit(p_bucket text, p_limit integer, p_seconds integer)
returns boolean language plpgsql set search_path = '' as $$
declare used integer;
begin
  insert into private.request_limits(bucket, window_started_at, requests)
  values(p_bucket, clock_timestamp(), 1)
  on conflict(bucket) do update set
    requests = case when private.request_limits.window_started_at + make_interval(secs => p_seconds) <= clock_timestamp()
      then 1 else private.request_limits.requests + 1 end,
    window_started_at = case when private.request_limits.window_started_at + make_interval(secs => p_seconds) <= clock_timestamp()
      then clock_timestamp() else private.request_limits.window_started_at end
  returning requests into used;
  delete from private.request_limits where window_started_at < clock_timestamp() - interval '2 hours';
  return used <= p_limit;
end;
$$;

create function public.issue_invitation(p_user uuid, p_token_hash text, p_code_hash text)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations; issued_at timestamptz;
begin
  perform 1 from private.memberships where user_id = p_user for update;
  if not found then raise exception 'membership_required'; end if;
  -- Retrying the same issuance never extends its original lifetime.
  select * into item from private.invitations where token_hash = p_token_hash and issuer_id = p_user;
  if not found then
    if (select count(*) from private.invitations where issuer_id = p_user and created_at > clock_timestamp() - interval '1 minute') >= 5 then
      raise exception 'rate_limited';
    end if;
    update private.invitations set code_hash = null where expires_at <= clock_timestamp() and code_hash is not null;
    issued_at := clock_timestamp();
    insert into private.invitations(issuer_id, token_hash, code_hash, created_at, expires_at)
      values(p_user, p_token_hash, p_code_hash, issued_at, issued_at + interval '15 minutes') returning * into item;
  end if;
  if item.revoked_at is not null or item.expires_at <= clock_timestamp() then raise exception 'invalid_invitation'; end if;
  return jsonb_build_object('id', item.id, 'expires_at', item.expires_at, 'server_now', clock_timestamp());
end;
$$;

create function public.check_invitation(p_hash text, p_manual boolean)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations;
begin
  select * into item from private.invitations
    where (not p_manual and token_hash = p_hash) or (p_manual and code_hash = p_hash);
  if not found or item.revoked_at is not null or item.expires_at <= clock_timestamp()
    or (item.max_uses is not null and item.uses >= item.max_uses) then
    raise exception 'invalid_invitation';
  end if;
  return jsonb_build_object('expires_at', item.expires_at, 'server_now', clock_timestamp());
end;
$$;

create function public.redeem_invitation(p_user uuid, p_hash text, p_manual boolean, p_profile jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations; already_member boolean;
begin
  -- A per-user lock serializes first registration with different invitations.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text, 0));
  select * into item from private.invitations
    where (not p_manual and token_hash = p_hash) or (p_manual and code_hash = p_hash)
    for update;
  if not found then raise exception 'invalid_invitation'; end if;
  if exists(select 1 from private.invite_redemptions where invitation_id = item.id and user_id = p_user) then
    return jsonb_build_object('connected', item.issuer_id is not null, 'replayed', true);
  end if;
  if item.issuer_id = p_user then raise exception 'own_invitation'; end if;
  if item.revoked_at is not null or item.expires_at <= clock_timestamp()
    or (item.max_uses is not null and item.uses >= item.max_uses) then
    raise exception 'invalid_invitation';
  end if;
  if item.issuer_id is not null and not exists(select 1 from private.memberships where user_id = item.issuer_id) then
    raise exception 'invalid_invitation';
  end if;
  already_member := exists(select 1 from private.memberships where user_id = p_user);
  if not already_member then
    perform private.save_profile(p_user, p_profile);
    insert into private.memberships(user_id) values(p_user);
  end if;
  if item.issuer_id is not null then
    insert into public.connections(user_low, user_high)
      values(least(p_user, item.issuer_id), greatest(p_user, item.issuer_id)) on conflict do nothing;
  end if;
  insert into private.invite_redemptions(invitation_id, user_id) values(item.id, p_user);
  update private.invitations set uses = uses + 1 where id = item.id;
  return jsonb_build_object('connected', item.issuer_id is not null, 'replayed', false);
end;
$$;

create function public.revoke_invitation(p_user uuid, p_invitation uuid)
returns void language sql set search_path = '' as $$
  update private.invitations set revoked_at = coalesce(revoked_at, clock_timestamp())
    where id = p_invitation and issuer_id = p_user;
$$;

create function public.save_member_profile(p_user uuid, p_profile jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if not exists(select 1 from private.memberships where user_id = p_user) then raise exception 'membership_required'; end if;
  perform private.save_profile(p_user, p_profile);
end;
$$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member(), private.can_read_profile(uuid) to authenticated;
grant execute on all functions in schema private to service_role;
revoke all on function public.invite_request_limit(text, integer, integer),
  public.issue_invitation(uuid, text, text), public.check_invitation(text, boolean),
  public.redeem_invitation(uuid, text, boolean, jsonb), public.revoke_invitation(uuid, uuid),
  public.save_member_profile(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.invite_request_limit(text, integer, integer),
  public.issue_invitation(uuid, text, text), public.check_invitation(text, boolean),
  public.redeem_invitation(uuid, text, boolean, jsonb), public.revoke_invitation(uuid, uuid),
  public.save_member_profile(uuid, jsonb) to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values('avatars', 'avatars', false, 3145728, array['image/png']);
create policy avatar_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and private.can_read_profile(owner_id::uuid));
create policy avatar_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.png');
create policy avatar_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.png')
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.png');
-- Pending registrations can read their own upload before membership activates.
create policy avatar_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.png');
