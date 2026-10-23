#include "usb_ports.h"

#include "pico/bootrom.h"
#include "pico/stdio/driver.h"
#include "pico/stdlib.h"
#include "tusb.h"

static void (*background_hook)(void);
static bool in_background;

void usb_background(void) {
  if (in_background)
    return;
  in_background = true;
  tud_task();
  if (background_hook)
    background_hook();
  in_background = false;
}

bool port_connected(int port) { return tud_cdc_n_connected(port); }

uint32_t port_available(int port) { return tud_cdc_n_available(port); }

int port_read_byte(int port) {
  uint8_t c;
  if (tud_cdc_n_available(port) && tud_cdc_n_read(port, &c, 1) == 1)
    return c;
  return -1;
}

uint32_t port_read(int port, void *buf, uint32_t len) {
  return tud_cdc_n_read(port, buf, len);
}

uint32_t port_write(int port, const void *buf, uint32_t len) {
  if (!tud_cdc_n_connected(port))
    return len; // nobody listening: drop
  return tud_cdc_n_write(port, buf, len);
}

void port_write_all(int port, const void *buf, uint32_t len,
                    uint32_t timeout_us) {
  const uint8_t *p = (const uint8_t *)buf;
  absolute_time_t deadline = make_timeout_time_us(timeout_us);
  while (len > 0) {
    if (!tud_cdc_n_connected(port))
      return;
    uint32_t n = tud_cdc_n_write(port, p, len);
    p += n;
    len -= n;
    if (len == 0)
      break;
    if (n > 0)
      deadline = make_timeout_time_us(timeout_us);
    else if (time_reached(deadline))
      return;
    tud_cdc_n_write_flush(port);
    tud_task();
  }
}

void port_flush(int port) {
  tud_cdc_n_write_flush(port);
  tud_task();
}

void port_discard_input(int port) { tud_cdc_n_read_flush(port); }

// Opening the monitor port at 1200 baud reboots into BOOTSEL, like the
// default pico_stdio_usb driver.
void tud_cdc_line_coding_cb(uint8_t itf, cdc_line_coding_t const *coding) {
  if (itf == PORT_MON && coding->bit_rate == 1200)
    reset_usb_boot(0, 0);
}

// --- stdio driver on PORT_MON ---

static void mon_out_chars(const char *buf, int len) {
  if (get_core_num() != 0)
    return; // TinyUSB is not thread safe; core 1 must not print.
  port_write_all(PORT_MON, buf, (uint32_t)len, 500000);
}

static void mon_out_flush(void) {
  if (get_core_num() != 0)
    return;
  port_flush(PORT_MON);
}

static int mon_in_chars(char *buf, int len) {
  if (get_core_num() != 0)
    return PICO_ERROR_NO_DATA;
  // Waiting for input: push out the prompt/echo still in the TX FIFO (TinyUSB
  // only sends on its own once a full packet has accumulated).
  tud_cdc_n_write_flush(PORT_MON);
  usb_background();
  int n = (int)tud_cdc_n_read(PORT_MON, buf, (uint32_t)len);
  return n > 0 ? n : PICO_ERROR_NO_DATA;
}

stdio_driver_t stdio_mon = {
    .out_chars = mon_out_chars,
    .out_flush = mon_out_flush,
    .in_chars = mon_in_chars,
#if PICO_STDIO_ENABLE_CRLF_SUPPORT
    .crlf_enabled = PICO_STDIO_DEFAULT_CRLF,
#endif
};

void usb_ports_init(void (*background)(void)) {
  background_hook = background;
  tud_init(0);
  stdio_set_driver_enabled(&stdio_mon, true);
}
