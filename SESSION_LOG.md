# Session Log

## 2026-05-28 — UI Redesign + Design Docs

### 背景
用户使用 impeccable skill 对 OverBalanceFlow 进行 UI 改版。通过 teach flow 建立了 PRODUCT.md 和 DESIGN.md。

### 完成内容
- **配色迭代**: blue (#2563eb) → amber (#b45309) → 土黄 (#a16207) → 暗金黄 (#b8860b) → 金色土黄 (#c49a2a)
- **统计页面重设计**: 从深色卡片 (#292524) 改为白底纸卡样式
- **加班页最近记录**: 记加班页面底部新增最近 2 条记录展示 (`renderRecentRecords()`)
- **设计文档**: 新增 PRODUCT.md（产品定义）、DESIGN.md（设计规范）
- **文档更新**: README.md / CHANGELOG.md / CLAUDE.md 同步更新
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
| CLAUDE.md | 更新 tech stack、文件职责、业务规则 |

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
