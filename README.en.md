# PXLobster

[简体中文](README.md) | [English](README.en.md)

[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Language](https://img.shields.io/github/languages/top/molqzone/pxlobster)](https://github.com/molqzone/pxlobster)
[![GitHub Stars](https://img.shields.io/github/stars/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/network/members)
[![GitHub Issues](https://img.shields.io/github/issues/molqzone/pxlobster)](https://github.com/molqzone/pxlobster/issues)

PXLobster is a command-line host tool for PXLogic logic analyzers.

## Features

- Device scan: `--scan`
- Firmware/bitstream injection: `--prime-fw`
- Capture output: `bin` / `sr`
- Target control: `--samples` (bytes) or `--time` (ms)
- Trigger configuration: `-t/--triggers`
- Pipe output: `--stdout` (for `bin` only)

## Build

Requirements:

- Zig `0.15.2+`
- System `libusb-1.0` runtime

## Linux udev Access

If you hit permission issues on Linux, install the bundled udev rule:

```bash
sudo cp packaging/udev/99-pxlobster.rules /etc/udev/rules.d/99-pxlobster.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then replug the device, or re-login your current session.

## Usage

```text
pxlobster [--verbose] --scan
pxlobster [--verbose] --prime-fw
pxlobster [--verbose] -o <path> --format <bin|sr> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
pxlobster [--verbose] --stdout --format <bin> [--samples <bytes>|--time <ms>] [--decode-cross] [--mode <buffer|stream|loop>] [-t <spec>] [--samplerate <hz>]
```

Common examples:

```bash
# Scan devices
pxlobster --scan

# Inject firmware
pxlobster --prime-fw

# Capture to a bin file
pxlobster -o /tmp/capture.bin --format bin --samples 65536

# Capture to an sr file
pxlobster -o /tmp/capture.sr --format sr --samples 1048576 --samplerate 25000000

# Stdout piping (bin)
pxlobster --stdout --format bin --samples 65536 > /tmp/capture_stdout.bin
```

Notes:

- `--format` must be specified explicitly
- `--samples` and `--time` are mutually exclusive
- `--stdout` and `--output-file` are mutually exclusive
- `--stdout` supports `--format bin` only

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See [LICENSE](LICENSE).
