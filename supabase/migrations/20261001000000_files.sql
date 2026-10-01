-- EasyNotes 同步：files 資料表、commit_file RPC、RLS、Storage bucket
-- 檔案即真相：這裡只記錄每個檔案的身分、路徑、內容 hash 與版本；內容以 hash 為 key 存在 Storage。

create table public.files (
  id          uuid primary key,                 -- 穩定 file id，由建立檔案的裝置產生
  user_id     uuid not null references auth.users on delete cascade,
  path        text not null,                    -- vault 內相對路徑，只是屬性
  hash        text not null,                    -- SHA-256 of content
  size        bigint not null,
  version     bigint not null,                  -- 只由 commit_file 遞增
  deleted     boolean not null default false,   -- 軟刪除，保留 30 天
  device_id   text not null,
  updated_at  timestamptz not null default clock_timestamp()
);

create unique index files_live_path on public.files (user_id, path) where not deleted;
create index files_user_updated on public.files (user_id, updated_at);

-- 只能讀自己的列；寫入一律經過 commit_file，沒有 insert / update / delete 政策
alter table public.files enable row level security;
create policy "read own files" on public.files
  for select to authenticated using (user_id = (select auth.uid()));

-- 一個交易內：比對 base_version、寫入、遞增 version。
-- 回傳新 version；回傳 null = 遠端已變（或路徑被別的檔案佔用），client 需要拉取後合併。
create function public.commit_file(
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
    if cur.user_id <> uid or p_base_version is distinct from cur.version then
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
    -- 同一 id 同時新建，或同一路徑被同時佔用：讓 client 拉取後再試
    return null;
  end;
  return new_version;
end;
$$;

revoke execute on function public.commit_file from public, anon;
grant execute on function public.commit_file to authenticated;

-- Realtime：client 訂閱自己的 files 變更（RLS 同樣適用）
alter publication supabase_realtime add table public.files;

-- Storage：vault/<user_id>/<hash>，只增不覆寫（沒有 update / delete 政策）
insert into storage.buckets (id, name, public) values ('vault', 'vault', false)
on conflict (id) do nothing;

create policy "read own blobs" on storage.objects
  for select to authenticated
  using (bucket_id = 'vault' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "upload own blobs" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'vault' and (storage.foldername(name))[1] = (select auth.uid())::text);
