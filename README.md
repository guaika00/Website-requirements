# PROJECT TRACKER V4.1 — 加急置顶、列表直接调优先级、持续需求批次

这是 `guaika00/Website-requirements` 项目的 V4.1 更新。**只增加当前看板自己的表和字段，不重建 Supabase，不修改 Travel app 行程表或 XICHA 注册机制。**

## 业务模型

- 项目是一条长期业务线，例如「沃德丰网站」。项目可以一直使用，不必为每个月重新建项目。
- 项目下设**需求批次**（也可以理解为迭代轮次），例如「2026 年 10 月 · 第一批」「2026 年 11 月 · 第二批」。每条需求必须属于一个批次。
- 迁移前所有旧需求自动归入本项目的 **「初始需求（升级前）」**，原来的优先级、进度、负责人、附件和历史反馈保持不变。
- 默认进入**最新的进行中批次**。批次可以新增、改名、结束、重新开启。结束后仍能查看、编辑已有需求和导出报表，但不能新增/移动需求进入已结束批次。
- **批次内的显示顺序始终是：加急 → 重点 → 普通**，优先级右侧在任务列表里直接选择，不用进入需求编辑。
- 一个批次内，同一优先级里的手动执行顺序可通过桌面拖动（同组）、按钮「顺序」设定；拖动不允许跨优先级。新优先级立即生效。选择“最近更新”或“截止日期”只影响**同优先级内部**的排列，不会把普通任务排到加急前面。
- 「全部批次」按**最新批次在前 → 该批次加急、重点、普通**分组展示，防止几个月的需求混在一起。报表和 CSV 带批次名称；切换批次后统计也跟着变化。
- 原来的四角色权限不变：全局管理员/运营可以创建和管理批次、调整优先级；开发/只读可以切换批次、查看需求及报表，但不能编辑优先级。

## 正确升级顺序（非常重要）

### 第 0 步：先确认已成功安装 V4

在 Supabase 的 **Travel app** SQL Editor 运行：

```sql
SELECT to_regclass('public.board_projects') AS projects,
       to_regclass('public.board_activity') AS activity,
       to_regclass('public.requirements') AS requirements;
```

必须全部不为 `NULL` 才能继续。**如果 V4 表还不存在**，先使用之前 V4 包内的 `install_v4_from_v2.sql` 或 `upgrade_v4.sql`，不要直接执行 V4.1 的迁移文件。

### 第 1 步：先备份，再升级数据库

1. 备份共享的 Supabase 数据库；至少导出 `requirements`、`requirement_progress`、`board_activity`、`board_projects`。确认你的 Travel app 数据仍在。建议先测试库试运行。
2. Supabase → SQL Editor → New query，打开 `supabase/upgrade_v41.sql`，**复制并一次执行整个文件（BEGIN 到 COMMIT）**。如果中途出错会回滚；不要跳着执行、不要删除任何旧表。
3. 运行 `supabase/verify_v41.sql`：表 `board_iterations` 应存在；`missing_iteration` / `mismatched_project` 应都等于 **0**；每个现有项目至少拥有一个「初始需求（升级前）」批次。
4. 如果 Supabase 提示表未出现在 API 缓存中，可以执行 `NOTIFY pgrst, 'reload schema';` 并等几秒。

### 第 2 步：再更新 GitHub 前端

将补丁 ZIP 中的文件，按相同相对目录**覆盖**到 `guaika00/Website-requirements` 仓库：

```text
public/app.js
public/index.html
public/style.css
supabase/upgrade_v41.sql
supabase/verify_v41.sql
README.md
```

提交到 `main`，Vercel 会自动构建部署。已有 `SUPABASE_URL`、`SUPABASE_PUBLISHABLE_KEY` 不需要修改。**切勿把 Supabase Secret Key 提交 GitHub。**

### 第 3 步：浏览器测试

1. 运营打开「需求批次」，旧需求应在「初始需求（升级前）」中，原状态不变。
2. 运营点击「新增批次」，例如建立「11 月 · 第二批」，新批次最初空白，新增需求默认归入该批。
3. 在需求卡片上，把一条普通需求改为「加急」，它应自动移到本批次任务列表顶部；不会影响其他批次。
4. 在同一优先级内点击「顺序」，选择组内的位置，刷新后应保留顺序。
5. 结束一批需求后，历史仍可查询，新的需求只放到进行中的批次。
6. 使用开发和只读账号检查：可查看批次和进度，**看不到优先级修改、批次创建按钮**。
7. 报表切换为「全部批次」时可看到跨批次汇总，导出 CSV 包含「需求批次」列。

## 技术与数据安全说明

- `board_iterations` 是新表，开启 RLS；**已授权项目成员才能读，只有 admin/operator 能创建/更新**，且没有客户端 DELETE 权限。
- `requirements.iteration_id` 是新增的非空 UUID 外键，使用 `project_id + iteration_id` 复合外键防止跨项目串批次。
- SQL 提供旧导入脚本兼容：当插入新需求没有指定 `iteration_id` 时，自动归入本项目最新进行中的批次；如果该项目全部批次已结束，会明确报错。
- 数据库排序 RPC `board_set_task_position` 改为仅重排**同项目、同批次、同优先级**任务，以免旧前端也把加急和普通任务交叉排序。
- 每次需求优先级调整、批次迁移继续通过 V4 的 `board_activity` 审计触发器追加历史，开发状态和备注数据仍在原表。
- **本次没有访问你的在线 Supabase**，SQL 完成了静态检查，网页经过模拟数据库的浏览器测试。真实数据库 RLS、迁移和并发写入应先在备份/测试环境校验，再在生产执行。

## 文件说明

- `supabase/upgrade_v41.sql` — V4 → V4.1 增量数据库迁移
- `supabase/verify_v41.sql` — 升级后只读检查
- `public/app.js`、`public/index.html`、`public/style.css` — 前端升级
- `supabase/install_v4_from_v2.sql`、`supabase/upgrade_v4.sql` — 历史 V4 安装路径，仅未安装 V4 的数据库使用
