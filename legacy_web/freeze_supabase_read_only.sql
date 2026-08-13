-- 仅在 Android 迁移、重启、覆盖升级和备份恢复全部验收后人工执行。
-- 本文件不删除任何数据，只冻结匿名写入并保留只读迁移能力。

revoke insert, update, delete on table public.ot_records from anon;
grant select on table public.ot_records to anon;

drop policy if exists "Public can upload OT photos" on storage.objects;
drop policy if exists "Public can delete OT photos" on storage.objects;

-- 若已有 ot_records RLS 策略，请在 Dashboard 再确认 anon 只剩 SELECT 策略。
