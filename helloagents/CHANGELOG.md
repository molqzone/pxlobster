# 变更日志

## [Unreleased]

## [0.2.4] - 2026-03-12

### 修复
- **[发布流程]**: Windows 发布资产改为静态链接 libusb，并新增 hardlink 启动烟雾验证
  - 文件: build.zig, .github/workflows/release.yml, .github/workflows/ci.yml
  - 影响: 避免 portable 入口因缺少侧边 DLL 在启动前失败

### 文档
- **[文档]**: 明确 Windows 发布资产为自包含 EXE，Linux/macOS 仍需系统 libusb 运行库
  - 文件: README.md, README.en.md, helloagents/context.md

## [0.2.0] - 2026-03-05

### 新增
- **[发布清单]**: 添加 winget 发布清单（v0.2.0，ZIP portable）
  - 方案: [202603051917_winget-release](archive/2026-03/202603051917_winget-release/)
  - 决策: winget-release#D001(使用ZIP+portable作为Windows安装源)

## [0.1.0] - 2026-03-05

### 微调
- **[知识库]**: 初始化 HelloAGENTS 知识库结构（自动创建）
  - 类型: 微调（无方案包）
  - 文件: helloagents/INDEX.md
