# output-session

## 职责

生成 Sigrok `.sr` 所需 metadata 与统计信息，提供通道 unitsize 映射。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| initMetadata | samplerate_hz, channel_count | !SessionMetadata | 构建默认元数据 |
| renderMetadata | allocator, metadata | ![]u8 | 渲染 metadata 文本 |
| unitsizeForChannelCount | channel_count | !u32 | 计算 unitsize |

## 行为规范

### 元数据渲染
**条件**: 需要生成 `.sr` metadata
**行为**: 填充 sigrok 字段并输出 INI 文本
**结果**: 返回可写入 `.sr` 的 metadata 内容

## 依赖关系

```yaml
依赖: std
被依赖: capture, output-srzip
```