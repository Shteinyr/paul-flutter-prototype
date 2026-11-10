-- Keep every existing profile UUID and all conversation/network references.
alter table public.profiles add column auth_user_id uuid;
update public.profiles set auth_user_id=id;
alter table public.profiles drop constraint profiles_id_fkey;
alter table public.profiles
  add constraint profiles_auth_user_id_fkey foreign key(auth_user_id) references auth.users(id),
  add constraint profiles_auth_user_id_key unique(auth_user_id),
  add column profile_kind text not null default 'member',
  add column disabled_at timestamptz,
  add constraint profiles_identity_check check (
    (profile_kind='member' and auth_user_id is not null and id=auth_user_id and disabled_at is null)
    or (profile_kind='managed' and auth_user_id is null)
  );

-- Existing registration/save code inserts id only. Populate its Auth link on
-- insert without changing those callers or allowing managed identities to log in.
create function private.profile_auth_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.profile_kind='member' and new.auth_user_id is null then new.auth_user_id:=new.id; end if;
  return new;
end;
$$;
create trigger profile_auth_identity before insert on public.profiles
  for each row execute function private.profile_auth_identity();

create table private.admin_roles (
  user_id uuid primary key references auth.users(id),
  role text not null check(role in ('owner','admin')),
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz
);
create table private.managed_profile_grants (
  user_id uuid not null references auth.users(id),
  profile_id uuid not null references public.profiles(id),
  can_manage boolean not null default false,
  can_reply boolean not null default false,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  primary key(user_id,profile_id)
);
create index managed_profile_grants_profile_idx on private.managed_profile_grants(profile_id,user_id);
create table private.admin_audit (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users(id),
  profile_id uuid references public.profiles(id),
  action text not null,
  client_operation_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default clock_timestamp(),
  unique(actor_user_id,client_operation_id)
);
create index admin_audit_profile_idx on private.admin_audit(profile_id,created_at);
alter table private.admin_roles enable row level security;
alter table private.managed_profile_grants enable row level security;
alter table private.admin_audit enable row level security;
revoke all on private.admin_roles,private.managed_profile_grants,private.admin_audit from public,anon,authenticated;
grant all on private.admin_roles,private.managed_profile_grants,private.admin_audit to service_role;

create function private.require_admin(p_actor uuid) returns text
language plpgsql set search_path = '' as $$
declare assigned_role text;
begin
  if p_actor is null or not exists(select 1 from private.memberships where user_id=p_actor) then
    raise exception 'admin_forbidden';
  end if;
  -- Locks serialize privileged commands against concurrent role revocation.
  select role into assigned_role from private.admin_roles where user_id=p_actor and revoked_at is null for share;
  if not found then raise exception 'admin_forbidden'; end if;
  return assigned_role;
end;
$$;
create function private.require_managed_profile(p_actor uuid,p_profile uuid,p_reply boolean default false)
returns void language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  -- Fixed role -> grant -> profile order also serializes disable/edit/reply.
  perform 1 from private.managed_profile_grants g
    where g.user_id=p_actor and g.profile_id=p_profile and g.revoked_at is null
      and (case when p_reply then g.can_reply else g.can_manage end) for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
  perform 1 from public.profiles p where p.id=p_profile and p.profile_kind='managed'
    and (not p_reply or p.disabled_at is null) for update;
  if not found then raise exception 'managed_profile_forbidden'; end if;
end;
$$;

-- Sole public entry is service-only. Edge supplies the verified Auth identity.
-- Administrative access never adds a bypass to profile/chat/avatar RLS.
create function public.admin_context(p_actor uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare assigned_role text; items jsonb;
begin
  assigned_role:=private.require_admin(p_actor);
  select coalesce(jsonb_agg(to_jsonb(p) || jsonb_build_object('can_manage',g.can_manage,'can_reply',g.can_reply)
    order by p.name,p.id),'[]'::jsonb) into items
  from private.managed_profile_grants g join public.profiles p on p.id=g.profile_id
  where g.user_id=p_actor and g.revoked_at is null and p.profile_kind='managed' and (g.can_manage or g.can_reply);
  return jsonb_build_object('role',assigned_role,'profiles',items);
end;
$$;
revoke all on function private.profile_auth_identity(),private.require_admin(uuid),
  private.require_managed_profile(uuid,uuid,boolean),public.admin_context(uuid) from public,anon,authenticated;
grant execute on function private.profile_auth_identity(),private.require_admin(uuid),
  private.require_managed_profile(uuid,uuid,boolean),public.admin_context(uuid) to service_role;
