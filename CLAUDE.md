# CLAUDE.md — AI 开发规范

## 一句话

加班调休统计 PWA。纯前端（Vanilla JS + Tailwind CDN + Supabase），无构建步骤，离线可用。

## 文件职责

| 文件 | 职责 | 注意 |
|------|------|------|
| `index.html` | UI 骨架 + 视图切换 + SW 注册 | 不写逻辑 |
| `app.js` | 渲染、表单、业务规则 | 所有 UI 逻辑 |
| `api.js` | Supabase CRUD + offline-first 队列 | 数据层唯一入口 |
| `sw.js` | 缓存策略 + sync 事件 | 不引用外部变量 |

## 关键业务规则（不可违反）

### 加班时长计算 `parseDuration()`
- 加班结束时间**必须 >= 18:00** 才计入（`isLeave=true` 时跳过）
- 时长向下取整到 0.5h，最小 0.5h
- 跨越 11:30~12:00 扣减 0.5h（午休）
- 时长 < 0 → 返回 0

### 核销 FIFO `handleReconciliation()`
- 按 `ot_date` 升序取有余额的记录，最早加班最先消费
- 创建"已调休"存根记录：`memo` 存 `JSON.stringify([{id, deduct, info}])`
- `duration` 存根记录为负值（`-totalDeducted`）
- 不能修改已入账的记录（除非删除返还）

### 删除顺序（不可逆转）
1. 先 `API.deleteRecord(id)` 删除记录本身
2. 如果失败**直接 return**，不修改任何余额
3. 删除成功后才执行余额返还逻辑
4. 这防止了**双倍返还漏洞**

### 状态枚举
`status` 只允许四种值：`待核销 | 部分核销 | 已结清 | 已调休`

### 数据路径
- `fetchRecords()` 在线成功时调 `setCached()`（统一版本管理）
- `fetchRecords()` 失败时调 `getCached()` 读缓存
- 所有离线写入走 `getCached()/setCached()`，含版本校验 `cache_version`

## 安全红线

- **永不**用 `innerHTML` 插入用户文本（memo）→ 用 `textContent` + DOM 方法
- 删除按钮绑 `data-delete-btn` + `addEventListener`，不拼字符串 onclick
- `syncPendingOps` 的 `catch` 必须 `console.warn`，不能空吞

## 数据库 `ot_records`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | uuid | PK |
| ot_date | date | 加班/调休日期 |
| start_time / end_time | time | 时间段 |
| duration | float | 计算后时长（调休存根为负） |
| total_hours | float | = duration |
| remaining_hours | float | 未消费余额 |
| status | text | 四种枚举值 |
| memo | text | OT=文本，调休=JSON 数组 |
| created_at | timestamp | 创建时间 |

## 离线策略

```
写入失败 → pushOp({type, record/id/remaining/status}) 入队 localStorage.pending_ops
恢复在线 → initApp() 调用 syncPendingOps() 逐条重放
SW sync 事件 → postMessage 通知页面 → 页面调用 syncPendingOps()
```

## 开发

```bash
npx serve .          # 纯静态，无需构建
node -c app.js       # 语法检查
```

## 部署

静态托管（GitHub Pages / Vercel），确保 `api.js` 中的 Supabase 凭据有效。
