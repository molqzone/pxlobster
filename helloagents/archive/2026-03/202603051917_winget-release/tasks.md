# 任务清单: winget-release

> **@status:** completed | 2026-03-05 19:27

目录: `helloagents/plan/202603051917_winget-release/`

---

## 任务状态符号说明

| 符号 | 状态 | 说明 |
|------|------|------|
| `[ ]` | pending | 待执行 |
| `[√]` | completed | 已完成 |
| `[X]` | failed | 执行失败 |
| `[-]` | skipped | 已跳过 |
| `[?]` | uncertain | 待确认 |

---

## 执行状态
```yaml
总任务: 7
已完成: 7
完成率: 100%
```

---

## 任务列表

### 1. 资产与元数据确认

- [√] 1.1 确认 Windows Release 资产 SHA256 与可执行文件名
  - 验证: ZIP 解压后存在 `pxlobster-windows-x86_64.exe`

- [√] 1.2 确认包标识、发布者、版本、架构与命令别名
  - 验证: 与 Release/README 一致（Publisher=molqzone，版本=0.2.0，架构=x64）

### 2. Manifest 生成

- [√] 2.1 生成 version manifest
  - 路径: `winget-manifests/manifests/m/molqzone/pxlobster/0.2.0/molqzone.pxlobster.yaml`

- [√] 2.2 生成 defaultLocale manifest
  - 路径: `winget-manifests/manifests/m/molqzone/pxlobster/0.2.0/molqzone.pxlobster.locale.en-US.yaml`

- [√] 2.3 生成 installer manifest（ZIP + nested portable）
  - 路径: `winget-manifests/manifests/m/molqzone/pxlobster/0.2.0/molqzone.pxlobster.installer.yaml`

### 3. 校验与交付

- [√] 3.1 执行清单字段自检（必要时运行 `winget validate`）
  - 验证: schema 字段完整、SHA256 匹配

- [√] 3.2 输出提交到 winget-pkgs 的 PR 步骤与注意事项
  - 验证: 用户可按步骤完成提交

---

## 执行备注

> 执行过程中的重要记录

| 任务 | 状态 | 备注 |
|------|------|------|
| 3.1 | completed | 已执行 winget validate，清单验证通过 |
| 3.2 | completed | 已整理 PR 提交步骤与注意事项 |
|------|------|------|