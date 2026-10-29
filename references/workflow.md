# SDD 工作流与周期索引

## 五阶段

```
spec.md（需求 + 验收标准 FR/SC） → plan.md（技术决策 D1~Dn） → tasks.md（任务拆解）
  → 实施（逐任务勾选） → 验证（含 device-acceptance.md 真机清单）
```

`spec/feature.json` 指向当前周期；新功能先建周期目录，再动代码。

## 当前周期

`spec/capture-envelope-tracking/`（P0.3 取景包络）。任务勾选同步到 `TODO.md`。

## 历史周期（证据归档，改前读对应目录）

`layout-engine` · `layout-restore` · `scan-fidelity` · `scan-edge-accuracy` ·
`live-edge-crop` · `overlay-frame-visibility` · `wysiwyg-crop` · `wps-parity-layout` ·
`agent-handover` · `case-b-sticky-v2` · `folded-page-capture` · `frame-truth` ·
`scan-enhance` · `guided-capture` · `page-preprocess` · `word-fidelity`。

真机清单在各周期 `device-acceptance.md`；结论以对应 `spec.md` 的 FR/SC 为准。

## 状态归属

| 信息 | 唯一位置 |
|---|---|
| 当前状态 / 下一步 / 不要做什么 | `docs/12-handover.md` §0 |
| 任务勾选 / 暂停项 / 测试债 | `TODO.md` |
| 测试总数基线 | `Makefile` + `ci/known-failures.txt` |
| 技术决策 | `spec/<周期>/plan.md` |
| 文档分级 | `docs/README.md` |

## 团队规则同步

项目 `AGENTS.md` 第 0 节由 `team-agent-template` 生成，不要手改：

```bash
python3 <team-agent-template>/scripts/sync_team_baseline.py --check AGENTS.md
```

团队规则更新后，先跑同目录的 `scripts/check_rules.py`，再同步到本项目；
CI 的 `.github/workflows/rules.yml` 会校验基线一致。
