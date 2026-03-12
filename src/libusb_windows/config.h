#ifndef PXLIBUSB_CONFIG_H
#define PXLIBUSB_CONFIG_H

/* Minimal libusb config for Windows GNU/Clang static builds. */

#define DEFAULT_VISIBILITY
#define ENABLE_LOGGING 1
#define PLATFORM_WINDOWS 1
#define PRINTF_FORMAT(a, b) __attribute__((format(printf, a, b)))

#endif
