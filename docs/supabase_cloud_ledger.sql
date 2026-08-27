-- 先在 Supabase SQL Editor 审阅，再人工执行。
-- 保证删除调休存根和返还余额属于同一 PostgreSQL 事务。

-- 新增或编辑加班记录：服务端重检同日时间重叠，并保留已核销小时数。
-- 日常新增和编辑都应使用此 RPC，不要用普通 upsert 绕过校验。
-- ZIP 恢复是经过 manifest、哈希和账本校验的受控合并例外，仍由恢复流程调用 upsert。
-- allow_insert=true 仅用于新增；编辑必须传 false，目标不存在时会失败，
-- 防止过期缓存把已经删除的记录悄悄重新插入。
drop function if exists public.save_ot_record_atomic(jsonb);
create or replace function public.save_ot_record_atomic(
  payload jsonb,
  allow_insert boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  target public.ot_records%rowtype;
  target_id uuid;
  new_date date;
  new_start time;
  new_end time;
  new_duration numeric;
  new_memo text;
  new_created_at timestamptz;
  consumed numeric;
  new_remaining numeric;
  conflict_label text;
  target_exists boolean;
begin
  if payload is null
    or payload->>'id' is null
    or payload->>'ot_date' is null
    or payload->>'start_time' is null
    or payload->>'end_time' is null
    or payload->>'duration' is null
    or payload->>'created_at' is null
  then
    raise exception '加班记录缺少必填字段';
  end if;

  begin
    target_id := (payload->>'id')::uuid;
    new_date := (payload->>'ot_date')::date;
    new_start := (payload->>'start_time')::time;
    new_end := (payload->>'end_time')::time;
    new_duration := (payload->>'duration')::numeric;
    new_created_at := (payload->>'created_at')::timestamptz;
  exception when invalid_text_representation or datetime_field_overflow then
    raise exception '加班记录字段格式无效';
  end;

  if new_date is null
    or new_start is null
    or new_end is null
    or new_duration is null
    or new_created_at is null
    or new_start >= new_end
    or new_duration <= 0
    or new_duration * 2 <> trunc(new_duration * 2)
  then
    raise exception '加班记录时间或时长无效';
  end if;

  new_memo := coalesce(payload->>'memo', '');

  -- 同一天的写入串行化，避免两个并发请求同时通过重叠检查。
  perform pg_advisory_xact_lock(hashtext(new_date::text));

  select * into target
  from public.ot_records
  where id = target_id
  for update;
  target_exists := found;

  if allow_insert is null then
    raise exception '必须明确指定新增或编辑模式';
  end if;
  if target_exists and allow_insert then
    raise exception '新增记录 ID 已存在';
  end if;
  if not target_exists and not allow_insert then
    raise exception '待编辑记录不存在，请刷新后重试';
  end if;

  if target_exists then
    if target.status = '已调休' then
      raise exception '调休记录不能编辑';
    end if;
    if target.duration <= 0
      or target.remaining_hours < 0
      or target.remaining_hours > target.duration
    then
      raise exception '原加班记录余额无效';
    end if;
    consumed := target.duration - target.remaining_hours;
    if new_duration < consumed then
      raise exception '新的时长不能少于已核销时长';
    end if;
    new_remaining := new_duration - consumed;
  else
    new_remaining := new_duration;
  end if;

  select format('%s %s–%s', candidate.ot_date, candidate.start_time, candidate.end_time)
    into conflict_label
  from public.ot_records candidate
  where candidate.id <> target_id
    and candidate.status <> '已调休'
    and candidate.ot_date = new_date
    and candidate.start_time::time < new_end
    and candidate.end_time::time > new_start
  order by candidate.start_time::time, candidate.end_time::time, candidate.id
  limit 1;

  if conflict_label is not null then
    raise exception '加班时间段与已有记录重叠：%', conflict_label;
  end if;

  if target_exists then
    update public.ot_records
    set ot_date = new_date,
        start_time = to_char(new_start, 'HH24:MI'),
        end_time = to_char(new_end, 'HH24:MI'),
        duration = new_duration,
        total_hours = new_duration,
        remaining_hours = new_remaining,
        status = case
          when new_remaining <= 0 then '已结清'
          when consumed > 0 then '部分核销'
          else '待核销'
        end,
        memo = new_memo
    where id = target_id;
  else
    insert into public.ot_records (
      id, ot_date, start_time, end_time, duration, total_hours,
      remaining_hours, status, memo, photo_path, created_at
    ) values (
      target_id,
      new_date,
      to_char(new_start, 'HH24:MI'),
      to_char(new_end, 'HH24:MI'),
      new_duration,
      new_duration,
      new_remaining,
      '待核销',
      new_memo,
      nullif(payload->>'photo_path', ''),
      new_created_at
    );
  end if;
end;
$$;

revoke all on function public.save_ot_record_atomic(jsonb, boolean) from public;
grant execute on function public.save_ot_record_atomic(jsonb, boolean) to anon;

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
