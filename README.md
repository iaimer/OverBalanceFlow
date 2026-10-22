# 偷闲半日

云端优先的 Android 加班调休账本。Supabase 保存权威数据，Flutter + SQLite 提供离线只读缓存，ZIP 提供独立备份与云端恢复。

## 功能

- 四个入口：记加班、记请假、统计、设置
- 加班珊瑚橙、调休深青绿的双主题界面，可快速辨认当前业务页面
- 工作日/节假日加班时长规则与 FIFO 调休核销
- 加班记录可编辑日期、时间和备注；同日重叠时间段会在保存前拦截
- 新增加班当天点击结束时间会默认定位当前时分；保存成功后表单会保留并锁定，修改后继续录入
- 相机或相册保存打卡照片
- 年假从 2026 年起每年 5 天，按整天或半天登记，年底过期；支持范围登记、休息日跳过和历史编辑
- 请假事由选填；年假与调休双向检查重叠，调休余额不足拒绝录入
- 统计页同一行独立显示可用调休小时与当前年度可用年假天数，规则说明通过 Tooltip 查看
- 完整历史、核销明细、请假编辑和删除后的事务返还
- Supabase 云端读写、联网刷新与 SQLite 离线只读缓存
- ZIP 备份、SHA-256 校验、按 UUID 合并恢复和恢复前数据库/照片完整快照
- 自动判断工作日、国务院法定节假日和普通周末休息日

## 数据安全

Supabase 是权威账本；新增、编辑、FIFO 核销、删除和 ZIP 恢复只有在云端确认成功后才刷新 SQLite 缓存。加班新增/编辑通过带重叠和余额校验的原子 RPC，编辑期间若检测到远端记录变化会要求重新打开。断网时可以查看最后一次完整缓存和导出备份，但不会把未确认写入伪装为成功。调试版包名为 `org.femkits.overbalanceflow.debug`，正式版为 `org.femkits.overbalanceflow`，两者的缓存目录完全隔离。

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

新增、编辑、核销和删除依赖 [Supabase 原子 RPC](docs/supabase_cloud_ledger.sql) 与 [年假升级 SQL](docs/supabase_annual_leave.sql)，必须先在 SQL Editor 审阅并人工部署；不得在客户端用多次普通请求模拟事务。部署顺序、备份兼容和本机并发测试见 [年假升级说明](docs/ANNUAL_LEAVE_UPGRADE.md)。

正式 APK 需要创建独立 release keystore，并在 `android/key.properties` 配置；这两个文件均被 Git 忽略。

正式构建使用本机 `.supabase.production.json`（Git 已忽略），内容为包含 `SUPABASE_URL` 与 `SUPABASE_PUBLISHABLE_KEY` 的 JSON 对象。仅使用 publishable 或 legacy anon 客户端密钥：

```bash
flutter build apk --release --flavor production \
  --dart-define-from-file=.supabase.production.json
```

正式构建缺少上述配置或使用非客户端密钥时会失败。交付前还应只读验证 `get_leave_ledger_snapshot`，并确认最终 APK 包含目标项目地址。

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
