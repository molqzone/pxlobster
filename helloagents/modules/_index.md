# 模块索引

> 通过此文件快速定位模块文档

## 模块清单

| 模块 | 职责 | 状态 | 文档 |
|------|------|------|------|
| main | CLI 入口与命令分发 | 🚧 | [main.md](./main.md) |
| args | CLI 参数解析与命令构建 | 🚧 | [args.md](./args.md) |
| caps | 采集能力与采样率映射 | 🚧 | [caps.md](./caps.md) |
| capture | 采集执行与传输调度 | 🚧 | [capture.md](./capture.md) |
| device | 设备识别与固件引导 | 🚧 | [device.md](./device.md) |
| usb | libusb 访问与寄存器操作 | 🚧 | [usb.md](./usb.md) |
| root | libusb 绑定入口 | 🚧 | [root.md](./root.md) |
| output-ringbuffer | 采集环形缓冲 | 🚧 | [output-ringbuffer.md](./output-ringbuffer.md) |
| output-stream | 采集写线程与解码 | 🚧 | [output-stream.md](./output-stream.md) |
| output-session | Sigrok 会话元数据 | 🚧 | [output-session.md](./output-session.md) |
| winget-manifests | Windows winget 发布清单 | 🚧 | [winget-manifests.md](./winget-manifests.md) |
| output-srzip | Sigrok .sr 打包 | 🚧 | [output-srzip.md](./output-srzip.md) |

## 模块依赖关系

```
main → args → caps
main → capture → usb → root
main → capture → device → usb
capture → output-ringbuffer → (无)
capture → output-stream → output-ringbuffer
capture → output-session
capture → output-srzip → output-session
发布清单: winget-manifests
```

## 状态说明
- ✅ 稳定
- 🚧 开发中
- 📝 规划中