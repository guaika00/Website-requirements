# PROJECT TRACKER V4 — 多项目需求协作平台

这是当前 `Website-requirements` 静态项目的升级包，适用于 GitHub + Vercel + Supabase。**和已有 Travel app 共用 Supabase，不会删除或修改旅行行程表、XICHA 注册 Hook。**

## 这次新增

- **运营 = 项目负责人**：可以负责多个项目、自己创建新项目、改项目名称、维护分类与需求、排序/加急/重点、安排开发与预计日期、撤回需求、更新进度和最终验收。
- **开发**：查看授权项目，修改「待开始 / 进行中 / 待验收」状态，标记阻塞，追加文字、完成链接与进度图片；不能覆盖运营的原始需求，也不能自己完成最终验收。
- **只读角色**：只能查看被分配的项目、历史与需求报表，可导出当前项目 CSV；不能写入、删除或上传。
- **全局管理员**：访问全部项目、分配运营负责人、归档项目、删除需求、所有日常操作。
- **新交互**：桌面和手机端项目切换、集中项目设置、抽屉详情、追加式时间线、固定的状态流转、手动排序/桌面拖动、CSV（包含最近反馈）、独立参考素材。

### 状态定义

1. **待开始** → 开发 **进行中** → 开发 **提交待验收**。
2. 运营验收 **已完成**，或填写原因 **退回修改**（进行中）。
3. **阻塞**为独立标记，可以与进行中并存；开启阻塞需要填写原因。
4. 「已完成」计入完成率；已撤回需求不计入完成率。原有 `todo/doing/done` 状态保留，V4 扩充 `review`。

## 四类角色和权限

| 功能 | admin | operator | developer | viewer |
|---|---|---|---|---|
| 查看授权项目 / 报表 / CSV | 是 | 是 | 是 | 是 |
| 查看所有项目（即使未分配） | 是 | 否 | 否 | 否 |
| 创建新项目 | 是 | 是 | 否 | 否 |
| 编辑所负责项目资料 | 是 | 是 | 否 | 否 |
| 授权开发或只读成员 | 是 | 是 | 否 | 否 |
| 任命 / 移除另一位运营负责人 | 是 | 否 | 否 | 否 |
| 归档 / 恢复项目 | 是 | 否 | 否 | 否 |
| 添加 / 编辑 / 撤回需求与分类 | 是 | 是 | 否 | 否 |
| 设置重点、加急、开发负责人、截止日期和顺序 | 是 | 是 | 否 | 否 |
| 更新开发状态、阻塞和备注 | 是 | 是 | 是 | 否 |
| 提交待验收 | 是 | 是 | 是 | 否 |
| 最终验收已完成 / 退回修改 | 是 | 是 | 否 | 否 |
| 追加进度截图或完成链接 | 是 | 是 | 是 | 否 |
| 永久删除需求 | 是 | 否 | 否 | 否 |

**运营和开发可以同时属于多个项目，在不同项目拥有不同角色。** 全局角色存于 `team_members`（主要用于管理员以及创建项目资格），项目角色存于 `board_project_members`。RLS 以当前项目角色授权；前端只是交互层，不能替代数据库权限。

## 先确定你 Supabase 属于哪一种情况

到 Supabase SQL Editor 执行（安全、只读）：

```sql
SELECT to_regclass('public.board_projects') AS projects,
       to_regclass('public.board_categories') AS categories,
       to_regclass('public.board_project_members') AS project_members;
```

**情况 A：三个都是 `NULL`**（你之前的截图属于这种）。说明你仍是原单项目 V2 数据库。请运行 **`supabase/install_v4_from_v2.sql`**：它将 V3 项目模型和 V4 协作模型放到同一个事务中完成。它不是重建或清空数据库，也不需要运行旧版 `setup.sql`。

**情况 B：三个表都存在**，并且以前 V3 迁移已经完成。请只运行 **`supabase/upgrade_v4.sql`**。不要在已安装 V3 的数据库执行情况 A 的完整脚本。

**情况 C：仅部分表存在**：先停止操作，不要试图自己删除表；说明迁移状态不完整，应检查具体 SQL 错误后制定恢复方案。

### 生产升级步骤

1. **备份**：Supabase 备份原数据库；至少导出 `requirements`、`requirement_progress`、`team_members`、`board_assets`，并确认旧图片 Storage 仍在。重要项目建议先用测试环境演练。
2. **先升级 SQL**：在原来的 `Travel app` Supabase → SQL Editor → **New query**，粘贴情况 A 或 B 对应 SQL **完整内容**，不要仅执行选中某一行；从 `BEGIN;` 到 `COMMIT;` 一次点击 Run。若报错，整个事务回滚，保留旧表原状；把第一条 SQL 错误贴回来，**不要改用 DROP TABLE**。
3. **验证**：执行 `supabase/verify_v4.sql`，确认项目表、历史表和 5 个新的 RPC 函数存在。原有任务应在默认「沃德丰网站」项目，老状态和旧备注仍在。
4. **再部署前端**：解压本项目，按目录覆盖 GitHub 仓库 `guaika00/Website-requirements` 中对应文件，提交到 `main`。Vercel 继续使用已有 `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY`，不需重新创建项目。Vercel 使用 `npm run build`，Output Directory 为 `public`。
5. **兼容只读成员注册**：如果你的 Supabase 仍使用此前的 `xicha_before_user_created` + `enforce_registration_code` 团队邮箱白名单，且之前执行过我们给的「团队注册兼容修复」，请额外执行 `supabase/allow_viewer_signup.sql`，它只在现有白名单中加入 `viewer`，不会开放旅行网站注册。脚本发现原函数与预期不一致会停止、回滚，切勿手动删除 Hook。
6. **测试账号**：管理员登录 → 项目设置 → 成员 → 添加运营负责人；运营创建第二个项目，添加一个开发和一个只读邮箱；测试另一个项目是否不可见。用只读用户直接请求别的项目 REST 接口也必须被 RLS 拒绝或返回空集。

### 注意几个关键点

- **不要运行** `supabase/setup.sql`：它是历史 V2 初始化文件，不是升级脚本。
- **不要再次导入旧版 Excel**，除非原数据库确实没有导入任务；迁移不会把本地 `.xlsx` 自动写入数据库。`seed/` 是原始备份，不会公开部署到 Vercel。若旧库空，可在迁移成功后用本地服务密钥运行 `npm run import:seed`，切勿把 `SUPABASE_SECRET_KEY` 提交到 GitHub 或填到公开前端。
- **旧版 JSON 导入入口已从主界面移除**，以免跨项目覆盖已有进度。
- **共用账号和注册限制**：旧旅行网站的 XICHA 注册码 Hook 仍然存在，V4 主迁移不会修改它。此前的团队免邀请码函数原本只允许 admin/operator/developer，**新 viewer 无法注册**；按上面步骤执行单独的 `allow_viewer_signup.sql`（必须先确认原注册兼容函数与预期一致），不要删除旅行网站 Hook。
- 图片放在私有 `requirements-private` Bucket；新文件存储在 `projects/{project_id}/uploads/` 下，按项目授权。不要把图片上传到公开 GitHub。
- 前端用 **每 20 秒授权查询**，避免依赖可能泄露 DELETE 元数据的跨项目广播。签名图片 URL 只短期有效；已产生的 URL 在到期前可能仍可访问。
- PostgreSQL 同一表的多条 permissive RLS Policy 可以合并放行，若你额外创建过同名业务表的自定义宽权限政策，必须通过 `verify_v4.sql` 检查并处理。
- 最新进度通过 `board_activity` **追加记录**；旧 `requirement_progress.note` 字段不会删除，历史旧备注仍可在时间线看到。CSV 会带最近的反馈和旧备注；若单项目反馈记录超过 1000 条，CSV 的“最近反馈”字段只能覆盖按时间倒序取到的前 1000 条（其他数据仍在数据库中）。

## 项目文件

```text
public/index.html             桌面与手机界面
public/style.css              布局与响应式样式
public/app.js                 Supabase 登录、授权数据读写、页面交互
public/config.js              Vercel 构建生成的前端公开配置（不含 secret）
supabase/install_v4_from_v2.sql  从 V2 直接升级的完整迁移（优先用于你之前的情况）
supabase/upgrade_v4.sql       已有 V3 时增量升级
supabase/verify_v4.sql        升级后只读检查
supabase/allow_viewer_signup.sql  只读角色注册的可选兼容 SQL
supabase/upgrade_multi_project.sql  历史 V3 迁移，仅参考，不要和 V4 SQL 混用
scripts/build-config.mjs      生成 Vercel 公开配置
scripts/import-seed.mjs       空需求库的本地一次性导入脚本（需要本地 service secret）
seed/                         原 Excel 的 19 条需求和 34 张参考图备份
```

## 已完成的验证、未完成的验证

- 完成：`node --check` JS 语法检查；使用模拟 Supabase 会话测试 admin/operator/developer/viewer 四种界面，任务列表、详情时间线、项目设置、手机端无横向溢出。
- **尚未完成**：在你的真实 Supabase 执行 SQL、逐角色验证数据库 RLS / Storage / RPC；Vercel 真实环境联调。上线前务必以测试账号验证。
