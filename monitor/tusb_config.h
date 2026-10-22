#ifndef TUSB_CONFIG_H_
#define TUSB_CONFIG_H_

// TinyUSB configuration: 4 CDC-ACM ports (see usb_ports.h for their roles).

#define CFG_TUSB_RHPORT0_MODE (OPT_MODE_DEVICE)

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_PICO
#endif

#define CFG_TUD_ENABLED 1
#define CFG_TUD_ENDPOINT0_SIZE 64

#define CFG_TUD_CDC 4
#define CFG_TUD_MSC 0
#define CFG_TUD_HID 0
#define CFG_TUD_MIDI 0
#define CFG_TUD_VENDOR 0

#define CFG_TUD_CDC_RX_BUFSIZE 1024
#define CFG_TUD_CDC_TX_BUFSIZE 1024
#define CFG_TUD_CDC_EP_BUFSIZE 64

#endif
