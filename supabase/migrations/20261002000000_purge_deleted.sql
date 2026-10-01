-- 軟刪除保留 30 天：每天清掉超過期限的列（Storage 內容不刪：內容定址，可能被其他版本共用）
create extension if not exists pg_cron with schema pg_catalog;

create function public.purge_deleted_files() returns integer
language sql security definer set search_path = ''
as $$
  with gone as (
    delete from public.files where deleted and updated_at < now() - interval '30 days' returning 1
  )
  select count(*)::integer from gone;
$$;

revoke execute on function public.purge_deleted_files from public, anon, authenticated;

select cron.schedule('purge-deleted-files', '17 3 * * *', 'select public.purge_deleted_files()');
