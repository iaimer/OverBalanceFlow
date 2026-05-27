# OverBalanceFlow — Design

## Principles

- **Quiet utility**: 不喧哗，不装饰。核心功能一目了然
- **Offline-resilient**: 网络差时看着也像正常 app，不展示崩溃痕迹
- **One screen at a time**: 当前视图只聚焦一个任务（记加班 / 核销 / 看列表）
- **Durability over delight**: 动效和视觉锦上添花，但永远不牺牲数据安全和可读性

## Visual Direction

### Typography
- System font stack (`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif`)
- Monospace for time display (`ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`)
- Single type scale: `text-sm` / `text-base` / `text-lg` / `text-xl` / `text-2xl`

### Color
Muted neutral palette — one accent color for interaction, one semantic color per state.

| Token | Usage | Value |
|-------|-------|-------|
| `--bg` | Page background | `#f5f5f4` (stone-50) |
| `--surface` | Card / form | `#ffffff` |
| `--border` | Dividers, input borders | `#e7e5e4` (stone-200) |
| `--text-primary` | Body | `#1c1917` (stone-900) |
| `--text-secondary` | Labels, hints | `#78716c` (stone-500) |
| `--accent` | Primary action, focus | `#2563eb` (blue-600) |
| `--accent-hover` | Hover state | `#1d4ed8` (blue-700) |
| `--success` | 已结清, positive states | `#059669` (emerald-600) |
| `--warning` | 部分核销, pending | `#d97706` (amber-600) |
| `--danger` | 待核销, delete actions | `#dc2626` (red-600) |

### Spacing
4px base unit. Common values: `4px 8px 12px 16px 20px 24px 32px 48px 64px`.

### Radius
- Cards / inputs: `8px`
- Badges / buttons: `6px`
- Modal: `12px`

### Shadows
- Card: `0 1px 2px rgba(0,0,0,0.05), 0 1px 3px rgba(0,0,0,0.1)`
- Elevated (modal): `0 4px 6px rgba(0,0,0,0.07), 0 10px 15px rgba(0,0,0,0.1)`

## Layout Architecture

```
┌─────────────────────────────────┐
│  Header (app name + sync icon)  │
├─────────────────────────────────┤
│                                 │
│  Tab bar: [记加班] [调休核销]     │
│           [记录列表] [统计]      │
│                                 │
│  ┌───────────────────────────┐  │
│  │  View container           │  │
│  │  (one view at a time)     │  │
│  │                           │  │
│  └───────────────────────────┘  │
│                                 │
└─────────────────────────────────┘
```

## Component Inventory

### Global
- `AppHeader` — app title + online status indicator
- `TabBar` — 4-tab navigation
- `OfflineBanner` — shown when offline (dismissible?)
- `LoadingSpinner` — inline or overlay
- `Toast` — ephemeral feedback

### Views
1. **OTForm** — date picker, time range (start-end), memo, submit
2. **ReconciliationForm** — date picker, time range, submit → FIFO result
3. **RecordList** — filterable/sortable table of all records
4. **StatsView** — summary: total OT / used / remaining

### Shared
- `DurationBadge` — colored badge showing hours + status
- `DeleteButton` — icon-only, with confirmation flow
- `MemoText` — user-provided text, rendered safely (no XSS)

## Interaction Patterns

- **Tab switch**: instant view swap, no animation (simplicity)
- **Form submit**: button shows `正在保存...` (withLoading), disables inputs
- **Delete**: confirm via alert before proceeding
- **Offline write**: visually identical to online — queue is transparent
- **Empty state**: "还没有记录" with suggestion to add one

## Future (light → upgraded)

- Dark mode
- View transition animations
- Drag-to-reorder in the FIFO approval dialog
- i18n / locale support
