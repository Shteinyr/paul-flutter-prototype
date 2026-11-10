-- The profile UUID is allocated by the database, never chosen by a browser.
-- Keep the exact actor/operation/reservation check without granting the Edge
-- database role access to the Auth schema's user data.
create or replace function public.admin_authorize_save(p_actor uuid,p_profile uuid,p_create boolean,p_client_operation uuid)
returns void language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  if p_profile is null or p_create is null or p_client_operation is null then raise exception 'invalid_request'; end if;
  if p_create and not exists(
    select 1 from private.managed_profile_reservations where actor_user_id=p_actor and client_operation_id=p_client_operation and profile_id=p_profile
  ) then raise exception 'managed_profile_forbidden'; end if;
  if not p_create or exists(select 1 from public.profiles where id=p_profile) then
    perform private.require_managed_profile(p_actor,p_profile);
    if p_create and not exists(select 1 from private.admin_audit where actor_user_id=p_actor
      and client_operation_id=p_client_operation and profile_id=p_profile and action='profile_create') then
      raise exception 'managed_profile_forbidden';
    end if;
  end if;
end;
$$;
