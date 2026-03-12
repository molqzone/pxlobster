# 变更提案: winget-release

## 元信息
```yaml
类型: 新功能
方案类型: implementation
优先级: P2
状态: 待执行
创建: 2026-03-05
```

---

## 1. 需求

### 背景
PXLobster 已发布 Windows 可用的 Release 资产，但尚未进入 winget，用户无法通过 Windows 包管理器安装。

### 目标
- 为 `molqzone/pxlobster` 的 `v0.2.0` 生成符合 winget 规范的 manifests
- 采用现有 Windows ZIP 资产作为 portable 安装源
- 提供可提交到 `winget-pkgs` 的文件与提交步骤

### 约束条件
```yaml
时间约束: 无
性能约束: 无
兼容性约束: 仅 Windows x64（现有 Release 资产）
业务约束: 仅使用官方 Release 资产与公开元数据
```

### 验收标准
- [ ] 生成 version / defaultLocale / installer 三份 manifest，字段完整且一致
- [ ] installer 使用 ZIP + nested portable，并包含正确 SHA256 与可执行文件路径
- [ ] 提供可直接提交至 winget-pkgs 的目录结构与 PR 步骤

---

## 2. 方案

### 技术方案
- 使用 winget 清单 schema（当前稳定版）生成三类 manifest
- installer 采用 `InstallerType: zip` + `NestedInstallerType: portable`，并设置 `PortableCommandAlias: pxlobster`
- 元数据来自 README 与 Release（名称、描述、许可证、主页、下载地址）

### 影响范围
```yaml
涉及模块:
  - 发布清单: 新增 winget manifests
预计变更文件: 3
```

### 风险评估
| 风险 | 等级 | 应对 |
|------|------|------|
| Release 资产变更或重发导致 SHA256 失效 | 中 | 以 Release URL 和现有 hash 为准，必要时重新计算更新 |
| ZIP 内可执行文件命名变化 | 中 | 先解压确认文件名，若变更则更新 NestedInstallerFiles |
| winget schema 版本变化 | 低 | 以官方 schema 文档为准，必要时调整字段 |

---

## 3. 技术设计（可选）

本次为清单生成任务，不涉及代码结构或 API 设计，暂不需要额外技术设计。

---

## 4. 核心场景

### 场景: 使用 winget 安装 PXLobster
**模块**: 发布清单
**条件**: 用户在 Windows 上执行 `winget install molqzone.pxlobster`
**行为**: winget 下载 ZIP 并注册 portable 命令别名
**结果**: 用户可直接运行 `pxlobster` CLI

---

## 5. 技术决策

### winget-release#D001: 使用 ZIP + portable 作为 Windows 安装源
**日期**: 2026-03-05
**状态**: ✅采纳
**背景**: 当前 Release 仅提供 `pxlobster-windows-x86_64.zip`，无独立 EXE 安装器
**选项分析**:
| 选项 | 优点 | 缺点 |
|------|------|------|
| A: ZIP + portable | 与现有 Release 资产一致，发布速度快 | 需要配置 NestedInstallerFiles/命令别名 |
| B: 等待 EXE 安装器 | 可简化清单 | 需要额外构建与发布流程 |
**决策**: 选择方案 A
**理由**: 当前资产已满足可执行发布需求，优先完成 winget 上架
**影响**: 仅影响发布清单字段，无代码改动