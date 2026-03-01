# PXLobster

[中文](README.md) | [English](README.en.md)

[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Language](https://img.shields.io/github/languages/top/molqzone/pxlobster)](https://github.com/molqzone/pxlobster)
[![GitHub Stars](https://img.shields.io/github/stars/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/network/members)
[![GitHub Issues](https://img.shields.io/github/issues/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/issues)

PXLobster 是一个面向 PXLogic 逻辑分析仪的命令行上位机程序。

## 特性

- 设备扫描：`--scan`
- 固件/位流注入：`--prime-fw`
- 采集输出：`bin` / `sr`
- 目标控制：`--samples`（字节）或 `--time`（毫秒）
- 触发配置：`-t/--triggers`
- 管道输出：`--stdout`（仅 `bin`）

## 构建

环境要求：

- Zig `0.15.2+`
- 系统 `libusb-1.0` 运行库

## Linux udev 放行

如果在 Linux 下遇到无权限访问设备，可安装 udev 规则：

```bash
sudo cp packaging/udev/99-pxlobster.rules /etc/udev/rules.d/99-pxlobster.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

然后重新插拔设备，或重新登录当前会话。

## 用法

```text
pxlobster [--verbose] --scan
pxlobster [--verbose] --prime-fw
pxlobster [--verbose] -o <path> --format <bin|sr> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
pxlobster [--verbose] --stdout --format <bin> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
```

常用示例：

```bash
# 扫描设备
pxlobster --scan

# 注入固件
pxlobster --prime-fw

# 采集到 bin 文件
pxlobster -o /tmp/capture.bin --format bin --samples 65536

# 采集到 sr 文件
pxlobster -o /tmp/capture.sr --format sr --samples 1048576 --samplerate 25000000

# stdout 管道输出（bin）
pxlobster --stdout --format bin --samples 65536 > /tmp/capture_stdout.bin
```

注意：

- `--format` 必须显式指定
- `--samples` 与 `--time` 互斥
- `--stdout` 与 `--output-file` 互斥
- `--stdout` 仅支持 `--format bin`

## License

本项目采用 GNU General Public License v3.0（GPL-3.0）许可证，详见 [LICENSE](LICENSE)。
