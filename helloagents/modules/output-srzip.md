# output-srzip

## 职责

将原始采集文件打包为 Sigrok `.sr` ZIP 归档。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| writeSessionFromRawFile | allocator, options | !void | 生成 `.sr` 归档 |

## 行为规范

### .sr 打包
**条件**: 已有 raw 数据文件
**行为**: 写入 version/metadata/logic-1-1 条目
**结果**: 输出符合 Sigrok 规范的 `.sr` 文件

## 依赖关系

```yaml
依赖: output-session
被依赖: capture
```