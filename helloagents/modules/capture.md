# capture

## 职责

采集执行与传输调度：配置寄存器、启动 USB 传输、缓冲与写出数据，并处理停止逻辑。

## 接口定义（可选）

| 函数/方法 | 参数 | 返回值 | 说明 |
|----------|------|--------|------|
| runCapture | allocator, options | !void | 启动一次采集任务 |

## 行为规范

### 采集流程
**条件**: 接收到有效采集参数
**行为**: 打开设备、配置寄存器、启动传输并输出数据
**结果**: 采集完成或按错误/中断停止

## 依赖关系

```yaml
依赖: usb, device, caps, output-ringbuffer, output-stream, output-session, output-srzip
被依赖: main
```