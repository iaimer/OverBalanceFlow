# AGENTS.md — AI 开发规范

## 一句话

个人加班调休 Android 应用。Supabase 保存权威账本，Flutter + SQLite 提供离线只读缓存；旧 Web 位于 `legacy_web/`，只用于审计。

## 文件职责

| 路径 | 职责 |
|---|---|
| `lib/domain/` | 记录模型、时长规则、FIFO、节假日 |
| `lib/data/` | Supabase 云端仓库、SQLite 缓存、指纹、备份恢复 |
| `lib/ui/` | 记加班、记调休、统计、设置四入口 |
| `test/` | 业务、数据库事务、备份恢复回归测试 |
| `legacy_web/` | 原 PWA 完整归档，迁移完成前不得删除 |

## 绝对数据安全约束

- 所有业务写入必须由 Supabase 确认成功后再刷新 SQLite 缓存；断网不得伪装写入成功。
- 禁止启动失败后自动清库、重建空库或用远端空结果覆盖有效缓存。
- 调试 flavor 固定为 `org.femkits.overbalanceflow.debug`，正式 flavor 固定为 `org.femkits.overbalanceflow`。
- 云端同步必须完整获取后再事务替换缓存；远端空结果不得覆盖已有缓存。
- schema 升级必须显式实现事务迁移并创建恢复点；当前未知版本直接失败。
- 核销和删除返还必须通过 PostgreSQL RPC 在单一远端事务内完成。
- ZIP 恢复必须先验证 manifest、逐文件哈希和照片引用，再按 UUID 合并到 Supabase。
- `.migration-baselines/` 含真实历史，只能本机只读保存，永不提交 Git。
- 涉及 Supabase RPC、RLS 或 Storage policy 的 SQL 只能审阅后人工执行，禁止测试代码写生产数据。

## 关键业务规则

- 工作日结束时间必须不早于 18:00，从 17:00 起算；休息日跳过这两项限制。
- 时长向下取整至 0.5h，最小 0.5h；跨 11:30–12:00 扣除午休。
- FIFO 按 `ot_date`、`created_at`、UUID 升序稳定排序，必须先预览再执行。
- 状态仅允许：`待核销 | 部分核销 | 已结清 | 已调休`。
- 调休存根 `duration/total_hours` 为负数，`memo` 保持 `{id,deduct,info}` 数组。
- 记加班页显示最近两条非调休记录；完整历史位于统计页。
- 记加班固定使用珊瑚橙主题，记调休固定使用深青主题；不要用单一主题色抹平业务差异。

## 开发命令

```bash
flutter pub get
flutter test
flutter analyze
flutter run --flavor debugging
flutter build apk --debug --flavor debugging
```

最低 Android API 26。release keystore 和 `android/key.properties` 永不提交。
