# 更新日志

## [Unreleased]

### 新增
- 暂无

### 修复
- 暂无

---

## e3459e3 - 2026-05-27

### 安全修复

- **XSS 漏洞**：用户输入的 memo 文本在渲染时使用 `textContent` 替代 `innerHTML`
- **删除双倍返还漏洞**：删除记录时先删数据库再返还余额，防止重试时重复加回

### 功能性修复

- **离线队列数据丢失**：`initApp()` 启动时立即调用 `syncPendingOps()` 恢复离线操作
- **错误静默吞没**：`syncPendingOps` 的 catch 改为 `console.warn` 输出错误信息
- **离线横幅文案错误**：从"离线"改为"部分功能受限"，并标注数据来源
- **时区解析异常**：`parseDate` 改用 `parseISO` 并增加守卫判断
- **加载状态缺失**：表单提交和删除操作显示 loading 反馈（`withLoading`）
- **localStorage 版本迁移**：`getCached`/`setCached` 增加 `cache_version` 校验，版本不匹配时自动清缓存
- **SW 更新检测**：Service Worker 检测到新版本时显示"新版本可用"刷新横幅；CACHE_NAME 加时间戳防止缓存穿透
- **内联 onclick**：删除按钮改为 `data-delete-btn` 属性 + `addEventListener` 绑定

### 其他

- 新增 `CLAUDE.md`（AI 开发规范）、`README.md`（人类使用文档）
- `fetchRecords` 统一使用 `getCached`/`setCached` 路径

---

## f375657 - 2026-05-27

### 修复

- **调休核销不受 18:00 限制**：调休记录不校验结束时间，允许录入如 8:30~17:00 的正常工作时间

---

## 02f9391 - 2026-05-27

### 修复

- **时长计算改为向下取整到 0.5h**：加班到 18:31/18:44 不再被错误记为 2h（现为 1.5h）
- **新增规则**：加班结束时间必须 ≥ 18:00 才计入时长

---

## fd88de7 - 2026-05-27

### 修复

- **时长取整改为向上取整到 0.5h**：不满 0.5h 的部分按 0.5h 计算

---

## f9c690d - 2026-05-27

### 新增

- PNG 应用图标（适配主屏幕）
- favicon、Apple Touch Icon 引用
- manifest.webmanifest 改用 PNG 图标，支持 maskable

---

## 3516b27 - 2026-05-27

### 新增

- Service Worker 支持
- 离线缓存策略
- PWA 可安装

---

## 2f12b1c - 2026-05-27

### 新增

- 加班/调休记录 CRUD
- Supabase 数据同步
- FIFO 核销逻辑
- 统计分析仪表盘
- 加班时长计算（含午休扣减、最小 0.5h）
- 四种状态管理：待核销 / 部分核销 / 已结清 / 已调休

---

## 3f520e7 - 2026-05-27

### 新增

- 项目初始化
