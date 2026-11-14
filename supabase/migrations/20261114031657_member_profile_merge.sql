-- Service-only, field-level optimistic writes. Old registration writes are unchanged.
-- Receipts contain only a request fingerprint and disappear with membership deletion.
create table private.profile_write_receipts (
  actor_id uuid not null references private.memberships(user_id) on delete cascade,
  operation_id uuid not null,
  request_hash text not null,
  primary key(actor_id, operation_id)
);
alter table private.profile_write_receipts enable row level security;
revoke all on private.profile_write_receipts from public, anon, authenticated;
grant all on private.profile_write_receipts to service_role;

create function public.merge_member_profile(p_user uuid, p_operation uuid, p_base jsonb, p_changes jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare current_profile public.profiles; current_values jsonb; merged jsonb;
  fingerprint text; previous_hash text; field text;
  allowed constant text[] := array['name','occupation','summary','skills','searching_skills','avatar_path'];
begin
  if p_operation is null or jsonb_typeof(p_base) is distinct from 'object'
    or jsonb_typeof(p_changes) is distinct from 'object'
    or exists(select 1 from jsonb_object_keys(p_base) k where not k=any(allowed))
    or exists(select 1 from jsonb_object_keys(p_changes) k where not k=any(allowed))
    or not p_base ?& allowed then raise exception 'invalid_profile'; end if;
  -- Same row-lock order as private.save_profile/account deletion. Two clients merge atomically.
  select * into current_profile from public.profiles where id=p_user for update;
  if not found or current_profile.deleted_at is not null then raise exception 'account_deleted'; end if;
  if current_profile.auth_user_id is distinct from p_user or current_profile.profile_kind<>'member'
    or not exists(select 1 from private.memberships where user_id=p_user) then
    raise exception 'membership_required';
  end if;
  fingerprint:=encode(sha256(convert_to(jsonb_build_array(p_base,p_changes)::text,'UTF8')),'hex');
  select request_hash into previous_hash from private.profile_write_receipts
    where actor_id=p_user and operation_id=p_operation;
  if found then
    if previous_hash<>fingerprint then raise exception 'invalid_profile'; end if;
    -- Never re-apply an acknowledged operation, even after an ABA change by another device.
    return jsonb_build_object('profile',public.member_network(p_user)->'profile');
  end if;
  current_values:=jsonb_build_object('name',current_profile.name,'occupation',current_profile.occupation,
    'summary',current_profile.summary,'skills',current_profile.skills,
    'searching_skills',current_profile.searching_skills,'avatar_path',current_profile.avatar_path);
  for field in select jsonb_object_keys(p_changes) loop
    if (current_values->field) is distinct from (p_base->field)
      and (current_values->field) is distinct from (p_changes->field) then
      raise exception 'profile_conflict';
    end if;
  end loop;
  merged:=current_values||p_changes;
  if jsonb_typeof(merged->'name') is distinct from 'string'
    or jsonb_typeof(merged->'occupation') is distinct from 'string'
    or jsonb_typeof(merged->'summary') is distinct from 'string'
    or jsonb_typeof(merged->'avatar_path') not in ('string','null') then
    raise exception 'invalid_profile';
  end if;
  if p_changes<>'{}'::jsonb then perform private.save_profile(p_user,merged); end if;
  insert into private.profile_write_receipts values(p_user,p_operation,fingerprint);
  return jsonb_build_object('profile',public.member_network(p_user)->'profile');
end;
$$;
revoke all on function public.merge_member_profile(uuid,uuid,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.merge_member_profile(uuid,uuid,jsonb,jsonb) to service_role;
