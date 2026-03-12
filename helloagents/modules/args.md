# args

## 职责

解析 CLI 参数并构建采集命令结构，负责参数互斥与默认值校验。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| parseArgs | - | !ParsedCommand | 解析进程参数 |
| parseArgsFromSlice | argv, allocator | !ParsedCommand | 测试/辅助解析入口 |
| deinitParsedCommand | parsed, allocator | void | 释放解析结果持有资源 |

## 行为规范

### 参数解析
**条件**: 输入 argv 或进程参数
**行为**: 解析 scan/prime-fw/capture 选项并校验互斥
**结果**: 返回 `ParsedCommand` 或错误（InvalidArgument/ShowHelp）

## 依赖关系

```yaml
依赖: clap, caps
被依赖: main
```