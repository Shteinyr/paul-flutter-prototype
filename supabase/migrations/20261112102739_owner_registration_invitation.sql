-- Owner activation uses a separate single-use capability. Ordinary QR codes
-- retain their existing 15-minute lifetime and never acquire an admin role.
create table private.owner_registration_invitations (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
  expected_email text not null,
  managed_profile_ids uuid[] not null default '{}',
  created_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null default statement_timestamp() + interval '7 days',
  revoked_at timestamptz,
  claimed_at timestamptz,
  claimed_by uuid references auth.users(id) on delete set null,
  check (expires_at > created_at and expires_at <= created_at + interval '7 days'),
  check (expected_email=lower(btrim(expected_email))
    and length(expected_email) between 3 and 254 and expected_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  check (cardinality(managed_profile_ids)<=1000),
  check (claimed_by is null or claimed_at is not null)
);
alter table private.owner_registration_invitations enable row level security;
revoke all on private.owner_registration_invitations from public,anon,authenticated;
grant all on private.owner_registration_invitations to service_role;

-- There is deliberately no browser/Edge issuance action for this operation.
-- Only the trusted provisioning operator can prepare the private invitation.
create function public.issue_owner_registration_invitation(
  p_hash text,p_expected_email text default null,p_profile_ids uuid[] default '{}'
) returns jsonb language plpgsql set search_path='' as $$
declare item private.owner_registration_invitations; issued timestamptz:=clock_timestamp();
begin
  if p_hash is null or p_hash !~ '^[a-f0-9]{64}$' or p_profile_ids is null
    or cardinality(p_profile_ids)>1000 or array_position(p_profile_ids,null) is not null
    or p_expected_email is null or length(btrim(p_expected_email)) not between 3 and 254
    or btrim(p_expected_email) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'invalid_invitation';
  end if;
  perform pg_advisory_xact_lock(770077);
  select * into item from private.owner_registration_invitations where token_hash=p_hash;
  if found then
    if item.expected_email is distinct from lower(btrim(p_expected_email))
      or item.managed_profile_ids is distinct from p_profile_ids then raise exception 'invalid_invitation'; end if;
    return jsonb_build_object('id',item.id,'expires_at',item.expires_at);
  end if;
  if exists(select 1 from private.owner_registration_invitations
    where claimed_at is null and revoked_at is null and expires_at>issued) then
    raise exception 'owner_invitation_pending';
  end if;
  if exists(select 1 from unnest(p_profile_ids) wanted(id)
    where not exists(select 1 from public.profiles p where p.id=wanted.id
      and p.profile_kind='managed' and p.deleted_at is null)) then raise exception 'invalid_invitation'; end if;
  insert into private.owner_registration_invitations(token_hash,expected_email,managed_profile_ids,created_at,expires_at)
    values(p_hash,lower(btrim(p_expected_email)),p_profile_ids,issued,issued+interval '7 days') returning * into item;
  return jsonb_build_object('id',item.id,'expires_at',item.expires_at);
end;
$$;

create function public.check_registration_invitation(p_hash text,p_manual boolean)
returns jsonb language plpgsql set search_path='' as $$
declare item private.owner_registration_invitations;
begin
  if not p_manual then
    select * into item from private.owner_registration_invitations where token_hash=p_hash;
    if found then
      if item.revoked_at is not null or item.claimed_at is not null or item.expires_at<=clock_timestamp() then
        raise exception 'invalid_invitation';
      end if;
      -- Do not disclose the privileged purpose, recipient or managed-profile IDs.
      return jsonb_build_object('expires_at',item.expires_at,'server_now',clock_timestamp());
    end if;
  end if;
  return public.check_invitation(p_hash,p_manual);
end;
$$;

create function public.redeem_registration_invitation(
  p_user uuid,p_hash text,p_manual boolean,p_profile jsonb,p_verified_google_email text
) returns jsonb language plpgsql set search_path='' as $$
declare item private.owner_registration_invitations;
begin
  -- Same lock as ordinary registration: two links cannot race one user's signup.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
  if not p_manual then
    select * into item from private.owner_registration_invitations where token_hash=p_hash for update;
    if found then
      if item.claimed_at is not null then
        if item.claimed_by is distinct from p_user then raise exception 'invalid_invitation'; end if;
        -- A retry cannot restore a subsequently revoked role or deleted account.
        if not exists(select 1 from private.memberships where user_id=p_user)
          or exists(select 1 from private.account_deletions where target_profile_id=p_user and kind='account') then
          raise exception 'account_deleted';
        end if;
        return jsonb_build_object('connected',false,'replayed',true);
      end if;
      if item.revoked_at is not null or item.expires_at<=clock_timestamp() then raise exception 'invalid_invitation'; end if;
      -- This value comes ONLY from the Edge's verified getUser/Google identity,
      -- never from request JSON, a profile name, or editable user_metadata.
      if p_verified_google_email is null or btrim(p_verified_google_email)=''
        or item.expected_email<>lower(btrim(p_verified_google_email)) then
        raise exception 'invitation_account_mismatch';
      end if;
      if p_user is null or exists(select 1 from public.profiles where id=p_user and deleted_at is not null)
        or exists(select 1 from private.account_deletions where target_profile_id=p_user and kind='account') then
        raise exception 'account_deleted';
      end if;
      if not exists(select 1 from private.memberships where user_id=p_user) then
        if not private.owns_avatar(p_user,p_profile->>'avatar_path') then raise exception 'invalid_profile'; end if;
        perform private.save_profile(p_user,p_profile);
        insert into private.memberships(user_id) values(p_user);
      end if;
      insert into private.admin_roles(user_id,role,granted_by) values(p_user,'owner',null)
        on conflict(user_id) do update set role='owner',revoked_at=null,granted_at=clock_timestamp(),granted_by=null;
      insert into private.managed_profile_grants(user_id,profile_id,can_manage,can_reply,granted_by)
        select p_user,p.id,true,true,p_user from public.profiles p
        where p.id=any(item.managed_profile_ids) and p.profile_kind='managed' and p.deleted_at is null
        on conflict(user_id,profile_id) do update set can_manage=true,can_reply=true,revoked_at=null,
          granted_at=clock_timestamp(),granted_by=excluded.granted_by;
      update private.owner_registration_invitations set claimed_by=p_user,claimed_at=clock_timestamp() where id=item.id;
      insert into private.admin_audit(actor_user_id,action,client_operation_id,details)
        values(p_user,'owner_invitation_accepted',item.id,jsonb_build_object('invitation_id',item.id));
      return jsonb_build_object('connected',false,'replayed',false);
    end if;
  end if;
  return public.redeem_invitation(p_user,p_hash,p_manual,p_profile);
end;
$$;

revoke all on function public.issue_owner_registration_invitation(text,text,uuid[]),
  public.check_registration_invitation(text,boolean),
  public.redeem_registration_invitation(uuid,text,boolean,jsonb,text) from public,anon,authenticated;
grant execute on function public.issue_owner_registration_invitation(text,text,uuid[]),
  public.check_registration_invitation(text,boolean),
  public.redeem_registration_invitation(uuid,text,boolean,jsonb,text) to service_role;
