# 23 · 团队协作与仓库设置

> 状态：当前方案（单仓、多人维护，2026-10-29 定）。
> 关联：`AGENTS.md` §0 团队基线、[`references/workflow.md`](../references/workflow.md)、
> [`.github/workflows/`](../.github/workflows/)。
> 多仓共享规则 / secrets 时再评估迁 org，见 §7。

## 1. 角色与权限

| 角色 | 建议 | 能做什么 |
|---|---|---|
| Owner / Admin | **至少 2 人** | 改仓库设置、加协作者、配 secrets |
| Maintain | 核心开发 | 合并 PR、管理 issue / release |
| Write | 日常开发 | 推分支、开 PR、跑 CI |
| Read | 设计 / 产品 | 看代码、提 issue |

- 每人使用自己的 GitHub 账号；**不共享账号、SSH key、PAT**。
- 至少两个 Admin，避免只有一个人能改设置（bus factor）。

## 2. 仓库设置（一次性）

1. **Settings → Collaborators and teams**：按上表加人。
2. **Settings → Branches → Protect `main`**：
   - Require a pull request before merging
   - Require approvals：1
   - Require status checks：`rules`
   - 不允许 bypass（含 admin）
   - 私有仓的分支保护取决于 GitHub 套餐；没有该能力时，先用 PR 模板 + 团队约定。
3. **Settings → Secrets and variables → Actions**：`TEAM_RULES_TOKEN`
   （对 `team-agent-template` 只读即可；公开仓可省略）。
4. **Settings → Actions → General**：允许 Actions；fork PR 默认不传 secrets。
5. 日常不直接 push `main`；hotfix 也走 PR。

> **当前状态（2026-10-29）**：
> - `scantool` 已转 **public**；分支保护已启用（PR + 1 approval + `rules` 检查），
>   `enforce_admins` 暂为 `false`，首个 `rules` 绿后改 `true`。
> - `TEAM_RULES_TOKEN` 已在 Actions secrets 添加；当前 PAT 无 secrets 读权限，
>   无法用 API 复核，首次 CI 验证。
> - 协作者邀请已发给 `davidtan2012`，**待对方接受**；接受后才会出现在协作者列表。
> - self-hosted runner 0 台；iOS CI 暂不需要。

## 3. 日常流程

1. 从 `main` 开分支：`feat/...`、`fix/...`、`docs/...`。
2. 改代码前读 `AGENTS.md` §4 与对应 `spec/<周期>/spec.md`。
3. 本地验证：`make test-ci`（或 `make test` + `make test-gate`）、`make check-docs`；
   涉及取景 / 还原的改动按 `device-acceptance.md` 跑真机。
4. 开 PR：用 [模板](../.github/pull_request_template.md) 填 spec/FR、验证、真机证据、
   白名单变化。
5. `rules` 必须绿；`ios`（自托管）按需手动跑（见 §5）。
6. 合并：squash merge；提交信息跟随仓库语言，不加 AI 署名。

## 4. 已知债门禁

- `make test-ci` 只拦**新增失败**与**总数下降**；白名单 `ci/known-failures.txt` 只准缩。
- 新增白名单必须在 PR 说明“为什么不是本轮回归”，由评审人核对。
- 修好一条既有债 → 从白名单删行；未命中的白名单项 CI 会警告，不失败（flaky）。

## 5. CI

| workflow | runner | 触发 | 内容 |
|---|---|---|---|
| [`rules`](../.github/workflows/rules.yml) | `ubuntu-latest` | push / PR | 团队基线同步 + 文档链接/索引 |
| [`ios`](../.github/workflows/ios.yml) | `[self-hosted, macOS, ios]` | 手动 `workflow_dispatch` | `make test-ci` + `make device-build` |

- `ios` 需要先注册 self-hosted runner，安装 Xcode 26.x 与 iOS 27 模拟器；
  仓库变量 `DEVELOPER_DIR` / `SIM_NAME` / `SIM_OS` 可覆盖默认值。
- GitHub 托管 macOS runner 通常没有 iOS 27 runtime，不要直接拿来跑。
- `TEAM_RULES_TOKEN` 缺失时，`rules` 跳过团队基线校验并输出 warning（不染红）；
  配置后自动恢复校验。当前 runner 数为 0。

## 6. 新成员 checklist

- [ ] 接受仓库邀请，开启 2FA
- [ ] clone 后跑 `make doctor`；`DEVELOPER_DIR` 指向本机 Xcode
- [ ] 确认模拟器 runtime；没有就用 `DEST_SIM` 覆盖
- [ ] 真机调试在 Xcode 配自己的 Development Team（`device-build` 免签名）
- [ ] 读 `AGENTS.md` §0~§7、[`docs/12`](12-handover.md) §0、[`docs/README.md`](README.md)
- [ ] 跑一次 `make test-ci`：预期 547 total / 10 条既有债 / 0 新增
- [ ] 读本文与 [`references/verification.md`](../references/verification.md)

## 7. 何时迁 org / 加 CODEOWNERS

触发条件（任一即可，不必提前做）：

- 第二个仓要共享团队规则、secrets 或 reusable workflows；
- 维护者 ≥5 人，或需要按目录强制 review；
- 项目成为公司资产，需要归属连续性 / 审计。

迁移成本：本地 remote、`rules.yml` 的 `repository:` 一行、`TEAM_RULES_TOKEN`、
分支保护；GitHub 会保留 history 并给旧地址做 redirect。

## 8. 迁 org（已决定：多仓前直接做）

> Team 按人计费；如果只有 public 仓，org Free 已含 public 仓分支保护。
> Team 主要买 private 仓保护、团队权限与审计。

前置：org 已创建并开通 Team；你是 owner；两个仓 admin。

1. 创建 org + 选择 Team：`https://github.com/organizations/plan`。
2. 建 team（如 `ios`）并加成员；`davidtan2012` 接受邀请后再加入。
3. 转移两个仓：Settings → General → Transfer ownership，或
   `gh api -X POST repos/davidtan2008/scantool/transfer -f new_owner=<org>`。
4. 更新本地 remote：`git remote set-url origin git@github.com:<org>/scantool.git`。
5. 改 `.github/workflows/rules.yml` 的 `repository:` 为 `<org>/team-agent-template`。
6. **重新添加 `TEAM_RULES_TOKEN`**：仓库转移**不会**带走 secrets。
7. 转移后复核分支保护；未保留就重新应用。
8. 更新文档里的 URL：`AGENTS.md` §0、本文件、`references/`。
9. 验证：`rules` / `docs` / `test-ci`。
10. 旧的 pending 邀请在转移后可能失效，需在 org 重发。

未触发前：**现有仓库 + collaborators 足够，不建 CODEOWNERS**。
