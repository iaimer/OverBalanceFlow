# 偷闲半日

云端优先的 Android 加班调休账本。Supabase 保存权威数据，Flutter + SQLite 提供离线只读缓存，ZIP 提供独立备份与云端恢复。

## 功能

- 四个入口：记加班、记调休、统计、设置
- 加班珊瑚橙、调休深青绿的双主题界面，可快速辨认当前业务页面
- 工作日/节假日加班时长规则与 FIFO 调休核销
- 相机或相册保存打卡照片
- 完整历史、核销明细、删除调休后的事务返还
- Supabase 云端读写、联网刷新与 SQLite 离线只读缓存
- ZIP 备份、SHA-256 校验、按 UUID 合并恢复和恢复前数据库/照片完整快照
- 自动判断工作日、国务院法定节假日和普通周末休息日

## 数据安全

Supabase 是权威账本；新增、FIFO 核销、删除和 ZIP 恢复只有在云端确认成功后才刷新 SQLite 缓存。断网时可以查看最后一次完整缓存和导出备份，但不会把未确认写入伪装为成功。调试版包名为 `org.femkits.overbalanceflow.debug`，正式版为 `org.femkits.overbalanceflow`，两者的缓存目录完全隔离。

迁移前只读基线保存在本机 `.migration-baselines/`，该目录被 Git 忽略。当前基线为 58 条记录、总加班 97.0h、余额 16.0h。不要把真实记录、Supabase key 或签名材料提交到 Git。

使用与 App 相同算法生成基线参数：

```bash
dart run tool/baseline_fingerprint.dart .migration-baselines/overbalanceflow-baseline-YYYYMMDD
```

详细步骤见 [迁移与灾难恢复手册](docs/MIGRATION_AND_RECOVERY.md)。

## 开发

```bash
flutter pub get
flutter test
flutter analyze
flutter run --flavor debugging
flutter build apk --debug --flavor debugging
```

运行时通过编译期参数注入 Data API 地址和 publishable/anon key：

```bash
flutter run --flavor debugging \
  --dart-define=SUPABASE_URL=https://PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

核销和删除依赖 [Supabase 原子 RPC](docs/supabase_cloud_ledger.sql)，必须先在 SQL Editor 审阅和部署；不得在客户端用多次普通请求模拟事务。

正式 APK 需要创建独立 release keystore，并在 `android/key.properties` 配置；这两个文件均被 Git 忽略。

## 目录

```text
lib/domain/       业务模型、时长和 FIFO 规则
lib/data/         Supabase 仓库、SQLite 缓存、指纹、备份恢复
lib/ui/           四入口 Material 界面
test/             业务、事务、备份恢复测试
legacy_web/       冻结前的完整 Web PWA
docs/             迁移与灾难恢复操作手册
```

首版支持 Android 8.0（API 26）及以上。
