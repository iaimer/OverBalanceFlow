# 历史迁移与灾难恢复手册

## 不可违反的原则

1. 迁移只复制，不搬移、不清空、不覆盖 Supabase。
2. Android 校验完成前，旧 Web 和 Supabase 保持可恢复状态。
3. 调试只安装 `org.femkits.overbalanceflow.debug`，不得用调试 APK 覆盖正式版。
4. 任何 schema 升级、恢复和删除失败时，都不得用空库继续启动。

## 迁移前

1. 打开 `legacy_web/`，联网等待离线队列完成；浏览器 `localStorage.pending_ops` 必须为 `[]`，IndexedDB `pending_photos` 必须为空。
2. 重新执行只读基线导出，至少保存 `records.json`、照片、`manifest.json` 和 SHA-256。将目录设为只读并复制到两处独立介质。
3. 比较基线：记录数、UUID 集合、四类状态数量、总加班、总余额、照片数量与哈希。
4. 不执行 `legacy_web/freeze_supabase_read_only.sql`。

## Android 首次迁移

1. 构建 `production` flavor，并通过 `--dart-define` 注入仅用于读取的 URL/key，以及基线的 `BASELINE_RECORD_COUNT`、`BASELINE_RECORDS_SHA256`、`BASELINE_UUID_SHA256`、`BASELINE_PHOTO_COUNT`、`BASELINE_PHOTOS_JSON`。缺少任一参数时 App 会拒绝迁移。不要注入 service role 或 secret key。
2. App 分页 GET `ot_records`，照片写入暂存目录，记录写入暂存 SQLite。
3. App 比较全字段规范化 SHA-256、UUID、状态、总时长、余额，并逐张核对“记录 UUID → 原始路径 → 照片 SHA-256”；任何差异都会中止。
4. 成功后核对设置页迁移报告，并至少重启一次 App。
5. 导出 ZIP，重新导入做合并恢复演练，再核对统计与基线一致。
6. 用旧版测试 APK 写入夹具，覆盖安装新版，确认记录和照片仍存在。

## 冻结旧系统

只有在上述验证全部通过并由用户确认后，才可人工审阅并执行 `legacy_web/freeze_supabase_read_only.sql`。SQL 只撤销写权限并保留 SELECT，不删除表、行、bucket 或对象。旧 Web 继续保留在仓库中作为只读归档。

## 日常备份

- 每次大量录入、恢复或 APK 覆盖升级前导出 ZIP。
- ZIP 未加密，含备注和照片，应保存到可信位置。
- 只有 App 提示“已通过哈希校验”的 ZIP 才算成功备份。
- 至少保留手机外两份副本，不要只放在应用私有目录。

## 故障恢复

- 迁移失败：不要卸载旧 Web 或改 Supabase 权限；在 App 内重试。
- ZIP 校验失败：停止恢复，换用另一份备份；当前 SQLite 不会被清空。
- 恢复前会在应用私有目录生成包含数据库和全部照片的完整恢复点；同 UUID 被备份版本覆盖后，活动目录旧照片可清理，但恢复点副本继续保留。
- schema 升级失败：保留原 APK、数据库和升级前恢复点，不执行清库重装。
- 手机损坏或卸载：安装相同正式签名 APK，从最近已验证 ZIP 合并恢复。
- 统计不一致：立即停止新增和删除，导出当前 ZIP，分别比较基线、Supabase 和 Android 指纹。
