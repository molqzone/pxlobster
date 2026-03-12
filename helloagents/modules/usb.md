# usb

## 职责

封装 libusb 访问、设备枚举、寄存器读写与采集寄存器脚本构建。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| listSnapshots | allocator, ctx | ![]DeviceSnapshot | 枚举设备快照 |
| openFirstDeviceByVidPid | ctx, vid, pid | !?handle | 打开首个匹配设备 |
| writeRegister | handle, addr, value, timeout | !void | 写寄存器 |
| readRegister | handle, addr, timeout | !u32 | 读寄存器 |
| buildCaptureRegisterScript | profile, options | !CaptureRegisterScript | 构建采集脚本 |

## 行为规范

### USB 操作
**条件**: 已取得 libusb 句柄
**行为**: 按协议读写寄存器/传输数据
**结果**: 成功返回或抛出 libusb 相关错误

## 依赖关系

```yaml
依赖: caps, root
被依赖: device, capture, main
```