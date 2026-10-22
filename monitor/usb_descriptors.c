// USB descriptors: composite device with 4 CDC-ACM interfaces.
// Linux exposes them as /dev/serial/by-id/usb-cradle86_*-if00, -if02, -if04, -if06.

#include "pico/unique_id.h"
#include "tusb.h"
#include "usb_ports.h"

#define USBD_VID 0x1209 // pid.codes
#define USBD_PID 0x0001 // pid.codes test PID (private use only)

enum {
  STR_LANG = 0,
  STR_MANUFACTURER,
  STR_PRODUCT,
  STR_SERIAL,
  STR_CDC0,
  STR_CDC1,
  STR_CDC2,
  STR_CDC3,
};

static const tusb_desc_device_t desc_device = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    // Required for composite devices using IAD.
    .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = USBD_VID,
    .idProduct = USBD_PID,
    .bcdDevice = 0x0100,
    .iManufacturer = STR_MANUFACTURER,
    .iProduct = STR_PRODUCT,
    .iSerialNumber = STR_SERIAL,
    .bNumConfigurations = 1,
};

uint8_t const *tud_descriptor_device_cb(void) {
  return (uint8_t const *)&desc_device;
}

#define ITF_NUM_TOTAL (CFG_TUD_CDC * 2)
#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + CFG_TUD_CDC * TUD_CDC_DESC_LEN)

// CDC n uses interfaces 2n/2n+1, notify EP 0x81+2n, data EPs 0x02+2n/0x82+2n.
#define CDC_DESC(n)                                                            \
  TUD_CDC_DESCRIPTOR(2 * (n), STR_CDC0 + (n), 0x81 + 2 * (n), 8,               \
                     0x02 + 2 * (n), 0x82 + 2 * (n), 64)

static const uint8_t desc_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0, 250),
    CDC_DESC(PORT_MON),
    CDC_DESC(PORT_CON),
    CDC_DESC(PORT_AUX),
    CDC_DESC(PORT_DISK),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
  (void)index;
  return desc_configuration;
}

static const char *const string_desc[] = {
    [STR_MANUFACTURER] = "cradle86",
    [STR_PRODUCT] = "cradle86 V30",
    [STR_SERIAL] = NULL, // filled from the flash unique id
    [STR_CDC0] = "V30 Monitor",
    [STR_CDC1] = "DOS Console",
    [STR_CDC2] = "DOS AUX",
    [STR_CDC3] = "Virtual Disk",
};

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
  (void)langid;
  static uint16_t desc_str[32 + 1];
  char serial[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
  const char *str;
  uint8_t len;

  if (index == STR_LANG) {
    desc_str[1] = 0x0409; // English
    len = 1;
  } else {
    if (index >= sizeof(string_desc) / sizeof(string_desc[0]))
      return NULL;
    if (index == STR_SERIAL) {
      pico_get_unique_board_id_string(serial, sizeof(serial));
      str = serial;
    } else {
      str = string_desc[index];
    }
    len = 0;
    while (str[len] && len < 32) {
      desc_str[1 + len] = (uint8_t)str[len];
      len++;
    }
  }
  desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * len + 2));
  return desc_str;
}
