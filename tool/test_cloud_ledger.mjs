// 仅使用临时隔离 PostgreSQL。此程序没有生产 URL 或连接字符串入口。
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';
let db, cluster, client, directory;
if (process.env.EMBEDDED_POSTGRES_MODULE) {
  const { default: EmbeddedPostgres } = await import(process.env.EMBEDDED_POSTGRES_MODULE);
  directory = await mkdtemp(join(tmpdir(), 'obf-pg-test-'));
  const listener = createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  cluster = new EmbeddedPostgres({databaseDir: join(directory, 'db'), user: 'postgres',
    password: randomUUID(), port, persistent: false, postgresFlags: ['-h', '127.0.0.1'], onLog() {}, onError() {}});
  await cluster.initialise(); await cluster.start();
  client = cluster.getPgClient(); await client.connect();
  db = {exec: sql => client.query(sql), query: (sql, params) => client.query(sql, params)};
} else {
  const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
  db = new PGlite();
}
try {
  await db.exec(`CREATE ROLE anon; CREATE TABLE public.ot_records (
    id uuid PRIMARY KEY, ot_date date NOT NULL, start_time text NOT NULL, end_time text NOT NULL,
    duration numeric NOT NULL, total_hours numeric NOT NULL, remaining_hours numeric NOT NULL,
    status text NOT NULL, memo text NOT NULL DEFAULT '', photo_path text, created_at timestamptz NOT NULL);
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.ot_records TO anon;`);
  await db.exec(await readFile(new URL('../docs/supabase_cloud_ledger.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../docs/supabase_annual_leave.sql', import.meta.url), 'utf8'));
  await db.exec('SET ROLE anon');
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const annual = (n, start, end, slots) => ({id: id(n), start_date: start, end_date: end, slots,
    reason: '', created_at: '2026-01-01T00:00:00Z'});
  const slots = dates => dates.flatMap(date => ['am', 'pm'].map(period => ({date, period})));
  const save = r => db.query('SELECT public.save_annual_leave_atomic($1::jsonb,true)', [JSON.stringify(r)]);
  const first = annual(1, '2026-08-03', '2026-08-07', slots(['2026-08-03','2026-08-04','2026-08-05','2026-08-06','2026-08-07']));
  await save(first);
  await assert.rejects(save(annual(2, '2026-08-10','2026-08-10', slots(['2026-08-10']))), /年假余额不足/);
  assert.equal((await db.query('select count(*)::int as n from annual_leave_records')).rows[0].n, 1);
  await db.query('SELECT public.delete_annual_leave_atomic($1)', [id(1)]);
  await assert.rejects(save(annual(3,'2027-01-04','2027-01-04', slots(['2027-01-04']))), /完整日历/);

  await assert.rejects(save(annual(3,'2026-12-31','2027-01-01', slots(['2026-12-31']))), /跨年/);
  const half = annual(4,'2026-08-07','2026-08-10', [
    {date:'2026-08-07',period:'pm'}, {date:'2026-08-10',period:'am'}]);
  await save(half);
  await assert.rejects(save(annual(5,'2026-08-07','2026-08-07', slots(['2026-08-07']))), /重复/);
  await db.query('SELECT public.save_annual_leave_atomic($1::jsonb,false)',
    [JSON.stringify({...half, reason:'修正',slots:slots(['2026-08-07','2026-08-10'])})]);
  const snapshot = (await db.query('SELECT public.get_leave_ledger_snapshot() AS data')).rows[0].data;
  assert.equal(snapshot.calendar.length,365);
  assert.equal(snapshot.annual_leave[0].reason,'修正');
  await assert.rejects(db.query('INSERT INTO annual_leave_records(id,start_date,end_date,slots,created_at) VALUES($1,$2,$2,$3,now())',
    [id(99),'2026-08-11',JSON.stringify(slots(['2026-08-11']))]), /row-level security/);
  await db.query('SELECT public.delete_annual_leave_atomic($1)',[id(4)]);
  console.log('PASS 年假范围、半天、编辑、额度、未知日历、RLS 与快照完整性');

  const overtime = (n, date) => ({id:id(n),ot_date:date,start_time:'08:30',end_time:'11:30',
    duration:3,total_hours:3,remaining_hours:3,status:'待核销',memo:'',created_at:`${date}T00:00:00Z`});
  for (const r of [overtime(10,'2026-08-01'), overtime(11,'2026-08-02')]) {
    await db.query('SELECT public.save_ot_record_atomic($1,true)',[JSON.stringify(r)]);
  }
  const comp = (end, hours, date='2026-08-12') => ({id:id(12),ot_date:date,start_time:'08:30',end_time:end,
    duration:-hours,total_hours:-hours,remaining_hours:0,status:'已调休',memo:'[]',leave_reason:'',created_at:'2026-08-12T00:00:00Z'});
  const deductions = (hours) => [{id:id(10),deduct:Math.min(3,hours),info:''},
    ...(hours>3 ? [{id:id(11),deduct:hours-3,info:''}] : [])];
  const saveComp = (record, details, insert) => db.query('SELECT public.save_comp_leave_atomic($1,$2,$3)',
    [JSON.stringify(record),JSON.stringify(details),insert]);
  await saveComp(comp('11:30',3),deductions(3),true);
  await saveComp(comp('13:00',4),deductions(4),false);
  let after = (await db.query('SELECT public.get_leave_ledger_snapshot() AS data')).rows[0].data;
  assert.equal(after.records.find(r=>r.id===id(10)).remaining_hours,0);
  assert.equal(after.records.find(r=>r.id===id(11)).remaining_hours,2);
  await assert.rejects(saveComp(comp('17:00',8),deductions(8),false), /余额不足/);
  assert.deepEqual((await db.query('SELECT public.get_leave_ledger_snapshot() AS data')).rows[0].data,after);
  const saved = after.records.find(r=>r.id===id(12));
  await saveComp({...saved,leave_reason:'只改事由'},JSON.parse(saved.memo),false);
  after = (await db.query('SELECT public.get_leave_ledger_snapshot() AS data')).rows[0].data;
  assert.equal(after.records.find(r=>r.id===id(12)).memo,saved.memo);
  await assert.rejects(save(annual(20,'2026-08-12','2026-08-12',slots(['2026-08-12']))), /重叠/);
  await save(annual(21,'2026-08-13','2026-08-13',[{date:'2026-08-13',period:'am'}]));
  await assert.rejects(saveComp({...comp('10:30',2,'2026-08-13'),id:id(22)},
    [{id:id(11),deduct:2,info:''}],true),/重叠/);
  // 恢复两类账本必须同时成功；非法年假不能把调休事由改到一半。
  await assert.rejects(db.query('SELECT public.restore_leave_ledger_atomic($1,$2)',[
    JSON.stringify([{...after.records.find(r=>r.id===id(12)),leave_reason:'不应写入'}]),
    JSON.stringify([annual(23,'2026-08-13','2026-08-13',slots(['2026-08-13']))])]), /重复/);
  assert.equal((await db.query('SELECT leave_reason FROM ot_records WHERE id=$1',[id(12)])).rows[0].leave_reason,'只改事由');
  await db.query('SELECT public.delete_annual_leave_atomic($1)',[id(21)]);
  await db.query('SELECT public.delete_ot_record_atomic($1)',[id(12)]);
  assert.equal((await db.query('SELECT sum(remaining_hours)::int AS n FROM ot_records')).rows[0].n,6);
  const short={...comp('08:45',0.5,'2026-08-14'),id:id(24)};
  await saveComp(short,[{id:id(10),deduct:0.5,info:''}],true);
  await db.query('SELECT public.delete_ot_record_atomic($1)',[id(24)]);
  console.log('PASS 调休编辑 FIFO、余额不足回滚、双向冲突、跨表恢复回滚及删除返还');

  if (cluster) {
    const c1 = cluster.getPgClient(), c2 = cluster.getPgClient();
    await c1.connect(); await c2.connect();
    try {
      for (const c of [c1,c2]) await c.query('SET ROLE anon');
      await save(annual(30,'2026-08-03','2026-08-06',slots(['2026-08-03','2026-08-04','2026-08-05','2026-08-06'])));
      await c1.query('BEGIN'); await c2.query('BEGIN');
      await c1.query('SELECT public.save_annual_leave_atomic($1,true)',[JSON.stringify(annual(31,'2026-08-10','2026-08-10',slots(['2026-08-10'])))]);
      const second = c2.query('SELECT public.save_annual_leave_atomic($1,true)',
        [JSON.stringify(annual(32,'2026-08-11','2026-08-11',slots(['2026-08-11'])))])
        .then(()=>({ok:true}), error=>({error}));
      let waiting = false;
      for(let n=0;n<50;n++) {
        waiting = (await db.query("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND NOT granted) AS waiting")).rows[0].waiting;
        if(waiting) break;
        await new Promise(resolve=>setTimeout(resolve,20));
      }
      assert.equal(waiting,true,'第二个连接必须等待账本事务锁');
      await c1.query('COMMIT');
      const outcome=await second; assert.match(outcome.error?.message || '',/年假余额不足/);
      await c2.query('ROLLBACK');
      assert.equal((await db.query('SELECT sum(jsonb_array_length(slots))::int AS n FROM annual_leave_records')).rows[0].n,10);
      console.log('PASS 两个真实连接并发争用最后 1 天，等待锁后拒绝超额请求');
    } finally {
      await c1.query('ROLLBACK'); await c2.query('ROLLBACK'); await c1.end(); await c2.end();
    }
  } else console.log('SKIP 真实多连接并发，请使用 EMBEDDED_POSTGRES_MODULE 运行');
} catch (error) {
  console.error({message: error.message, code: error.code, position: error.position, where: error.where});
  process.exitCode = 1;
} finally {
  if (cluster) { await client.end(); await cluster.stop(); await rm(directory,{recursive:true,force:true}); }
  else await db.close();
}
