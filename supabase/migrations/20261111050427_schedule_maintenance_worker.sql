-- Supabase operational activation, after application SQL and reviewed Edge deploy.
begin;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
do $$
begin
  if (select count(*) from vault.decrypted_secrets where name='paul_web_push_runtime')<>1
    or not exists(select 1 from vault.decrypted_secrets where name='paul_web_push_runtime'
      and length((decrypted_secret::jsonb)->>'worker_secret')=43
      and (decrypted_secret::jsonb)->>'worker_url'='https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/push-worker') then
    raise exception 'Maintenance credentials are missing or project target is unexpected';
  end if;
end;
$$;
select cron.unschedule(jobid) from cron.job where jobname='paul-maintenance-worker';
select cron.schedule('paul-maintenance-worker','* * * * *',$worker$
  select net.http_post(
    url:='https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/maintenance',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization',
      'Bearer '||(select (decrypted_secret::jsonb)->>'worker_secret' from vault.decrypted_secrets where name='paul_web_push_runtime')),
    body:='{}'::jsonb,timeout_milliseconds:=50000
  );
$worker$);
commit;
