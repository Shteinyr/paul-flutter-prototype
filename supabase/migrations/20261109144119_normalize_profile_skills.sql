create or replace function private.valid_skills(items text[], required boolean) returns boolean
language sql immutable set search_path = '' as $$
  select items is not null and cardinality(items) between (case when required then 1 else 0 end) and 100
    and not exists(select 1 from unnest(items) s where s is null or length(btrim(s)) < 1 or octet_length(s) > 32768)
    and (select count(*) = count(distinct lower(regexp_replace(btrim(s), '\s+', ' ', 'g'))) from unnest(items) s);
$$;

create policy avatar_owner_delete on storage.objects for delete to authenticated
  using (bucket_id='avatars' and name ~ ('^' || (select auth.uid())::text || '/[a-f0-9]{64}[.]png$'));
