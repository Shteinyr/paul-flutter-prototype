-- Classify notifications without exposing sender, message, skill or request text.
-- Existing leases, dispatch authorization, TTL and click resolution stay intact.
create or replace function public.push_prepare(p_delivery uuid,p_lease uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare delivery private.push_deliveries; item private.push_subscriptions;
begin
  select * into delivery from private.push_deliveries where id=p_delivery for update;
  if not found or p_lease is null or delivery.status<>'leased' or delivery.lease_token is distinct from p_lease
    or delivery.lease_until is null or delivery.lease_until<=clock_timestamp() then return null; end if;
  select * into item from private.push_subscriptions where binding_id=delivery.binding_id;
  if item.disabled_at is not null or (item.expires_at is not null and item.expires_at<=clock_timestamp())
    or exists(select 1 from private.notification_jobs where id=delivery.job_id and created_at+interval '24 hours'<=clock_timestamp()+interval '30 seconds')
    or not private.push_dispatch_allowed(item.user_id,item.session_id,delivery.job_id) then
    update private.push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
    return null;
  end if;
  update private.push_deliveries set lease_until=clock_timestamp()+interval '30 seconds' where id=delivery.id;
  return jsonb_build_object('lease_remaining_ms',30000,'endpoint',item.endpoint,'keys',jsonb_build_object('p256dh',item.p256dh,'auth',item.auth),
    'payload',jsonb_build_object('version',1,'delivery_id',delivery.id,'binding_id',item.binding_id,'recipient_user_id',item.user_id,
      'kind',(select kind from private.notification_jobs where id=delivery.job_id)));
end;
$$;
