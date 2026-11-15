-- Auth proves identity; admission authorizes precisely one Auth session.
create table private.session_admissions (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid primary key,
  admitted_at timestamptz not null default clock_timestamp(),
  legacy_snapshot_at timestamptz,
  invitation_id uuid,
  source text not null check(source in ('existing_session','invitation','owner_invitation')),
  credential_hash text check(credential_hash ~ '^[a-f0-9]{64}$'),
  manual boolean not null default false,
  revoked_at timestamptz
);
create index session_admissions_user_idx on private.session_admissions(user_id);
alter table private.session_admissions enable row level security;
revoke all on private.session_admissions from public,anon,authenticated;
grant all on private.session_admissions to service_role;

-- One-time compatibility snapshot, never a permanent exemption for old users.
insert into private.session_admissions(user_id,session_id,source,legacy_snapshot_at)
select s.user_id,s.id,'existing_session',clock_timestamp()
from auth.sessions s join private.memberships m on m.user_id=s.user_id
join public.profiles p on p.id=m.user_id
where (s.not_after is null or s.not_after>clock_timestamp())
  and p.profile_kind='member' and p.auth_user_id=s.user_id
  and p.disabled_at is null and p.deleted_at is null
  and not exists(select 1 from private.account_deletions d where d.target_profile_id=s.user_id and d.kind='account');

create function private.member_session_admitted(p_user uuid,p_session uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select private.push_session_active(p_user,p_session) and exists(
    select 1 from private.session_admissions a
    join private.memberships m on m.user_id=a.user_id join public.profiles p on p.id=m.user_id
    where a.user_id=p_user and a.session_id=p_session and a.revoked_at is null
      and p.auth_user_id=p_user and p.profile_kind='member' and p.disabled_at is null and p.deleted_at is null
  );
$$;
create function private.jwt_session_id() returns uuid
language sql stable set search_path='' as $$
  select case when auth.jwt()->>'session_id' ~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'
    then (auth.jwt()->>'session_id')::uuid end;
$$;
create or replace function private.is_member() returns boolean
language sql stable security definer set search_path='' as $$
  select private.member_session_admitted((select auth.uid()),private.jwt_session_id());
$$;
create or replace function private.require_member_session(p_user uuid,p_session uuid) returns void
language plpgsql stable set search_path='' as $$
begin
  perform private.require_auth_session(p_user,p_session);
  perform private.require_chat_member(p_user,null);
  if not private.member_session_admitted(p_user,p_session) then raise exception 'invitation_required'; end if;
end;
$$;
create or replace function private.require_push_member(p_user uuid,p_session uuid) returns void
language sql stable set search_path='' as $$ select private.require_member_session(p_user,p_session); $$;

-- Pre-registration photos have a separate short-lived permit. This does not
-- admit the session to member APIs and expires no later than the invitation.
create table private.registration_upload_permits (
  session_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  invitation_id uuid not null,
  source text not null check(source in ('invitation','owner_invitation')),
  owner_email text,
  check((source='owner_invitation' and owner_email is not null)
    or (source='invitation' and owner_email is null))
);
alter table private.registration_upload_permits enable row level security;
revoke all on private.registration_upload_permits from public,anon,authenticated;
grant all on private.registration_upload_permits to service_role;

-- A permit is a reference to one live invitation, not an independent upload
-- capability. Revocation, expiry, exhaustion and issuer deletion take effect
-- in the Storage policy even when the Auth session itself remains active.
create function private.registration_upload_permit_valid(p_user uuid,p_session uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from private.registration_upload_permits permit
    where permit.user_id=p_user and permit.session_id=p_session and permit.expires_at>clock_timestamp()
    and ((permit.source='invitation' and exists(select 1 from private.invitations i
      where i.id=permit.invitation_id and i.revoked_at is null and i.expires_at>clock_timestamp()
        and (i.max_uses is null or i.uses<i.max_uses) and i.issuer_id is distinct from p_user
        and (i.issuer_id is null or exists(select 1 from public.profiles issuer
          join private.memberships m on m.user_id=issuer.id where issuer.id=i.issuer_id
          and issuer.auth_user_id=issuer.id and issuer.profile_kind='member'
          and issuer.disabled_at is null and issuer.deleted_at is null))))
    or (permit.source='owner_invitation' and exists(select 1 from private.owner_registration_invitations i
      where i.id=permit.invitation_id and i.revoked_at is null and i.claimed_at is null
        and i.expires_at>clock_timestamp() and i.expected_email=permit.owner_email))));
$$;

create function private.valid_session_invitation(p_user uuid,p_hash text,p_manual boolean,p_email text)
returns jsonb language plpgsql set search_path='' as $$
declare ordinary private.invitations; owner_invite private.owner_registration_invitations; issuer uuid;
begin
  if not p_manual then
    select * into owner_invite from private.owner_registration_invitations where token_hash=p_hash for update;
    if found then
      if owner_invite.revoked_at is not null or owner_invite.claimed_at is not null
        or owner_invite.expires_at<=clock_timestamp() then raise exception 'invalid_invitation'; end if;
      if p_email is null or owner_invite.expected_email<>lower(btrim(p_email)) then
        raise exception 'invitation_account_mismatch'; end if;
      return jsonb_build_object('id',owner_invite.id,'expires_at',owner_invite.expires_at,'source','owner_invitation');
    end if;
  end if;
  select * into ordinary from private.invitations
    where (p_manual and code_hash=p_hash) or (not p_manual and token_hash=p_hash);
  if not found then raise exception 'invalid_invitation'; end if;
  issuer:=ordinary.issuer_id;
  if issuer is not null then
    perform 1 from public.profiles p join private.memberships m on m.user_id=p.id
      where p.id=issuer and p.auth_user_id=p.id and p.deleted_at is null and p.disabled_at is null for share of p;
    if not found then raise exception 'invalid_invitation'; end if;
  end if;
  select * into ordinary from private.invitations
    where (p_manual and code_hash=p_hash) or (not p_manual and token_hash=p_hash) for update;
  if not found or ordinary.issuer_id is distinct from issuer or ordinary.revoked_at is not null or ordinary.expires_at<=clock_timestamp()
    or (ordinary.max_uses is not null and ordinary.uses>=ordinary.max_uses) then raise exception 'invalid_invitation'; end if;
  if ordinary.issuer_id=p_user then raise exception 'own_invitation'; end if;
  if ordinary.issuer_id is not null and not exists(select 1 from private.memberships m
    join public.profiles p on p.id=m.user_id where m.user_id=ordinary.issuer_id
    and p.auth_user_id=m.user_id and p.disabled_at is null and p.deleted_at is null) then raise exception 'invalid_invitation'; end if;
  return jsonb_build_object('id',ordinary.id,'expires_at',ordinary.expires_at,'source','invitation');
end;
$$;
create function public.prepare_registration_session(p_user uuid,p_session uuid,p_hash text,p_manual boolean,p_verified_google_email text)
returns jsonb language plpgsql set search_path='' as $$
declare invitation jsonb;
begin
  perform private.require_auth_session(p_user,p_session);
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
  if private.member_session_admitted(p_user,p_session) then return jsonb_build_object('admitted',true); end if;
  invitation:=private.valid_session_invitation(p_user,p_hash,p_manual,p_verified_google_email);
  -- Existing users skip profile entry and have no upload exception.
  if not exists(select 1 from private.memberships where user_id=p_user) then
    insert into private.registration_upload_permits(user_id,session_id,expires_at,invitation_id,source,owner_email)
      values(p_user,p_session,least((invitation->>'expires_at')::timestamptz,clock_timestamp()+interval '15 minutes'),
        (invitation->>'id')::uuid,invitation->>'source',
        case when invitation->>'source'='owner_invitation' then lower(btrim(p_verified_google_email)) end)
      on conflict(session_id) do update set expires_at=excluded.expires_at,
        invitation_id=excluded.invitation_id,source=excluded.source,owner_email=excluded.owner_email
      where private.registration_upload_permits.user_id=excluded.user_id;
  end if;
  return jsonb_build_object('admitted',false);
end;
$$;
create function public.redeem_session_invitation(p_user uuid,p_session uuid,p_hash text,p_manual boolean,p_profile jsonb,p_verified_google_email text)
returns jsonb language plpgsql set search_path='' as $$
declare invitation jsonb; result jsonb; previous private.session_admissions;
  legacy private.invitations;
begin
  perform private.require_auth_session(p_user,p_session);
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
  select * into previous from private.session_admissions where session_id=p_session and user_id=p_user and revoked_at is null;
  -- Lost ACK is valid for the same admitted session and credential only. Old
  -- redemption rows never authorize a different session after invite expiry.
  if found and previous.credential_hash=p_hash and previous.manual=p_manual then
    perform private.require_member_session(p_user,p_session);
    return jsonb_build_object('admitted',true,'replayed',true);
  end if;
  -- Only sessions captured at the compatibility boundary can acknowledge an
  -- older completed redemption without a session-specific credential receipt.
  -- History must predate that boundary and belong to this exact user+invite.
  -- Never call legacy redemption here: no profile, role, referral or connection
  -- can be restored by acknowledging an old response.
  if previous.legacy_snapshot_at is not null then
    perform private.require_member_session(p_user,p_session);
    if not p_manual and exists(select 1 from private.owner_registration_invitations i
      where i.token_hash=p_hash and i.claimed_by=p_user and i.claimed_at<=previous.legacy_snapshot_at) then
      return jsonb_build_object('admitted',true,'replayed',true,'connected',false);
    end if;
    select i.* into legacy from private.invitations i join private.invite_redemptions r on r.invitation_id=i.id
      where r.user_id=p_user and r.redeemed_at<=previous.legacy_snapshot_at
        and ((p_manual and i.code_hash=p_hash) or (not p_manual and i.token_hash=p_hash));
    if found then
      return jsonb_build_object('admitted',true,'replayed',true,'connected',
        legacy.issuer_id is not null and exists(select 1 from public.connections
          where user_low=least(p_user,legacy.issuer_id) and user_high=greatest(p_user,legacy.issuer_id)));
    end if;
  end if;
  invitation:=private.valid_session_invitation(p_user,p_hash,p_manual,p_verified_google_email);
  result:=public.redeem_registration_invitation(p_user,p_hash,p_manual,p_profile,p_verified_google_email);
  insert into private.session_admissions(user_id,session_id,invitation_id,source,credential_hash,manual)
    values(p_user,p_session,(invitation->>'id')::uuid,invitation->>'source',p_hash,p_manual)
    on conflict(session_id) do update set invitation_id=excluded.invitation_id,source=excluded.source,
      credential_hash=excluded.credential_hash,manual=excluded.manual,admitted_at=clock_timestamp()
      where private.session_admissions.user_id=excluded.user_id and private.session_admissions.revoked_at is null;
  perform private.require_member_session(p_user,p_session);
  delete from private.registration_upload_permits where session_id=p_session and user_id=p_user;
  return result||jsonb_build_object('admitted',true);
end;
$$;
create or replace function private.avatar_owner_access() returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and private.push_session_active(auth.uid(),private.jwt_session_id())
    and not exists(select 1 from public.profiles where id=auth.uid() and deleted_at is not null)
    and not exists(select 1 from private.account_deletions where target_profile_id=auth.uid() and kind='account')
    and (private.member_session_admitted(auth.uid(),private.jwt_session_id()) or (
      not exists(select 1 from private.memberships where user_id=auth.uid())
      and private.registration_upload_permit_valid(auth.uid(),private.jwt_session_id())
    ));
$$;
-- Preserve the function identity used by dispatch and click authorization.
create or replace function private.push_route(p_user uuid,p_session uuid,p_job uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare job private.notification_jobs; recipient public.profiles;
begin
  if not private.member_session_admitted(p_user,p_session) then return null; end if;
  if not private.push_session_active(p_user,p_session) or not exists(
    select 1 from private.memberships m join public.profiles p on p.id=m.user_id
      where m.user_id=p_user and p.auth_user_id=p_user and p.disabled_at is null and p.deleted_at is null) then return null; end if;
  select * into job from private.notification_jobs where id=p_job;
  if not found then return null; end if;
  if job.kind='community_created' then
    if job.recipient_user_id<>p_user then return null; end if;
    return jsonb_build_object('kind','community','request_id',job.request_id,
      'state',case when exists(select 1 from public.community_requests r join public.profiles p on p.id=r.author_profile_id
        where r.id=job.request_id and r.expires_at>clock_timestamp() and p.deleted_at is null and p.disabled_at is null)
        then 'active' else 'unavailable' end);
  end if;
  if not exists(select 1 from public.conversation_members where conversation_id=job.conversation_id and user_id=job.recipient_user_id)
    or exists(select 1 from public.profiles p join public.conversation_members m on m.user_id=p.id
      where m.conversation_id=job.conversation_id and p.disabled_at is not null) then return null; end if;
  select * into recipient from public.profiles where id=job.recipient_user_id;
  if recipient.profile_kind='member' and recipient.auth_user_id=p_user then
    return jsonb_build_object('kind','chat','conversation_id',job.conversation_id);
  end if;
  if recipient.profile_kind='managed' and exists(select 1 from private.admin_roles r join private.managed_profile_grants g on g.user_id=r.user_id
    where r.user_id=p_user and r.revoked_at is null and g.profile_id=recipient.id and g.can_reply and g.revoked_at is null) then
    return jsonb_build_object('kind','operator','conversation_id',job.conversation_id,'managed_profile_id',recipient.id);
  end if;
  return null;
end;
$$;

revoke all on function private.member_session_admitted(uuid,uuid),private.jwt_session_id(),
  private.registration_upload_permit_valid(uuid,uuid),
  private.valid_session_invitation(uuid,text,boolean,text),private.push_route(uuid,uuid,uuid),
  public.prepare_registration_session(uuid,uuid,text,boolean,text),
  public.redeem_session_invitation(uuid,uuid,text,boolean,jsonb,text) from public,anon,authenticated;
grant execute on function private.member_session_admitted(uuid,uuid),private.jwt_session_id(),
  private.registration_upload_permit_valid(uuid,uuid),
  private.valid_session_invitation(uuid,text,boolean,text),private.push_route(uuid,uuid,uuid),
  public.prepare_registration_session(uuid,uuid,text,boolean,text),
  public.redeem_session_invitation(uuid,uuid,text,boolean,jsonb,text) to service_role;
-- is_member and avatar_owner_access execute as owner; no raw session details are exposed.

create or replace function public.avatar_upload_begin(p_path text) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();session_key text:=auth.jwt()->>'session_id';
begin
 if actor is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false)
   or private.avatar_path_known(p_path) is distinct from true or split_part(p_path,'/',1)<>actor::text then
   raise exception 'sign_in_required';
 end if;
 if session_key is null or session_key !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then raise exception 'session_revoked';end if;
 if not private.push_session_active(actor,session_key::uuid) then raise exception 'session_revoked';end if;
 if not exists(select 1 from auth.users where id=actor) or private.avatar_account_deletion(actor)
   or exists(select 1 from public.profiles where id=actor and deleted_at is not null) then raise exception 'profile_unavailable';end if;
 if not private.avatar_owner_access() then raise exception 'invitation_required';end if;
 perform private.avatar_begin(p_path,'upload');
end;$$;


-- A fresh delete needs member admission; retries of an already authorized
-- deletion retain their original receipt even after membership is removed.
create or replace function public.member_delete_account(p_user uuid,p_session uuid,p_expected_user uuid,p_operation uuid,p_receipt_hash text) returns jsonb
language plpgsql set search_path='' as $$
begin
  if p_expected_user is distinct from p_user then raise exception 'identity_changed'; end if;
  if not exists(select 1 from private.account_deletions where operation_id=p_operation
    and actor_profile_id=p_user and target_profile_id=p_user and kind='account' and receipt_hash=p_receipt_hash) then
    perform private.require_member_session(p_user,p_session);
  end if;
  return private.start_profile_deletion(p_user,p_session,p_user,p_operation,'account',p_receipt_hash,null);
end;$$;
