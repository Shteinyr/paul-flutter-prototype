-- Minimal Auth/Storage stand-ins for an EMPTY, isolated postgres:17-alpine
-- container. Never run this bootstrap against a hosted Supabase project.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create schema storage;
create table auth.users(id uuid primary key);
create table auth.sessions(id uuid primary key,user_id uuid not null references auth.users(id),not_after timestamptz);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;
grant usage on schema auth to authenticated,service_role;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb);
$$;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key,bucket_id text,name text,owner_id text);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated;
grant select,insert,update,delete on storage.objects to authenticated;

-- Realtime stand-ins record transactional signals for isolated SQL assertions.
create schema realtime;
create table realtime.messages(topic text,extension text,payload jsonb,event text,private boolean);
alter table realtime.messages enable row level security;
grant usage on schema realtime to authenticated,service_role;
grant select,insert on realtime.messages to authenticated;
create function realtime.topic() returns text language sql stable as $$
  select current_setting('realtime.topic',true);
$$;
create function realtime.send(payload jsonb,event text,topic text,private boolean default true)
returns void language sql as $$
  insert into realtime.messages(topic,extension,payload,event,private) values(topic,'broadcast',payload,event,private);
$$;
