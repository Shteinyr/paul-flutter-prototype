-- Run only after the coordinator approves hosted activation, the reviewed
-- functions are deployed, and these two Vault secrets are provisioned privately.
-- Never replace them with literals or print vault.decrypted_secrets in logs.
-- paul_push_worker_url     exact HTTPS URL ending /functions/v1/push-worker
-- paul_push_worker_secret  same PAUL_PUSH_WORKER_SECRET used by that Edge Function
-- pg_cron and pg_net must be enabled in this project's Supabase configuration.
begin;
do $$
begin
  if not exists(select 1 from pg_extension where extname='pg_cron')
    or not exists(select 1 from pg_extension where extname='pg_net') then raise exception 'Required worker extensions are missing'; end if;
  if (select count(*) from vault.decrypted_secrets where name in ('paul_push_worker_url','paul_push_worker_secret'))<>2 then
    raise exception 'Worker Vault configuration is missing or ambiguous';
  end if;
  if exists(select 1 from vault.decrypted_secrets where name='paul_push_worker_url'
    and decrypted_secret<>'https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/push-worker') then raise exception 'Unexpected project target'; end if;
end;
$$;
select cron.unschedule(jobid) from cron.job where jobname='paul-web-push-worker';
select cron.schedule('paul-web-push-worker','* * * * *',$worker$
  select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='paul_push_worker_url'),
    headers:=jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='paul_push_worker_secret')),
    body:='{}'::jsonb,
    timeout_milliseconds:=50000
  );
$worker$);
commit;
