# winget-manifests

## 职责

维护 Windows winget 发布清单（version / defaultLocale / installer），用于在 winget-pkgs 提交发布。

## 接口定义（可选）

本模块为静态清单，不提供运行时 API。

## 行为规范

### 清单更新
**条件**: 新版本 Release 或安装器变化
**行为**: 更新版本号、下载链接与 SHA256
**结果**: 清单可通过 winget 验证并提交 PR

## 依赖关系

```yaml
依赖: 无
被依赖: 发布流程
```