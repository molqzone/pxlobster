# PXLobster

A third-party CLI host software for PXLogic logic analyzers.

## Quick Usage

```bash
# Save raw capture to a file
./zig-out/bin/pxlobster -o /tmp/capture.bin --samples 65536

# Stream raw capture to stdout for piping
./zig-out/bin/pxlobster --stdout --samples 65536 > /tmp/capture_stdout.bin
```
