-- Configure only the separate native worker. Provider activation is explicit;
-- applying this migration does not create a job or change existing schedules.
create function public.native_push_configure_scheduler(
  p_worker_secret text,
  p_enabled boolean default false
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  runtime_id uuid;
  runtime_count integer;
  native_job bigint;
  settings jsonb;
begin
  if p_worker_secret is null or p_worker_secret !~ '^[A-Za-z0-9_-]{43}$'
    or p_enabled is null then raise exception 'invalid_request'; end if;
  if not exists(select 1 from pg_catalog.pg_extension where extname='pg_cron')
    or not exists(select 1 from pg_catalog.pg_extension where extname='pg_net') then
    raise exception 'server_unavailable';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('paul_native_push_runtime',78));
  select count(*) into runtime_count from vault.secrets where name='paul_native_push_runtime';
  if runtime_count>1 then raise exception 'server_unavailable'; end if;
  settings:=pg_catalog.jsonb_build_object(
    'enabled',p_enabled,
    'worker_secret',p_worker_secret,
    'worker_url','https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/native-push-worker'
  );
  if runtime_count=0 then
    perform vault.create_secret(new_secret:=settings::text,new_name:='paul_native_push_runtime',
      new_description:='Paul native push worker authentication; no provider private key');
  else
    select id into runtime_id from vault.secrets where name='paul_native_push_runtime';
    perform vault.update_secret(secret_id:=runtime_id,new_secret:=settings::text);
  end if;
  if (select count(*) from cron.job where jobname='paul-native-push-worker')>1 then
    raise exception 'server_unavailable';
  end if;
  select jobid into native_job from cron.job where jobname='paul-native-push-worker';
  -- A fixed canonical command replaces only our dedicated native job. The
  -- bearer stays encrypted in Vault and is never embedded in cron.job.command.
  if native_job is not null then perform cron.unschedule(native_job); end if;
  native_job:=cron.schedule('paul-native-push-worker','* * * * *',$worker$
    select net.http_post(
      url:=(runtime.decrypted_secret::jsonb)->>'worker_url',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization',
        'Bearer '||((runtime.decrypted_secret::jsonb)->>'worker_secret')),
      body:='{}'::jsonb,
      timeout_milliseconds:=50000
    )
    from vault.decrypted_secrets runtime
    where runtime.name='paul_native_push_runtime'
      and (runtime.decrypted_secret::jsonb)->'enabled'='true'::jsonb
      and (runtime.decrypted_secret::jsonb)->>'worker_url'=
        'https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/native-push-worker';
  $worker$);
  perform cron.alter_job(native_job,active:=p_enabled);
  return p_enabled;
end;
$$;
revoke all on function public.native_push_configure_scheduler(text,boolean) from public,anon,authenticated;
grant execute on function public.native_push_configure_scheduler(text,boolean) to service_role;
