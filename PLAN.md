# 项目开发计划

## 新需求与想法

- [ ] 继续优化 Flutter Android 四入口的视觉层级、间距、表单密度和状态反馈（2026-08-13）

## 当前状态

- Flutter Android 基本功能完成，Supabase 保存权威账本。
- SQLite 与照片目录用于离线缓存，ZIP 支持校验、导出和云端合并恢复。
- 2026 年工作日、法定节假日和普通周末自动判断。

## 发布前待办

- 人工审阅并部署 `docs/supabase_cloud_ledger.sql`。
- 配置独立 release keystore，完成正式 APK 覆盖升级测试。
- 完成真机写入、核销、删除、ZIP 恢复及断网缓存验收。
