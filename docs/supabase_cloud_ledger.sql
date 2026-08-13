-- 先在 Supabase SQL Editor 审阅，再人工执行。
-- 保证删除调休存根和返还余额属于同一 PostgreSQL 事务。

create or replace function public.delete_ot_record_atomic(target_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  target public.ot_records%rowtype;
  detail jsonb;
  source public.ot_records%rowtype;
  restored numeric;
begin
  select * into target from public.ot_records
  where id = target_id for update;
  if not found then raise exception '记录不存在'; end if;

  if target.status <> '已调休' and exists (
    select 1 from public.ot_records leave_record,
      jsonb_array_elements(coalesce(nullif(leave_record.memo, ''), '[]')::jsonb) item
    where leave_record.status = '已调休' and item->>'id' = target_id::text
  ) then
    raise exception '该加班已有核销历史，请先删除关联调休';
  end if;

  delete from public.ot_records where id = target_id;
  if target.status = '已调休' then
    for detail in select value from jsonb_array_elements(target.memo::jsonb)
    loop
      select * into source from public.ot_records
      where id = (detail->>'id')::uuid for update;
      if not found then raise exception '调休引用的原加班不存在'; end if;
      restored := source.remaining_hours + (detail->>'deduct')::numeric;
      if restored > source.duration then raise exception '返还后余额超过原始时长'; end if;
      update public.ot_records
      set remaining_hours = restored,
          status = case when restored >= duration then '待核销' else '部分核销' end
      where id = source.id;
    end loop;
  end if;
end;
$$;

revoke all on function public.delete_ot_record_atomic(uuid) from public;
grant execute on function public.delete_ot_record_atomic(uuid) to anon;

create or replace function public.reconcile_ot_atomic(
  leave_record jsonb,
  deductions jsonb
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  detail jsonb;
  source public.ot_records%rowtype;
  remaining numeric;
begin
  if jsonb_array_length(deductions) = 0
    or (leave_record->>'status') <> '已调休'
    or (leave_record->>'duration')::numeric >= 0
    or (leave_record->>'duration')::numeric <> (leave_record->>'total_hours')::numeric
  then
    raise exception '调休存根无效';
  end if;

  for detail in select value from jsonb_array_elements(deductions)
  loop
    select * into source from public.ot_records
    where id = (detail->>'id')::uuid for update;
    if not found then raise exception '原加班记录不存在'; end if;
    if source.status = '已调休' or source.remaining_hours < (detail->>'deduct')::numeric
    then raise exception '余额不足或记录类型无效'; end if;
    remaining := source.remaining_hours - (detail->>'deduct')::numeric;
    update public.ot_records
    set remaining_hours = remaining,
        status = case when remaining <= 0 then '已结清' else '部分核销' end
    where id = source.id;
  end loop;

  insert into public.ot_records (
    id, ot_date, start_time, end_time, duration, total_hours,
    remaining_hours, status, memo, photo_path, created_at
  ) values (
    (leave_record->>'id')::uuid,
    (leave_record->>'ot_date')::date,
    (leave_record->>'start_time')::time,
    (leave_record->>'end_time')::time,
    (leave_record->>'duration')::numeric,
    (leave_record->>'total_hours')::numeric,
    0, '已调休', leave_record->>'memo', null,
    (leave_record->>'created_at')::timestamptz
  );
end;
$$;

revoke all on function public.reconcile_ot_atomic(jsonb, jsonb) from public;
grant execute on function public.reconcile_ot_atomic(jsonb, jsonb) to anon;
