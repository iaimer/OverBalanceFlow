-- 年假与请假升级：先备份，审阅后人工执行。先执行同目录 supabase_cloud_ledger.sql。
-- 单人、无认证的既有账本：沿用 anon 访问，不新增多用户或权限体系。
-- 新表写入只允许本脚本 RPC 设置的事务上下文；所有 RPC 均为 SECURITY INVOKER。
begin;
create schema if not exists obf_private;
revoke all on schema obf_private from public;
grant usage on schema obf_private to anon;
alter table public.ot_records add column if not exists leave_reason text;

create table if not exists public.leave_calendar (
  date date primary key,
  is_day_off boolean not null,
  calendar_version text not null check (length(calendar_version) > 0)
);
create table if not exists public.annual_leave_records (
  id uuid primary key,
  start_date date not null,
  end_date date not null,
  slots jsonb not null check (jsonb_typeof(slots) = 'array' and jsonb_array_length(slots) > 0),
  reason text not null default '',
  created_at timestamptz not null,
  check (start_date <= end_date and extract(year from start_date) >= 2026
    and extract(year from start_date) = extract(year from end_date))
);
create index if not exists annual_leave_year_idx on public.annual_leave_records(start_date);
alter table public.leave_calendar enable row level security;
alter table public.annual_leave_records enable row level security;
revoke all on public.leave_calendar, public.annual_leave_records from public, anon;
grant select on public.leave_calendar to anon;
grant select, insert, update, delete on public.annual_leave_records to anon;
drop policy if exists obf_calendar_read on public.leave_calendar;
create policy obf_calendar_read on public.leave_calendar for select to anon using (true);
drop policy if exists obf_annual_read on public.annual_leave_records;
create policy obf_annual_read on public.annual_leave_records for select to anon using (true);
drop policy if exists obf_annual_write on public.annual_leave_records;
create policy obf_annual_write on public.annual_leave_records for all to anon
  using (current_setting('obf.ledger_write', true) = 'on')
  with check (current_setting('obf.ledger_write', true) = 'on');

-- 与 Flutter 2026.1 日历同源，存储全年每日数据；缺少任何一天即不支持该年登记。
insert into public.leave_calendar(date, is_day_off, calendar_version)
select day::date, case
  when day::date = any(array['2026-01-04','2026-02-14','2026-02-28','2026-05-09','2026-09-20','2026-10-10']::date[]) then false
  when day::date = any(array[
    '2026-01-01','2026-01-02','2026-01-03',
    '2026-02-15','2026-02-16','2026-02-17','2026-02-18','2026-02-19','2026-02-20','2026-02-21','2026-02-22','2026-02-23',
    '2026-04-04','2026-04-05','2026-04-06','2026-05-01','2026-05-02','2026-05-03','2026-05-04','2026-05-05',
    '2026-06-19','2026-06-20','2026-06-21','2026-09-25','2026-09-26','2026-09-27',
    '2026-10-01','2026-10-02','2026-10-03','2026-10-04','2026-10-05','2026-10-06','2026-10-07']::date[]) then true
  else extract(isodow from day) in (6,7) end, '2026.1'
from generate_series(date '2026-01-01', date '2026-12-31', interval '1 day') day
on conflict (date) do nothing;

-- 同一 SQL 语句返回快照，无分页上限或多表读取时间差。
create or replace function public.get_leave_ledger_snapshot()
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'records', coalesce((select jsonb_agg(to_jsonb(r) order by ot_date desc, created_at desc, id desc) from public.ot_records r), '[]'::jsonb),
    'annual_leave', coalesce((select jsonb_agg(to_jsonb(a) order by start_date desc, created_at desc, id desc) from public.annual_leave_records a), '[]'::jsonb),
    'calendar', coalesce((select jsonb_agg(to_jsonb(c) order by date) from public.leave_calendar c), '[]'::jsonb));
$$;

-- 验证客户端预览恰好覆盖范围内工作日，仅允许范围首末半天或单日半天。
create or replace function obf_private.check_annual_shape(payload jsonb)
returns void language plpgsql security invoker set search_path = public as $$
declare
  s date := (payload->>'start_date')::date;
  e date := (payload->>'end_date')::date;
  y integer := extract(year from s);
  raw jsonb := payload->'slots';
  expected jsonb;
  first_pm boolean;
  last_am boolean;
begin
  if s is null or e is null or s > e or y < 2026 or y <> extract(year from e)
    or raw is null or jsonb_typeof(raw) <> 'array' or jsonb_array_length(raw) = 0 then
    raise exception '年假日期或时段无效，跨年请分两次登记';
  end if;
  if (select count(*) from public.leave_calendar where date >= make_date(y,1,1) and date < make_date(y+1,1,1))
    <> make_date(y+1,1,1) - make_date(y,1,1) then
    raise exception '% 年完整日历尚未更新', y;
  end if;
  first_pm := exists(select 1 from jsonb_array_elements(raw) x where x->>'date' = s::text and x->>'period' = 'pm')
    and not exists(select 1 from jsonb_array_elements(raw) x where x->>'date' = s::text and x->>'period' = 'am');
  last_am := exists(select 1 from jsonb_array_elements(raw) x where x->>'date' = e::text and x->>'period' = 'am')
    and not exists(select 1 from jsonb_array_elements(raw) x where x->>'date' = e::text and x->>'period' = 'pm');
  select coalesce(jsonb_agg(jsonb_build_object('date', c.date::text, 'period', p.period) order by c.date,p.period), '[]'::jsonb)
    into expected from public.leave_calendar c cross join (values ('am'),('pm')) p(period)
    where c.date between s and e and not c.is_day_off
      and not (c.date = s and first_pm and p.period = 'am')
      and not (c.date = e and last_am and p.period = 'pm');
  if raw <> expected then raise exception '年假时段与工作日日历不一致，请重新预览'; end if;
end;
$$;

create or replace function obf_private.check_annual_ledger()
returns void language plpgsql security invoker set search_path = public as $$
declare annual_row public.annual_leave_records%rowtype;
begin
  for annual_row in select * from public.annual_leave_records loop
    perform obf_private.check_annual_shape(to_jsonb(annual_row));
  end loop;
  if exists(select 1 from public.annual_leave_records group by extract(year from start_date)
    having sum(jsonb_array_length(slots)) > 10) then raise exception '年假余额不足，每年最多 5 天'; end if;
  if exists(select 1 from public.annual_leave_records a, jsonb_array_elements(a.slots) s
    group by s->>'date', s->>'period' having count(*) > 1) then
    raise exception '年假时段重复';
  end if;
  if exists(select 1 from public.annual_leave_records a, jsonb_array_elements(a.slots) s, public.ot_records o
    where o.status = '已调休' and o.ot_date = (s->>'date')::date
      and o.start_time::time < case when s->>'period' = 'am' then time '11:30' else time '17:00' end
      and o.end_time::time > case when s->>'period' = 'am' then time '08:30' else time '12:00' end) then
    raise exception '年假与调休时段重叠';
  end if;
end;
$$;

create or replace function public.save_annual_leave_atomic(payload jsonb, allow_insert boolean)
returns void language plpgsql security invoker set search_path = public as $$
declare
  target_id uuid := (payload->>'id')::uuid;
  old public.annual_leave_records%rowtype;
  exists_before boolean;
begin
  perform pg_advisory_xact_lock(186542, 1);
  perform set_config('obf.ledger_write', 'on', true);
  select * into old from public.annual_leave_records where id = target_id for update;
  exists_before := found;
  if allow_insert is null or allow_insert = exists_before then
    raise exception '年假新增 ID 已存在或待编辑记录不存在，请刷新';
  end if;
  perform obf_private.check_annual_shape(payload);
  if allow_insert then
    insert into public.annual_leave_records(id,start_date,end_date,slots,reason,created_at)
    values(target_id,(payload->>'start_date')::date,(payload->>'end_date')::date,
      payload->'slots',coalesce(payload->>'reason',''),(payload->>'created_at')::timestamptz);
  else
    update public.annual_leave_records set start_date=(payload->>'start_date')::date,
      end_date=(payload->>'end_date')::date, slots=payload->'slots', reason=coalesce(payload->>'reason','')
    where id=target_id;
  end if;
  perform obf_private.check_annual_ledger();
end;
$$;

create or replace function public.delete_annual_leave_atomic(target_id uuid)
returns void language plpgsql security invoker set search_path = public as $$
begin
  perform pg_advisory_xact_lock(186542, 1);
  perform set_config('obf.ledger_write', 'on', true);
  delete from public.annual_leave_records where id=target_id;
  if not found then raise exception '年假记录不存在'; end if;
end;
$$;

create or replace function public.save_comp_leave_atomic(leave_record jsonb, deductions jsonb, allow_insert boolean)
returns void language plpgsql security invoker set search_path = public as $$
declare
  target_id uuid := (leave_record->>'id')::uuid;
  old public.ot_records%rowtype;
  source public.ot_records%rowtype;
  exists_before boolean;
  start_min numeric;
  end_min numeric;
  hours numeric;
  pending numeric;
  deduct numeric;
  actual jsonb := '[]'::jsonb;
  info text;
  new_date date := (leave_record->>'ot_date')::date;
  new_start time := (leave_record->>'start_time')::time;
  new_end time := (leave_record->>'end_time')::time;
begin
  perform pg_advisory_xact_lock(186542, 1);
  select * into old from public.ot_records where id=target_id for update;
  exists_before := found;
  if allow_insert is null or allow_insert = exists_before then raise exception '新增 ID 已存在或待编辑调休不存在'; end if;
  if exists_before and old.status <> '已调休' then raise exception '目标不是调休记录'; end if;
  if new_date is null or new_start is null or new_end is null or new_start >= new_end then raise exception '调休时间无效'; end if;
  start_min := extract(epoch from new_start)/60;
  end_min := case when new_end=time '23:59' then 1440 else extract(epoch from new_end)/60 end;
  hours := end_min-start_min-greatest(0,least(end_min,720)-greatest(start_min,690));
  if hours <= 0 then raise exception '调休时间无效'; end if;
  hours := greatest(0.5, floor(hours/30)/2);
  if hours <= 0 or hours is null or leave_record->>'status' is distinct from '已调休'
    or (leave_record->>'duration')::numeric is distinct from -hours
    or (leave_record->>'total_hours')::numeric is distinct from -hours
    or (leave_record->>'remaining_hours')::numeric is distinct from 0 then raise exception '调休时长与时间段不一致'; end if;
  if exists(select 1 from public.annual_leave_records a, jsonb_array_elements(a.slots) s
    where (s->>'date')::date=new_date
      and new_start < case when s->>'period'='am' then time '11:30' else time '17:00' end
      and new_end > case when s->>'period'='am' then time '08:30' else time '12:00' end) then
    raise exception '调休与年假时段重叠';
  end if;
  if exists_before and old.duration = -hours then
    if deductions is distinct from old.memo::jsonb or (leave_record->>'memo')::jsonb is distinct from deductions then
      raise exception '核销明细已变化，请重新预览';
    end if;
    update public.ot_records set ot_date=new_date, start_time=to_char(new_start,'HH24:MI'),
      end_time=to_char(new_end,'HH24:MI'), leave_reason=coalesce(leave_record->>'leave_reason','') where id=target_id;
    return;
  end if;
  if exists_before then perform public.delete_ot_record_atomic(target_id); end if;
  pending := hours;
  for source in select * from public.ot_records where status <> '已调休' and remaining_hours>0
    order by ot_date, created_at, id for update loop
    exit when pending<=0;
    deduct := least(source.remaining_hours,pending);
    info := format('%s(%s-%s) 余额:%sh', source.ot_date, left(source.start_time::text,5), left(source.end_time::text,5), to_char(source.remaining_hours,'FM999999990.0'));
    actual := actual || jsonb_build_array(jsonb_build_object('id',source.id,'deduct',deduct,'info',info));
    update public.ot_records set remaining_hours=remaining_hours-deduct,
      status=case when remaining_hours-deduct<=0 then '已结清' else '部分核销' end where id=source.id;
    pending := pending-deduct;
  end loop;
  if pending>0 then raise exception '调休余额不足，还差 % 小时', pending; end if;
  -- info 为展示快照，不作为并发依据；来源 UUID、顺序与金额必须与预览一致。
  if (select jsonb_agg(jsonb_build_object('id',x->>'id','deduct',(x->>'deduct')::numeric) order by n)
      from jsonb_array_elements(actual) with ordinality a(x,n)) is distinct from
     (select jsonb_agg(jsonb_build_object('id',x->>'id','deduct',(x->>'deduct')::numeric) order by n)
      from jsonb_array_elements(deductions) with ordinality a(x,n)) then
    raise exception '余额或 FIFO 来源已变化，请重新预览';
  end if;
  insert into public.ot_records(id,ot_date,start_time,end_time,duration,total_hours,remaining_hours,status,memo,leave_reason,created_at)
    values(target_id,new_date,to_char(new_start,'HH24:MI'),to_char(new_end,'HH24:MI'),-hours,-hours,0,'已调休',actual::text,
      coalesce(leave_record->>'leave_reason',''),case when exists_before then old.created_at else (leave_record->>'created_at')::timestamptz end);
end;
$$;

-- 旧入口也必须遵守足额核销和年假冲突校验。
create or replace function public.reconcile_ot_atomic(leave_record jsonb, deductions jsonb)
returns void language plpgsql security invoker set search_path=public as $$
begin perform public.save_comp_leave_atomic(leave_record,deductions,true); end;
$$;

-- ZIP 恢复按 UUID 合并两类账本，在一次事务内验证最终余额与引用。
create or replace function public.restore_leave_ledger_atomic(records jsonb, annual_records jsonb)
returns void language plpgsql security invoker set search_path=public as $$
declare r public.ot_records%rowtype; detail jsonb; expected numeric;
begin
  perform pg_advisory_xact_lock(186542, 1);
  perform set_config('obf.ledger_write', 'on', true);
  if records is null or annual_records is null or jsonb_typeof(records)<>'array' or jsonb_typeof(annual_records)<>'array' then
    raise exception '恢复数据格式无效';
  end if;
  insert into public.ot_records(id,ot_date,start_time,end_time,duration,total_hours,remaining_hours,status,memo,photo_path,created_at,leave_reason)
    select id,ot_date,start_time,end_time,duration,total_hours,remaining_hours,status,memo,photo_path,created_at,leave_reason
      from jsonb_populate_recordset(null::public.ot_records,records)
    on conflict(id) do update set ot_date=excluded.ot_date,start_time=excluded.start_time,end_time=excluded.end_time,
      duration=excluded.duration,total_hours=excluded.total_hours,remaining_hours=excluded.remaining_hours,status=excluded.status,
      memo=excluded.memo,photo_path=excluded.photo_path,created_at=excluded.created_at,leave_reason=excluded.leave_reason;
  insert into public.annual_leave_records(id,start_date,end_date,slots,reason,created_at)
    select id,start_date,end_date,slots,coalesce(reason,''),created_at from jsonb_populate_recordset(null::public.annual_leave_records,annual_records)
    on conflict(id) do update set start_date=excluded.start_date,end_date=excluded.end_date,
      slots=excluded.slots,reason=excluded.reason,created_at=excluded.created_at;
  for r in select * from public.ot_records loop
    if r.duration is null or r.total_hours is distinct from r.duration or r.status is null
      or r.status not in ('已调休','待核销','部分核销','已结清') then raise exception '恢复账本状态或时长无效'; end if;
    if r.status='已调休' then
      if r.duration>=0 or r.remaining_hours<>0 or jsonb_typeof(r.memo::jsonb)<>'array' then raise exception '调休存根无效'; end if;
      expected:=0;
      for detail in select value from jsonb_array_elements(r.memo::jsonb) loop
        if (detail->>'deduct')::numeric is null or (detail->>'deduct')::numeric<=0 or
          not exists(select 1 from public.ot_records o where o.id=(detail->>'id')::uuid and o.status<>'已调休') then
          raise exception '恢复核销引用无效';
        end if;
        expected:=expected+(detail->>'deduct')::numeric;
      end loop;
      if expected<>-r.duration then raise exception '调休核销总额不一致'; end if;
    else
      select r.duration-coalesce(sum((x->>'deduct')::numeric),0) into expected
        from public.ot_records l cross join lateral jsonb_array_elements(case when l.status='已调休' then l.memo::jsonb else '[]'::jsonb end) x
        where x->>'id'=r.id::text;
      if r.duration<=0 or r.remaining_hours is distinct from expected or expected<0 or expected>r.duration or
        r.status<>(case when expected=0 then '已结清' when expected=r.duration then '待核销' else '部分核销' end) then
        raise exception '恢复加班余额与核销历史不一致';
      end if;
    end if;
  end loop;
  perform obf_private.check_annual_ledger();
end;
$$;

revoke all on all functions in schema obf_private from public;
grant execute on all functions in schema obf_private to anon;
revoke all on function public.get_leave_ledger_snapshot() from public;
revoke all on function public.save_annual_leave_atomic(jsonb,boolean) from public;
revoke all on function public.delete_annual_leave_atomic(uuid) from public;
revoke all on function public.save_comp_leave_atomic(jsonb,jsonb,boolean) from public;
revoke all on function public.restore_leave_ledger_atomic(jsonb,jsonb) from public;
grant execute on function public.get_leave_ledger_snapshot(), public.save_annual_leave_atomic(jsonb,boolean),
  public.delete_annual_leave_atomic(uuid), public.save_comp_leave_atomic(jsonb,jsonb,boolean),
  public.restore_leave_ledger_atomic(jsonb,jsonb) to anon;
notify pgrst, 'reload schema';
commit;
