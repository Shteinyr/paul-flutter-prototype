-- Run only after the coordinator approves hosted activation, the reviewed
-- functions are deployed, and Edge has provisioned its disabled Vault settings.
-- Never replace them with literals or print vault.decrypted_secrets in logs.
-- Only the fixed paul_web_push_runtime Vault entry is read by this job.
begin;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
do $$
begin
  if not exists(select 1 from pg_extension where extname='pg_cron')
    or not exists(select 1 from pg_extension where extname='pg_net') then raise exception 'Required worker extensions are missing'; end if;
  if (select count(*) from vault.decrypted_secrets where name='paul_web_push_runtime')<>1 then
    raise exception 'Worker Vault configuration is missing or ambiguous';
  end if;
  if not exists(select 1 from vault.decrypted_secrets where name='paul_web_push_runtime'
    and (decrypted_secret::jsonb)->>'worker_url'='https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/push-worker'
    and (decrypted_secret::jsonb)->'enabled'='true'::jsonb
    and length((decrypted_secret::jsonb)->>'worker_secret')=43) then raise exception 'Worker is disabled or target is unexpected'; end if;
end;
$$;
select cron.unschedule(jobid) from cron.job where jobname='paul-web-push-worker';
select cron.schedule('paul-web-push-worker','* * * * *',$worker$
  select net.http_post(
    url:=(select (decrypted_secret::jsonb)->>'worker_url' from vault.decrypted_secrets where name='paul_web_push_runtime'),
    headers:=jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer '||(select (decrypted_secret::jsonb)->>'worker_secret' from vault.decrypted_secrets where name='paul_web_push_runtime')),
    body:='{}'::jsonb,
    timeout_milliseconds:=50000
  );
$worker$);
commit;
