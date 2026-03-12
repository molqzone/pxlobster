# device

## 职责

识别受支持 PXLogic 设备并完成固件/位流引导，封装引导状态。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| isSupportedPxLogic | vid, pid | bool | 判断是否为受支持设备 |
| preparePxLogicDevice | dev, options | BootstrapState | 上传固件/位流 |

## 行为规范

### 固件引导
**条件**: 找到受支持设备
**行为**: 依次写入复位位流与主位流
**结果**: 返回 ready/busy/failed

## 依赖关系

```yaml
依赖: usb, pxresources
被依赖: main, capture
```