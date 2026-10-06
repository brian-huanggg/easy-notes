-- Permanent delete ("Delete Immediately" / "Empty Trash").
--
-- A hard-deleted file keeps a tombstone row (`purged`) so every other device learns about it through the normal pull;
-- deleting the row would leave them with a file nobody tells them to remove. Path, hash and size are cleared, so the
-- tombstone says nothing about what the file was.
--
-- Stored content is kept per file (`file_blobs`), so a hard delete can remove the content that only this file used.
-- Storage is content-addressed: a blob that another file (or an older version of one) still references must stay.

alter table public.files add column purged boolean not null default false;

create table public.file_blobs (
  file_id  uuid not null references public.files on delete cascade,
  user_id  uuid not null references auth.users on delete cascade,
  hash     text not null,
  primary key (file_id, hash)
);
create index file_blobs_user_hash on public.file_blobs (user_id, hash);

alter table public.file_blobs enable row level security;
create policy "read own file blobs" on public.file_blobs
  for select to authenticated using (user_id = (select auth.uid()));

-- Only the current version of each file is known before this migration; older versions stay unattributed
insert into public.file_blobs (file_id, user_id, hash)
select id, user_id, hash from public.files where hash <> '';

-- Same as the original commit_file, plus: a tombstone can never be committed over, and every committed hash is recorded
create or replace function public.commit_file(
  p_id uuid, p_base_version bigint, p_path text, p_hash text, p_size bigint, p_deleted boolean, p_device text
) returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  cur public.files;
  new_version bigint;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into cur from public.files where id = p_id for update;
  if found then
    if cur.user_id <> uid or cur.purged or p_base_version is distinct from cur.version then
      return null;
    end if;
  elsif p_base_version is not null then
    return null;
  end if;

  if not p_deleted and exists (
    select 1 from public.files f where f.user_id = uid and f.path = p_path and not f.deleted and f.id <> p_id
  ) then
    return null;
  end if;

  begin
    if found then
      update public.files
         set path = p_path, hash = p_hash, size = p_size, deleted = p_deleted, device_id = p_device,
             version = cur.version + 1, updated_at = clock_timestamp()
       where id = p_id
      returning version into new_version;
    else
      insert into public.files (id, user_id, path, hash, size, version, deleted, device_id)
      values (p_id, uid, p_path, p_hash, p_size, 1, p_deleted, p_device)
      returning version into new_version;
    end if;
  exception when unique_violation then
    -- The same id created at the same time, or the same path taken at the same time: the client pulls and retries
    return null;
  end;

  insert into public.file_blobs (file_id, user_id, hash) values (p_id, uid, p_hash) on conflict do nothing;
  return new_version;
end;
$$;

-- Turns the rows into tombstones in one transaction and returns the content hashes that no other file references any more
-- (the client then deletes those Storage objects). Versions are ignored: an explicit hard delete beats a concurrent edit.
-- Ids that are unknown, someone else's or already purged are skipped, so the call is idempotent.
create function public.purge_files(p_ids uuid[], p_device text) returns text[]
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  mine uuid[];
  candidates text[];
  freed text[];
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select coalesce(array_agg(id), '{}') into mine
    from (select id from public.files where id = any(p_ids) and user_id = uid and not purged order by id for update) locked;

  select coalesce(array_agg(distinct hash), '{}') into candidates
    from public.file_blobs where file_id = any(mine);

  update public.files
     set purged = true, deleted = true, path = id::text, hash = '', size = 0, device_id = p_device,
         version = version + 1, updated_at = clock_timestamp()
   where id = any(mine);

  delete from public.file_blobs where file_id = any(mine);

  select coalesce(array_agg(h), '{}') into freed
    from unnest(candidates) h
   where not exists (select 1 from public.file_blobs b where b.user_id = uid and b.hash = h)
     and not exists (select 1 from public.files f where f.user_id = uid and f.hash = h);
  return freed;
end;
$$;

revoke execute on function public.purge_files from public, anon;
grant execute on function public.purge_files to authenticated;

-- Storage used to be append-only. Now an owner may delete a blob only when nothing references it, so even a client that asks to
-- delete content a live or restorable file needs cannot.
create policy "delete unreferenced own blobs" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'vault'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and not exists (select 1 from public.file_blobs b
                     where b.user_id = (select auth.uid()) and b.hash = storage.filename(name))
    and not exists (select 1 from public.files f
                     where f.user_id = (select auth.uid()) and f.hash = storage.filename(name))
  );

-- Soft-deleted rows still go after 30 days; tombstones stay far longer so a device that was offline for weeks still hears about the delete
create or replace function public.purge_deleted_files() returns integer
language sql security definer set search_path = ''
as $$
  with gone as (
    delete from public.files
     where (deleted and not purged and updated_at < now() - interval '30 days')
        or (purged and updated_at < now() - interval '365 days')
    returning 1
  )
  select count(*)::integer from gone;
$$;
