# Session Log

## 2026-08-13 — Flutter Android 本地化迁移

### 讨论内容
将 Web PWA 转为四入口 Flutter Android 应用，并将调试过程中的历史记录零丢失作为首要约束。

### 决策 & 原因
- 根据最新需求调整为 Supabase 云端权威数据源；本地仅缓存和备份，避免多设备状态分叉。
- 使用 SQLite 和应用私有照片目录，避免日常依赖网络。
- Supabase 仅作为一次性只读迁移源；暂存全量校验后才写正式库。
- 调试/正式 flavor 包名隔离，避免调试 APK 覆盖正式数据。
- ZIP 使用普通未加密格式，但要求逐文件哈希、照片引用校验和数据库/照片完整恢复点。

### 改动文件清单
- 新建 Flutter/Android 工程、`lib/domain`、`lib/data`、`lib/ui` 和数据安全测试。
- 原 Web 完整移入 `legacy_web/`，新增只读冻结 SQL。
- 重写 README、PRODUCT、DESIGN、AGENTS，新增迁移恢复手册。

### 遇到的问题
- 修正 ZIP 默认携带临时根目录导致恢复找不到 manifest 的问题。
- 将测试 FFI 依赖锁定到无 native-assets hook 的兼容版本，Android APK 构建恢复正常。
- 云端模型调整后将 FIFO 核销与删除改为待部署 PostgreSQL 原子 RPC；客户端不再以本地成功代替云端确认。
- 发布前移除 Flutter 源码中的调试 Supabase key，统一改用 `--dart-define` 注入。

### 最终结果
- 22 项业务、事务、账本一致性、外部照片关联基线和备份恢复测试通过，静态分析零问题。
- `debugging` flavor APK 构建成功；生产历史只读基线为 58 条、97.0h、余额 16.0h。
- 设置页已精简，后续 UI 优化记录于 `PLAN.md`。
- UI 改用 Color Hunt `249D8F / E9C46A / E76F51 / FDF0D5` 参考色，形成加班珊瑚橙、调休深青绿的双主题；模拟器完成真实数据页面验证。
- 记加班照片操作已改为“拍照 / 相册”同一行等宽按钮，22 项测试和静态检查继续通过。


## 2026-07-08 — 加班打卡照片

### 背景
为加班记录增加打卡照片附件，移动端可拍照或从相册选图，离线可用。

### 完成内容
- **照片录入**: 表单新增文件选择（`accept="image/*" capture="environment"`），Canvas 压缩后上传
- **在线路径**: 先传 Supabase Storage（`ot-record-photos` 桶）再写记录，上传失败清理已传对象
- **离线路径**: 照片 blob 存 IndexedDB（`obf-photo-cache`），队列项携带 `pending_photo_id`，同步时先传照片再插记录，成功后清理本地 blob
- **展示**: 记录列表照片卡片（待同步/可查看）、点击放大预览
- **删除**: 删除记录后清理照片对象，失败入队 `photo-delete` 待同步
- **SQL**: 新增 `supabase_photo_storage.sql`（公开桶 + 匿名上传/删除策略）

### 决策
- 保持无认证模型，桶公开 + 匿名策略（SQL 注释明确提示 review before running）
- 图片压缩控制存储体积（最长边 1600px）

### 提交
a272ed8 — add overtime photo records

## 2026-05-28 — UI Redesign + Design Docs

### 背景
用户使用 impeccable skill 对 OverBalanceFlow 进行 UI 改版。通过 teach flow 建立了 PRODUCT.md 和 DESIGN.md。

### 完成内容
- **配色迭代**: blue (#2563eb) → amber (#b45309) → 土黄 (#a16207) → 暗金黄 (#b8860b) → 金色土黄 (#c49a2a)
- **统计页面重设计**: 从深色卡片 (#292524) 改为白底纸卡样式
- **加班页最近记录**: 记加班页面底部新增最近 2 条记录展示 (`renderRecentRecords()`)
- **设计文档**: 新增 PRODUCT.md（产品定义）、DESIGN.md（设计规范）
- **文档更新**: README.md / CHANGELOG.md / AGENTS.md 同步更新
- **移除 Tailwind CDN**: 全部样式迁移到自定义 style.css

### 设计决策
- register: product（个人工具，设计服务功能）
- Color strategy: Restrained（纸本色 #fafaf9 + 墨色 #292524 + 土黄 #c49a2a + 绿 #059669）
- Theme: 纸本/极简风（0 shadow 原则被撤销，保留圆角和阴影但突出 paper-ink 配色）
- Layout: 底部 Tab 栏，移动端优先，单列布局

### 技术变更
| 文件 | 变更 |
|------|------|
| style.css | 配色从 amber(#b45309) 改为 土黄(#c49a2a)，stats card 重写为白卡纸，新增 `.recent-item` 样式 |
| app.js | 新增 `renderRecentRecords()`，initApp 增加调用 |
| index.html | view-add 新增 `#recent-records` + `#recent-list` 容器 |
| README.md | 技术栈 Tailwind → 自定义 CSS，项目结构新增设计文档 |
| CHANGELOG.md | 新增 Unreleased 区段 |
| AGENTS.md | 更新 tech stack、文件职责、业务规则 |

### 待办
- 无

### 提交
396f336 — style: 纸本风格配色优化 + 统计页重设计 + 加班页最近记录

## 2026-05-28 — 周末/节假日加班规则修复

### 背景
用户录入 13:10-17:34 加班被拦截——工作日规则（17:00 截断 + 18:00 阈值）不应适用于周末和法定节假日。

### 修复内容
- **`parseDuration`** 新增 `isWeekend` 参数：跳过 17:00 起始截断和 18:00 结束阈值
- **`handleOTSubmit`** 录入时自动判断非工作日
- **节假日数据表** `HOLIDAYS`：2026 年法定节假日 + 调休补班一览
- **`checkHoliday(dateStr)`**: 先查节假日表，再判周末
- **`isWeekendDate(dateStr)`**: 周六/日判定

### 决策
- 节假日使用内嵌数据集（非 API），离线可用，每年手动更新
- 补班日（周末上班）通过 HOLIDAYS 表标记为 false

### 技术变更
| 文件 | 变更 |
|------|------|
| app.js | 新增 `HOLIDAYS`、`checkHoliday`、修改 `parseDuration`、修改 `handleOTSubmit` |

### 提交
8d6e8b2 — fix: 周末/节假日加班不受17:00截断和18:00阈值限制

## 2026-05-31 — 离线同步与 PWA 安全修复

### 讨论内容
- 审查单人使用的加班调休 PWA，排除当前不需要处理的多人认证方案
- 聚焦离线写入一致性、调休备注渲染和 Service Worker 部署路径

### 决策 & 原因
- 保留纯前端和 Supabase 匿名客户端架构，不引入新依赖
- 离线新增继续使用本地临时 ID，但同步成功后统一改写缓存、队列和调休存根引用
- 核销数据库级原子事务需要 Supabase RPC，本次仅完成前端可落地的失败检测和过期预览拦截

### 改动文件清单
| 文件 | 变更 |
|------|------|
| api.js | 临时 ID 唯一化、引用映射、依赖重放、同步错误保留队列 |
| app.js | 调休 memo 安全渲染、核销过期预览和写入失败处理、存根符号修正 |
| index.html | 更新横幅移除内联 `onclick` |
| sw.js | 相对路径缓存、Supabase SDK 离线缓存、缓存版本升级 |
| README.md / CHANGELOG.md / AGENTS.md | 同步更新项目文档 |

### 遇到的问题
- 模拟离线连续写入时发现 `Date.now()` 生成的本地 ID 可能碰撞
- 父新增同步失败时，依赖操作必须留队等待下一次重放

### 最终结果
- 离线新增后核销、离线新增后删除、同步失败保留队列、依赖延迟重放均通过模拟验证
- 页面、列表和最近记录通过浏览器冒烟测试，控制台无错误
