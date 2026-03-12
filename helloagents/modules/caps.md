# caps

## 职责

定义采集能力与采样率离散映射，提供 GPIO 时序与工作模式枚举。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| isSupportedSamplerate | samplerate_hz | bool | 判断采样率是否合法 |
| gpioTimingForSamplerate | samplerate_hz | !GpioTiming | 采样率映射到 GPIO 时序 |

## 行为规范

### 采样率校验
**条件**: 输入采样率
**行为**: 按 PXView 离散集合进行校验
**结果**: 返回是否支持或抛出 InvalidSamplerate

## 依赖关系

```yaml
依赖: std
被依赖: args, usb, capture
```