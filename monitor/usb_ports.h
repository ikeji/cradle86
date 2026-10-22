#ifndef USB_PORTS_H_
#define USB_PORTS_H_

// 4 USB CDC serial ports. All TinyUSB calls happen on core 0 in thread
// context (no USB IRQ worker), so port_* functions must only be used on core 0.

#include <stdbool.h>
#include <stdint.h>

#include "pico/stdio/driver.h"

#define PORT_MON 0  // monitor (stdio: printf/getchar)
#define PORT_CON 1  // HIDOS console (CO device)
#define PORT_AUX 2  // HIDOS AUX / COM (AU device)
#define PORT_DISK 3 // virtual disk server protocol (DI device)

#ifdef __cplusplus
extern "C" {
#endif

// stdio driver for PORT_MON (for stdio_set_translate_crlf).
extern stdio_driver_t stdio_mon;

// Initializes USB and registers PORT_MON as the stdio driver. `background` is
// called whenever core 0 waits for monitor input.
void usb_ports_init(void (*background)(void));

// Runs tud_task() and the background hook. Safe to call recursively (nested
// calls are ignored).
void usb_background(void);

bool port_connected(int port);
uint32_t port_available(int port);
int port_read_byte(int port); // -1 if no data
uint32_t port_read(int port, void *buf, uint32_t len);
uint32_t port_write(int port, const void *buf, uint32_t len); // non-blocking
// Writes everything, servicing USB while the TX FIFO is full. Gives up (drops
// the rest) if the port is not open or the host stops reading for timeout_us.
void port_write_all(int port, const void *buf, uint32_t len,
                    uint32_t timeout_us);
void port_flush(int port);
void port_discard_input(int port);

#ifdef __cplusplus
}
#endif

#endif
