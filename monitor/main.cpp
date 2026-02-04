/**
 * V30 Monitor & Controller for Raspberry Pi Pico
 * Features: Dual-core control, Memory Monitor, XMODEM, Disassembler stub
 */

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h" // Added for clock generation
#include "hardware/structs/sio.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Config ---
#define VERSION_STR "0.0.1"
#define RAM_SIZE 0x20000 // 128KB Virtual RAM
#define MAX_CYCLES 4000 // Log buffer size

// --- Pin Definitions ---
#define PIN_AD_BASE 0
#define PIN_ALE 16
#define PIN_RD 17
#define PIN_WR 18
#define PIN_IOM 19
#define PIN_BHE 20
#define PIN_CLK_OUT 21
#define PIN_RESET 22
#define PIN_SW 23
#define PIN_LED 25
#define PIN_A16 26 // A16-A19 are on GP26, 27, 28, 29
#define PIN_A17 27
#define PIN_A18 28
#define PIN_A19 29

// --- Data Structures ---
enum LogType { LOG_UNUSED = 0, LOG_MEM_RD, LOG_MEM_WR, LOG_IO_RD, LOG_IO_WR };

// Use `packed` attribute to ensure 8-byte alignment for cross-platform
// compatibility
struct __attribute__((packed)) BusLog {
  uint32_t address; // 4 bytes
  uint16_t data;    // 2 bytes
  uint8_t type;     // See LogType. 0 is unused.
  uint8_t ctrl;     // control signals. bit 0 for BHE status (1=low, 0=high)
};

// --- Globals ---
uint8_t ram[RAM_SIZE];
BusLog trace_log[MAX_CYCLES];

volatile bool stop_request = false;

volatile int cycle_limit;
volatile int executed_cycles;
volatile int execution_time_us;

// --- Clock Config ---
struct FreqSetting {
  uint32_t freq_hz;
  uint16_t wrap;
  float div;
};

const FreqSetting freq_table[] = {{8000000, 4, 6.25f},  {4000000, 4, 12.5f},
                                  {1000000, 4, 50.0f},  {750000, 4, 66.67f},
                                  {500000, 4, 100.0f},  {250000, 99, 10.0f},
                                  {125000, 99, 20.0f},  {50000, 99, 50.0f},
                                  {10000, 249, 100.0f}, {1000, 999, 250.0f}};
static uint32_t current_freq_hz = 125000;

// --- XMODEM Constants ---
#define SOH 0x01
#define EOT 0x04
#define ACK 0x06
#define NAK 0x15
#define CAN 0x18

// ==========================================
//   Hardware Helper Functions
// ==========================================

/**
 * @brief V30のアドレス/データバス(AD0-15)の方向を設定します。
 * @param output trueの場合は出力、falseの場合は入力に設定します。
 * @return なし
 */
inline void set_ad_dir(bool output) {
  uint32_t mask = (1 << 16) - 1; // Mask for GP0-15
  if (output)
    sio_hw->gpio_oe_set = mask;
  else
    sio_hw->gpio_oe_clr = mask;
}

/**
 * @brief V30バスからアドレス(A0-A19)を読み取ります。
 * @param なし
 * @return 読み取った20ビットのアドレス
 */
inline uint32_t read_addr() {
  uint32_t r = sio_hw->gpio_in;
  uint32_t addr = r & 0xFFFF;
  uint32_t high_addr_bits = (r >> PIN_A16) & 0b1111;
  addr |= (high_addr_bits << 16);
  return addr;
}

/**
 * @brief V30のデータバス(AD0-15)に16ビットのデータを書き込みます。
 * @param d 書き込む16ビットデータ
 * @return なし
 */
inline void write_data(uint16_t d) {
  uint32_t old_out = sio_hw->gpio_out;
  sio_hw->gpio_out = (old_out & 0xFFFF0000) | d;
}

/**
 * @brief V30のデータバス(AD0-15)から16ビットのデータを読み取ります。
 * @param なし
 * @return 読み取った16ビットデータ
 */
inline uint16_t read_data() { return sio_hw->gpio_in & 0xFFFF; }

/**
 * @brief V30の20ビットアドレスを、Pico上の64KB
 * RAMアドレス空間にマッピングします。
 * @param v30_addr V30の物理アドレス
 * @return PicoのRAM内の対応するアドレス
 */
inline uint32_t map_address(uint32_t v30_addr) {
  return v30_addr & (RAM_SIZE - 1);
}

/**
 * @brief V30に供給するクロックを指定された周波数で生成します。
 * @param freq_hz 目標の周波数 (Hz)
 * @return なし
 */
void setup_clock(uint32_t freq_hz) {
  const FreqSetting *setting = nullptr;
  for (const auto &s : freq_table) {
    if (s.freq_hz == freq_hz) {
      setting = &s;
      break;
    }
  }

  if (!setting) {
    printf("Error: Clock frequency %lu Hz not supported.\n", freq_hz);
    return;
  }

  // Configure PWM for clock output
  gpio_set_function(PIN_CLK_OUT, GPIO_FUNC_PWM);
  uint slice_num = pwm_gpio_to_slice_num(PIN_CLK_OUT);

  // Stop PWM while reconfiguring to prevent glitches
  pwm_set_enabled(slice_num, false);

  pwm_config cfg = pwm_get_default_config();
  // With 250MHz sys clock, freq = 250M / ((wrap + 1) * div)
  pwm_config_set_wrap(&cfg, setting->wrap);
  pwm_config_set_clkdiv(&cfg, setting->div);
  pwm_init(slice_num, &cfg, true);

  // Set 50% duty cycle
  pwm_set_gpio_level(PIN_CLK_OUT, (setting->wrap + 1) / 2);

  // Re-enable PWM
  pwm_set_enabled(slice_num, true);

  printf("Clock set to %lu Hz\n", freq_hz);
}

// ==========================================
//   Core 1: V30 Bus Driver
// ==========================================
// Core 1 commands
#define CMD_RUN_FULLLOG 1 // Run with full memory and I/O logging.
#define CMD_RUN_NOLOG 2   // Run without logging.
#define CMD_RUN_IOLOG 3   // Run with I/O logging only.
#define CMD_RUN_COMLOG 4   // Run with COM2 port logging only.
#define CMD_RUN_HIDOSVM 5   // Run hidos.

void hidos_cpu();

/**
 * @brief Core 1のエントリポイント。V30バスサイクルをエミュレートし、Core
 * 0からのコマンドを処理します。
 * この関数は無限ループで実行され、V30のメモリアクセスとI/Oアクセスをハンドリングします。
 * @param なし
 * @return なし
 */
void core1_entry() {
  // Initialize AD0-15 as GPIO pins
  gpio_init_mask((1 << 16) - 1); // Mask for GP0-15
  set_ad_dir(false);
  const uint32_t ctrl_mask = (1 << PIN_ALE) | (1 << PIN_RD) | (1 << PIN_WR) |
                             (1 << PIN_IOM) | (1 << PIN_BHE);
  gpio_init_mask(ctrl_mask);
  gpio_set_dir_in_masked(ctrl_mask);
  const uint32_t addr_mask =
      (1 << PIN_A16) | (1 << PIN_A17) | (1 << PIN_A18) | (1 << PIN_A19);
  gpio_init_mask(addr_mask);
  gpio_set_dir_in_masked(addr_mask);

  gpio_init(PIN_RESET);
  gpio_set_dir(PIN_RESET, GPIO_OUT);
  gpio_put(PIN_RESET, 1);

  while (true) {
    uint32_t command = multicore_fifo_pop_blocking();
    stop_request = false;

    absolute_time_t start_time = get_absolute_time(); // Start timing here

    int logged_cycles = 0;
    int bus_cycles = 0;

    enum LoggingMode { NO_LOG, IO_LOG, FULL_LOG, COM_LOG };
    LoggingMode logging_mode;

    switch (command) {
    case CMD_RUN_NOLOG:
      logging_mode = NO_LOG;
      break;
    case CMD_RUN_IOLOG:
      logging_mode = IO_LOG;
      break;
    case CMD_RUN_FULLLOG:
      logging_mode = FULL_LOG;
      break;
    case CMD_RUN_COMLOG:
      logging_mode = COM_LOG;
      break;
    case CMD_RUN_HIDOSVM:
      hidos_cpu();
      gpio_put(PIN_RESET, 1);
      continue;
    default:
      // Unknown command, ensure loop terminates immediately.
      logging_mode = NO_LOG;
      bus_cycles = cycle_limit + 1; // force exit
      break;
    }

    gpio_put(PIN_RESET, 1);
    sleep_ms(1);
    gpio_put(PIN_RESET, 0);

    while (true) {
      // --- Unified Termination Conditions ---
      if (stop_request)
        break;
      if (bus_cycles >= cycle_limit)
        break;
      if (logging_mode != NO_LOG && logged_cycles >= MAX_CYCLES)
        break;

      absolute_time_t t_start_ale = get_absolute_time();
      bool ale_detected = false;
      while (absolute_time_diff_us(t_start_ale, get_absolute_time()) <
             100000) { // ALE high timeout
        if (sio_hw->gpio_in & (1 << PIN_ALE)) {
          ale_detected = true;
          break;
        }
      }
      if (!ale_detected) {
        printf("Bus operation timeout (no ale), halt cpu.\n");
        break; // Break from the bus sniffing loop if ALE is not detected within
               // timeout (V30 inactive)
      }

      uint32_t addr = read_addr();
      bool is_io = !(sio_hw->gpio_in & (1 << PIN_IOM));

      // Wait for ALE to go low (no timeout requested here)
      while (sio_hw->gpio_in & (1 << PIN_ALE))
        ;

      bool done_bus_cycle_op = false;
      const uint32_t BUS_OPERATION_TIMEOUT_US =
          100000; // 100ms timeout for RD/WR going low
      absolute_time_t t_start_bus_operation = get_absolute_time();

      while (!done_bus_cycle_op) {
        if (absolute_time_diff_us(t_start_bus_operation, get_absolute_time()) >
            BUS_OPERATION_TIMEOUT_US) {
          printf("Bus operation timeout (no RD/WR detected low), breaking "
                 "cycle.\n");
          break; // Break from this inner loop, which will then break the outer
                 // cycle loop
        }
        uint32_t pins = sio_hw->gpio_in;

        if (!(pins & (1 << PIN_RD))) {
          sleep_us(3); // これが無いとショートしてデバイスが落ちる。
          set_ad_dir(true);
          uint16_t out_data = 0xFFFF;
          if (!is_io) {
            // Optimized read: Always read the word-aligned data.
            // The CPU will select the correct byte (or word) based on A0 and
            // BHE#.
            uint32_t aligned_v30_addr = addr & ~1;
            out_data = ram[map_address(aligned_v30_addr)] |
                       (ram[map_address(aligned_v30_addr + 1)] << 8);
          }
          write_data(out_data);

          if (logging_mode != NO_LOG) {
            bool should_log =
                (logging_mode == FULL_LOG) ||
                (logging_mode == IO_LOG && is_io) ||
                (logging_mode == COM_LOG && is_io && addr == 0x2F8);
            if (should_log) {
              uint8_t ctrl_flags =
                  (pins & (1u << PIN_BHE)) ? 0 : 1; // 1 if BHE is low
              trace_log[logged_cycles] = {
                  addr, out_data, (uint8_t)(is_io ? LOG_IO_RD : LOG_MEM_RD),
                  ctrl_flags};
              logged_cycles++;
            }
          }

          // Wait for RD to go high (no timeout requested here)
          while (!(sio_hw->gpio_in & (1 << PIN_RD)))
            ;
          set_ad_dir(false);
          done_bus_cycle_op = true;
        } else if (!(pins & (1 << PIN_WR))) {
          // Wait for WR to go high (no timeout requested here)
          while (!(sio_hw->gpio_in & (1 << PIN_WR)))
            ;
          uint16_t in_data = read_data();

          if (!is_io) {
            bool bhe_low = !(pins & (1u << PIN_BHE));
            bool a0_low = !(addr & 1);

            if (bhe_low && a0_low) { // Word Write to even address
              ram[map_address(addr)] = in_data & 0xFF;
              ram[map_address(addr + 1)] = in_data >> 8;
            } else if (bhe_low && !a0_low) { // High Byte Write to odd address
              ram[map_address(addr)] = in_data >> 8;
            } else if (!bhe_low && a0_low) { // Low Byte Write to even address
              ram[map_address(addr)] = in_data & 0xFF;
            }
            // For invalid case (BHE high, A0 high), nothing is written.
          }

          if (logging_mode != NO_LOG) {
            bool should_log =
                (logging_mode == FULL_LOG) ||
                (logging_mode == IO_LOG && is_io) ||
                (logging_mode == COM_LOG && is_io && addr == 0x2F8);
            if (should_log) {
              uint8_t ctrl_flags =
                  (pins & (1u << PIN_BHE)) ? 0 : 1; // 1 if BHE is low
              trace_log[logged_cycles] = {
                  addr, in_data, (uint8_t)(is_io ? LOG_IO_WR : LOG_MEM_WR),
                  ctrl_flags};
              logged_cycles++;
            }
          }
          done_bus_cycle_op = true;
        }
        // If ALE goes high during an active bus cycle (RD/WR phase), it
        // indicates an issue or new cycle. This breaks out of the current bus
        // operation to re-sync with the CPU.
        if (sio_hw->gpio_in & (1 << PIN_ALE)) {
          printf("ALE detected high unexpectedly during RD/WR wait, breaking "
                 "current bus operation.\n");
          break; // Break from done_bus_cycle_op loop
        }
      }

      if (done_bus_cycle_op) {
        bus_cycles++;
      } else {
        // The inner bus operation loop was broken (e.g. by timeout),
        // so we break the main bus sniffing loop.
        break;
      }
    }

    absolute_time_t end_time = get_absolute_time();
    execution_time_us =
        absolute_time_diff_us(start_time, end_time); // Store execution time

    gpio_put(PIN_RESET, 1);
    executed_cycles = bus_cycles;
    multicore_fifo_push_blocking(1); // Notify Core 0 of completion
  }
}

// ==========================================
//   HIDOS VM
// ==========================================


// Shared variable

volatile uint8_t io_running = 0; // 1 for running.
volatile uint16_t io_value = 0; // value for out86.

// Non shared variable

uint8_t hidos_loglevel = 9;
// 0 FINE
// 1 INFO
// 2 ERROR

// Images

extern const uint8_t _binary_disk_img_start[];
extern const uint8_t _binary_disk_img_end[];
extern const uint8_t _binary_disk_img_size[]; // GNU拡張

extern const uint8_t _binary_boot_img_start[];
extern const uint8_t _binary_boot_img_end[];

const uint8_t *disk_img = _binary_disk_img_start;
const size_t disk_img_size =
    (size_t)(_binary_disk_img_end - _binary_disk_img_start);

enum {
  IODEV = 0,
  IOIDX = 2,
  IOCMD = 4,
  IOBUF = 6,
  IOADR = 10,
  IOSIZ = 14,
};

// Memory access helpers
uint32_t memr2(uint32_t addr) {
  return ram[map_address(addr)] | (ram[map_address(addr + 1)] << 8);
}

void memw2(uint32_t addr, uint16_t value) {
  ram[map_address(addr)] = value & 0xFF;
  ram[map_address(addr + 1)] = value >> 8;
}

uint32_t memr4(uint32_t addr) {
  return memr2(addr) | (memr2(addr + 2) << 16);
}

void memw4(uint32_t addr, uint32_t value) {
  memw2(addr, value & 0xFFFF);
  memw2(addr + 2, value >> 16);
}

// I/O handlers from common.c, adapted for Pico
int io_init(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx)
    return -1;
  switch (cmd) {
    case 'D' << 8 | 'I': // Disks
      memw2(addr + IOBUF, 1); // one disk
      break;
    case 'R' << 8 | 'A': // RAM size
      memw4(addr + IOBUF, RAM_SIZE - 0xF);
      break;
    case 'D' << 8 | 'O':     // DOS address
      memw2(addr + IOBUF, 0x18000 >> 4);   // Fixed position for MSDOS.SYS
      break;
    default:
      return -1;
  }
  return 0;
}

int io_disk(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx){
    memw2 (addr + IOBUF, 0);
    return 0;
  }
  uint32_t buf = memr4 (addr + IOBUF);
  uint32_t siz = memr4 (addr + IOSIZ);
  uint32_t adr = memr4 (addr + IOADR);
  switch (cmd)
  {
    case 'R' << 8 | 'D':	/* Read */
      if (hidos_loglevel < 1) {
        printf("diskrw drive=%d wr=%d addr=%x off=%x len=%d\n", idx, 0, adr, buf, siz);
      }
      memcpy(ram+adr, disk_img+buf, siz);
      memw2 (addr + IOBUF, 1);

      break;
    case 'W' << 8 | 'R':	/* Write */
      memw2 (addr + IOBUF, 0);
    case 'C' << 8 | 'H':	/* Media change */
      memw2 (addr + IOBUF, 1);
      break;
    default:
      return -1;
  }
  return 0; // Return 0, but IOBUF indicates failure for the VM
}

int io_con(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx)
    return -1;
  static unsigned count;
  static uint16_t last;
  switch (cmd) {
  case 'W' << 8 | '1': // Write one byte
    count = 0;
    putchar(ram[map_address(addr + IOBUF)]);
    fflush(stdout);
    break;
  case 'W' << 8 | 'R': // Write
    count = 0;
    {
      uint32_t wr_addr = memr4(addr + IOADR);
      uint32_t wr_len = memr4(addr + IOSIZ);
      for (uint32_t i = 0; i < wr_len; i++) {
        putchar(ram[map_address(wr_addr + i)]);
      }
      fflush(stdout);
    }
    break;
  case 'R' << 8 | 'P': // Read poll
  case 'R' << 8 | '1': // Read one byte
    if (!last) {
      int c = getchar_timeout_us(0); // non-blocking check
      if (c != PICO_ERROR_TIMEOUT) {
        last = (uint8_t)c | 0x100;
      }
    }
    if (last) {
      count = 0;
    }
    memw2(addr + IOBUF, last);
    if (cmd == ('R' << 8 | '1')) {
      last = 0;
    }
    break;
  case 'R' << 8 | 'W': // Read wait (for lower CPU usage)
    if (last) {
      count = 0;
    } else if (count < 16) {
      count++;
    } else {
      // In common.c, this just polls. Here, we can't just poll without
      // reading. So we read with a timeout and buffer the character if found.
      // This should be functionally equivalent for the VM.
      int c = getchar_timeout_us(10000); // 10ms timeout
      if (c != PICO_ERROR_TIMEOUT) {
        last = (uint8_t)c | 0x100; // Buffer the character
        count = 0;                 // Reset wait counter
      }
    }
    break;
  default:
    return -1;
  }
  return 0;
}

int io_aux(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx)
    return -1;
  switch (cmd) {
  case 'R' << 8 | 'P':       // Read poll
    memw2(addr + IOBUF, 0); // No data
    break;
  default:
    break; // Other ops are no-ops
  }
  return 0;
}

int io_clock(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx)
    return -1;
  uint32_t siz = memr4 (addr + IOSIZ);
  uint32_t adr = memr4 (addr + IOADR);
  if (siz != 12)
    return -1;
  switch (cmd) {
  case 'R' << 8 | 'D': /* Read */
  {
    // Get elapsed time since boot in microseconds
    uint64_t elapsed_us = to_us_since_boot(get_absolute_time());

    uint32_t elapsed_seconds = elapsed_us / 1000000;
    uint32_t remaining_us = elapsed_us % 1000000;
    
    // 86400 seconds in a day
    uint32_t elapsed_days = elapsed_seconds / 86400;
    uint32_t seconds_of_day = elapsed_seconds % 86400;

    // Base date is Jan 1, 1980 (3652 days since 1970-01-01)
    memw4(adr + 8, remaining_us); // Microseconds (0-999999)
    memw4(adr + 4, seconds_of_day); // Seconds of a day (0-86399)
    memw4(adr + 0, 3652 + elapsed_days); // Days since 1970-01-01
  }
  break;
  case 'W' << 8 | 'R': /* Write */
    break;
  default:
    return -1;
  }
  return 0;
}

int io_printer(unsigned addr, unsigned idx, unsigned cmd) {
  if (idx)
    return -1;
  switch (cmd) {
  case 'R' << 8 | 'P':       // Read poll
    memw2(addr + IOBUF, 0); // Always busy/not present
    break;
  default:
    break; // Other ops are no-ops
  }
  return 0;
}

void vmio(uint16_t in_data) {
  // in_dataはパラグラフのアドレス。メモリアドレスにするために16倍する。
  uint16_t paragraph = in_data;
  uint32_t addr = in_data << 4;

  unsigned dev = memr2(addr + IODEV);
  unsigned idx = memr2(addr + IOIDX);
  unsigned cmd = memr2(addr + IOCMD);
  if (hidos_loglevel < 1) {
    printf("HIDOS: pos=%x %c%c %d %c%c\n", addr, dev >> 8, dev &0xFF, idx, cmd >> 8, cmd&0xFF);
  }
  int ret = -1;

  switch (dev) {
  case 'I' << 8 | 'N':
    ret = io_init(addr, idx, cmd);
    break;
  case 'D' << 8 | 'I':
    ret = io_disk(addr, idx, cmd);
    break;
  case 'C' << 8 | 'O':
    ret = io_con(addr, idx, cmd);
    break;
  case 'A' << 8 | 'U':
    ret = io_aux(addr, idx, cmd);
    break;
  case 'C' << 8 | 'L':
    ret = io_clock(addr, idx, cmd);
    break;
  case 'P' << 8 | 'R':
    ret = io_printer(addr, idx, cmd);
    break;
  }

  if (ret && ret != -2) {
    printf("vmio error: ret=%d dev=0x%04X idx=%x cmd=0x%04X\n", ret, dev, idx,
           cmd);
  }
}

// Run in core1.
void hidos_cpu() {
  gpio_put(PIN_RESET, 1);
  sleep_ms(1);
  gpio_put(PIN_RESET, 0);

  while (true) {
    absolute_time_t t_start_ale = get_absolute_time();
    bool ale_detected = false;
    while (absolute_time_diff_us(t_start_ale, get_absolute_time()) <
        100000) { // ALE high timeout
      if (sio_hw->gpio_in & (1 << PIN_ALE)) {
        ale_detected = true;
        break;
      }
    }
    if (!ale_detected) {
      printf("Bus operation timeout (no ale), halt cpu.\n");
      break;
    }

    uint32_t addr = read_addr();
    bool is_io = !(sio_hw->gpio_in & (1 << PIN_IOM));

    // Wait for ALE to go low (no timeout requested here)
    while (sio_hw->gpio_in & (1 << PIN_ALE))
      ;

    bool done_bus_cycle_op = false;
    const uint32_t BUS_OPERATION_TIMEOUT_US =
      100000; // 100ms timeout for RD/WR going low
    absolute_time_t t_start_bus_operation = get_absolute_time();

    while (!done_bus_cycle_op) {
      if (absolute_time_diff_us(t_start_bus_operation, get_absolute_time()) >
          BUS_OPERATION_TIMEOUT_US) {
        printf("Bus operation timeout (no RD/WR detected low), breaking "
            "cycle.\n");
        break; // Break from this inner loop, which will then break the outer
               // cycle loop
      }
      uint32_t pins = sio_hw->gpio_in;

      if (!(pins & (1 << PIN_RD))) {
        sleep_us(3); // これが無いとショートしてデバイスが落ちる。
        set_ad_dir(true);
        uint16_t out_data = 0xFFFF;
        if (!is_io) {
          uint32_t aligned_v30_addr = addr & ~1;
          out_data = ram[map_address(aligned_v30_addr)] |
            (ram[map_address(aligned_v30_addr + 1)] << 8);
        } else if (is_io && addr == 0x88) {
          out_data = io_running;
        }
        write_data(out_data);

        // Wait for RD to go high (no timeout requested here)
        while (!(sio_hw->gpio_in & (1 << PIN_RD)))
          ;
        set_ad_dir(false);
        done_bus_cycle_op = true;
      } else if (!(pins & (1 << PIN_WR))) {
        // Wait for WR to go high (no timeout requested here)
        while (!(sio_hw->gpio_in & (1 << PIN_WR)))
          ;
        uint16_t in_data = read_data();

        if (!is_io) {
          bool bhe_low = !(pins & (1u << PIN_BHE));
          bool a0_low = !(addr & 1);

          if (bhe_low && a0_low) { // Word Write to even address
            ram[map_address(addr)] = in_data & 0xFF;
            ram[map_address(addr + 1)] = in_data >> 8;
          } else if (bhe_low && !a0_low) { // High Byte Write to odd address
            ram[map_address(addr)] = in_data >> 8;
          } else if (!bhe_low && a0_low) { // Low Byte Write to even address
            ram[map_address(addr)] = in_data & 0xFF;
          }
          // For invalid case (BHE high, A0 high), nothing is written.
        } else if (is_io && addr == 0x86) {
          io_value = in_data;
          __dmb();
          io_running = 1;
        }

        done_bus_cycle_op = true;
      }
      // If ALE goes high during an active bus cycle (RD/WR phase), it
      // indicates an issue or new cycle. This breaks out of the current bus
      // operation to re-sync with the CPU.
      if (sio_hw->gpio_in & (1 << PIN_ALE)) {
        printf("ALE detected high unexpectedly during RD/WR wait, breaking "
            "current bus operation.\n");
        break; // Break from done_bus_cycle_op loop
      }
    }

    if (!done_bus_cycle_op) {
      // The inner bus operation loop was broken (e.g. by timeout),
      // so we break the main bus sniffing loop.
      break;
    }
  }
}

// Run in core0.
void hidos_host(uint8_t loglevel) {
  hidos_loglevel = loglevel;
  while(true){
    if (io_running == 0) continue;
    __dmb();

    vmio(io_value);

    __dmb();
    io_running = 0;
  }
}

// ==========================================
//   XMODEM Implementation (Simple)
// ==========================================
/**
 * @brief
 * XMODEM転送のために、タイムアウト付きで1バイトを標準入力から読み取ります。
 * @param timeout タイムアウト時間 (ミリ秒)
 * @return 読み取った文字。タイムアウトした場合は負数。
 */
int _inbyte(unsigned int timeout) { return getchar_timeout_us(timeout * 1000); }

/**
 * @brief XMODEM転送のために、1バイトを標準出力に書き込みます。
 * @param c 書き込む文字
 * @return なし
 */
void _outbyte(int c) {
  putchar(c);
  fflush(stdout);
}

/**
 * @brief データバッファのCRC-16-CCITTチェックサムを計算します。
 * @param buf データバッファへのポインタ
 * @param len データの長さ (バイト)
 * @return 計算された16ビットのCRC値
 */
uint16_t crc16_ccitt(const uint8_t *buf, int len) {
  uint16_t crc = 0;
  while (len--) {
    crc ^= *buf++ << 8;
    for (int i = 0; i < 8; ++i) {
      if (crc & 0x8000)
        crc = (crc << 1) ^ 0x1021;
      else
        crc = crc << 1;
    }
  }
  return crc;
}

/**
 * @brief XMODEM-CRCプロトコルを使用してデータを受信します。
 * @param dest 受信したデータを格納するバッファ
 * @param max_len 受信可能な最大バイト数
 * @return なし
 */
bool xmodem_receive(uint8_t *dest, int max_len) {
  uint8_t buffer[133]; // SOH + Block# + ~Block# + Data[128] + CRC[2]
  uint8_t block_num = 1;
  int total_bytes = 0;
  int retries = 0;
  const int max_retries = 16;
  int c; // Declare c at function scope to avoid goto/initialization error

  printf("Ready to RECEIVE XMODEM (CRC)...\n");
  fflush(stdout);
  stdio_set_translate_crlf(&stdio_usb, false);

  // 1. Start transfer: Send 'C' until sender responds with SOH
  while (retries < max_retries) {
    _outbyte('C');
    c = _inbyte(3000);
    if (c == SOH) {
      goto receive_loop; // First SOH received, start main loop
    }
    retries++;
  }
  printf("Error: No response from sender.\n");
  stdio_set_translate_crlf(&stdio_usb, true);
  return false;

receive_loop:
  retries = 0;
  while (retries <
         max_retries) { // The loop should only terminate on EOT or retry limit.
    // The first SOH was already received, or consumed at the end of the
    // previous loop iteration.
    // 2. Receive the rest of the block
    buffer[0] = SOH;
    for (int i = 1; i < 133; i++) {
      c = _inbyte(1000);
      if (c < 0) {
        // Timeout while receiving packet data
        while (_inbyte(50) >= 0)
          ; // Flush
        _outbyte(NAK);
        retries++;
        goto receive_loop_start_sync; // Go wait for a new SOH
      }
      buffer[i] = (uint8_t)c;
    }

    // 3. Validate block
    // Check block number
    if (buffer[1] == block_num && buffer[2] == (uint8_t)~block_num) {
      // CRC check
      uint16_t crc_calc = crc16_ccitt(&buffer[3], 128);
      uint16_t crc_remote = ((uint16_t)buffer[131] << 8) | buffer[132];

      if (crc_calc == crc_remote) {
        // Block is good, copy data, but prevent buffer overflow.
        if (total_bytes + 128 > max_len) {
          printf("Error: XMODEM data exceeds max_len. Aborting.\n");
          stdio_set_translate_crlf(&stdio_usb, true);
          _outbyte(CAN);
          _outbyte(CAN);
          return false;
        }
        memcpy(&dest[total_bytes], &buffer[3], 128);
        total_bytes += 128;
        block_num++;
        retries = 0;
        _outbyte(ACK);
        // Correctly handled packet, now wait for EOT or next SOH
      } else {
        // CRC error
        _outbyte(NAK);
        retries++;
        goto receive_loop_start_sync;
      }
    } else if (buffer[1] == (uint8_t)(block_num - 1)) {
      // This is a re-sent packet of the one we just processed. ACK it and move
      // on.
      _outbyte(ACK);
      retries = 0;
    } else {
      // Block number mismatch
      _outbyte(NAK);
      retries++;
      goto receive_loop_start_sync;
    }

    // 4. Check for EOT or next SOH
    c = _inbyte(2000);
    if (c == EOT) {
      _outbyte(ACK);
      printf("\nTransfer complete. Received %d bytes.\n", total_bytes);
      // Recommended to wait a moment and eat any duplicate EOTs
      sleep_ms(500);
      while (_inbyte(100) >= 0)
        ;
      stdio_set_translate_crlf(&stdio_usb, true);
      return true;
    } else if (c == SOH) {
      // Next block starts, loop continues and will process it
      continue;
    } else if (c < 0) {
      // Timeout waiting for EOT or SOH, ask for re-send
      _outbyte(NAK);
      retries++;
    }

  receive_loop_start_sync:
    // This is a recovery point. We lost sync, so wait for a fresh SOH.
    while (true) {
      c = _inbyte(1000);
      if (c == SOH) {
        goto receive_loop;
      } else if (c < 0) {
        _outbyte(NAK);
        break; // Break from inner while to outer while to check retries
      }
    }
  }
  // If we fall through the main while loop, it's due to retries or max_len
  // exceeded without EOT.
  _outbyte(CAN);
  _outbyte(CAN); // Abort transfer
  stdio_set_translate_crlf(&stdio_usb, true);
  return false;
}

/**
 * @brief XMODEM-CRCプロトコルを使用してデータを送信します。
 * @param src 送信するデータが格納されたバッファ
 * @param len 送信するデータのバイト数
 * @return なし
 */
bool xmodem_send(uint8_t *src, int len) {
  printf("Ready to SEND XMODEM...\n");
  fflush(stdout);
  stdio_set_translate_crlf(&stdio_usb, false);
  int c;
  int retries;

  // 1. Initial Handshake - wait for a single 'C' to start
  for (retries = 0; retries < 10; retries++) {
    c = _inbyte(10000);
    if (c != 'C') {
      printf("XMODEM Send: Handshake failed. Expected 'C', got 0x%02X\n", c);
      fflush(stdout);
      _outbyte(CAN);
      _outbyte(CAN);
      continue;
    }
    break;
  }

  // 2. Handle 0-byte file transfer
  if (len == 0) {
    _outbyte(EOT);
    _inbyte(2000); // Consume ACK
    stdio_set_translate_crlf(&stdio_usb, true);
    printf("XMODEM Send: 0-byte transfer complete.\n");
    fflush(stdout);
    return true;
  }

  // 3. Main data transfer loop
  uint8_t packetno = 1;
  for (int sent_len = 0; sent_len < len;) {
    retries = 0;
    while (retries < 10) {
      // 3.1 Send packet
      _outbyte(SOH);
      _outbyte(packetno);
      _outbyte(~packetno);

      uint8_t buff[128];
      memset(buff, 0x1A, 128); // Pad
      int bytes_to_copy = (len - sent_len) > 128 ? 128 : (len - sent_len);
      if (bytes_to_copy > 0) {
        memcpy(buff, &src[sent_len], bytes_to_copy);
      }
      for (int i = 0; i < 128; i++)
        _outbyte(buff[i]);

      uint16_t crc = crc16_ccitt(buff, 128);
      _outbyte(crc >> 8);
      _outbyte(crc & 0xFF);

      // 3.2 Wait for ACK
      c = _inbyte(5000);
      if (c == ACK) {
        break; // Success
      }
      // On NAK or timeout, retry
      retries++;
    }

    if (retries >= 10) {
      _outbyte(CAN);
      _outbyte(CAN);
      stdio_set_translate_crlf(&stdio_usb, true);
      printf("XMODEM Send: Failed to get ACK for packet %d\n", packetno);
      fflush(stdout);
      return false;
    }

    // 3.3 Increment for next packet
    sent_len += 128;
    packetno++;
  }

  // 4. End of Transmission
  retries = 0;
  while (retries < 10) {
    _outbyte(EOT);
    c = _inbyte(2000);
    if (c == ACK) {
      stdio_set_translate_crlf(&stdio_usb, true);
      printf("\nSend complete.\n");
      fflush(stdout);
      return true;
    }
    retries++;
  }

  stdio_set_translate_crlf(&stdio_usb, true);
  printf("XMODEM Send: Failed to get final ACK for EOT.\n");
  fflush(stdout);
  return false;
}

// ==========================================
//   Monitor Commands
// ==========================================
/**
 * @brief 'k'
 * コマンドを処理します。リンクされた boot.img の内容をRAMの先頭にロードします。
 * @param arg_str コマンドの引数文字列 (未使用)
 * @return なし
 */
void cmd_load_boot(const char *arg_str) {
    const size_t boot_img_size = (size_t)(_binary_boot_img_end - _binary_boot_img_start);
    if (boot_img_size > RAM_SIZE) {
        printf("Error: boot.img size (%u) is larger than RAM size (%u).\n", (unsigned int)boot_img_size, (unsigned int)RAM_SIZE);
        return;
    }
    memcpy(ram, _binary_boot_img_start, boot_img_size);
    printf("Loaded boot.img (%u bytes) into RAM at address 0x00000.\n", (unsigned int)boot_img_size);
}

/**
 * @brief 'd' (dump)
 * コマンドを処理します。指定されたアドレスからメモリの内容を16進数とASCIIで表示します。
 * @param arg_str コマンドの引数文字列 (アドレスと長さ)
 * @return なし
 */
void cmd_dump(const char *arg_str) {
  char args[128];
  strncpy(args, arg_str, sizeof(args) - 1);
  args[sizeof(args) - 1] = 0;
  char *addr_str = strtok(args, " ");
  char *len_str = strtok(NULL, " ");
  uint32_t addr = addr_str ? strtol(addr_str, NULL, 16) : 0;
  int len = len_str ? strtol(len_str, NULL, 10) : 256;

  for (int i = 0; i < len; i += 16) {
    printf("%05lX: ", addr + i);
    for (int j = 0; j < 16; j++)
      printf(i + j < len ? "%02X " : "   ", ram[map_address(addr + i + j)]);
    printf("|");
    for (int j = 0; j < 16; j++)
      putchar(i + j < len && isprint(ram[map_address(addr + i + j)])
                  ? ram[map_address(addr + i + j)]
                  : '.');
    printf("|\n");
  }
}

/**
 * @brief 'e' (edit)
 * コマンドを処理します。指定されたアドレスのメモリの内容を書き換えます。
 * @param arg_str コマンドの引数文字列 (アドレスと書き込むデータ)
 * @return なし
 */
void cmd_edit(const char *arg_str) {
  char args[128];
  strncpy(args, arg_str, sizeof(args) - 1);
  args[sizeof(args) - 1] = 0;
  char *addr_str = strtok(args, " ");
  if (!addr_str) {
    printf("Usage: e <addr> <val> ...\n");
    return;
  }
  uint32_t addr = strtol(addr_str, NULL, 16);
  char *val_str;
  while ((val_str = strtok(NULL, " ")) != NULL) {
    ram[map_address(addr++)] = (uint8_t)strtol(val_str, NULL, 16);
  }
  printf("Updated.\n");
}

/**
 * @brief 'f' (fill)
 * コマンドを処理します。指定されたバイト値でメモリ全体を埋めます。
 * @param arg_str コマンドの引数文字列 (16進数のバイト値)
 * @return なし
 */
void cmd_fill(const char *arg_str) {
  uint8_t fill_val = 0xF4; // Default to HLT
  if (arg_str && strlen(arg_str) > 0) {
    fill_val = (uint8_t)strtol(arg_str, NULL, 16);
  }
  memset(ram, fill_val, RAM_SIZE);
  printf("Memory filled with 0x%02X.\n", fill_val);
}

// --- Assembler/Disassembler ---
const char *const reg_names[] = {"ax", "cx", "dx", "bx",
                                 "sp", "bp", "si", "di"};
const char *const reg_names8[] = {"al", "cl", "dl", "bl",
                                  "ah", "ch", "dh", "bh"};

/**
 * @brief 16ビットレジスタ名を対応する3ビットのコードに変換します。
 * @param name レジスタ名 (例: "ax", "cx")
 * @return レジスタコード (0-7)。見つからない場合は-1。
 */
int reg_to_code(const char *name) {
  if (!name)
    return -1;
  for (int i = 0; i < 8; i++) {
    if (strcasecmp(name, reg_names[i]) == 0)
      return i;
  }
  return -1;
}

/**
 * @brief レジスタコードを対応する16ビットレジスタ名に変換します。
 * @param code レジスタコード (0-7)
 * @return レジスタ名を表す文字列。無効なコードの場合は "???"。
 */
const char *code_to_reg(int code) {
  if (code >= 0 && code < 8)
    return reg_names[code];
  return "??";
}

/**
 * @brief 1行のアセンブリコードをマシン語に変換（アセンブル）します。
 * @param addr 命令を書き込むメモリのアドレス
 * @param arg_str アセンブリ命令の文字列 (例: "mov ax, 1234")
 * @return アセンブルされた命令のバイト数。エラーの場合は0。
 */
int assemble_instruction(uint32_t addr, const char *arg_str) {
  char args[256];
  strncpy(args, arg_str, sizeof(args) - 1);
  args[sizeof(args) - 1] = 0;

  char *mnemonic = strtok(args, " ");
  if (!mnemonic) {
    return 0;
  }

  char *op1_str = strtok(NULL, ", ");
  char *op2_str = strtok(NULL, ", ");
  int bytes = 0;

  if (strcasecmp(mnemonic, "nop") == 0) {
    ram[map_address(addr)] = 0x90;
    bytes = 1;
  } else if (strcasecmp(mnemonic, "mov") == 0) {
    int reg1 = reg_to_code(op1_str);
    if (reg1 != -1 && op2_str) { // mov reg, imm
      int imm = strtol(op2_str, NULL, 16);
      ram[map_address(addr)] = 0xB8 + reg1;
      ram[map_address(addr + 1)] = imm & 0xFF;
      ram[map_address(addr + 2)] = imm >> 8;
      bytes = 3;
    } else if (op1_str[0] == '[' && op2_str &&
               reg_to_code(op2_str) == 0) { // mov [imm], ax
      int imm = strtol(op1_str + 1, NULL, 16);
      ram[map_address(addr)] = 0xA3;
      ram[map_address(addr + 1)] = imm & 0xFF;
      ram[map_address(addr + 2)] = imm >> 8;
      bytes = 3;
    }
  } else if (strcasecmp(mnemonic, "add") == 0) {
    int reg1 = reg_to_code(op1_str);
    int reg2 = reg_to_code(op2_str);
    if (reg1 != -1 && reg2 != -1) {
      ram[map_address(addr)] = 0x01;
      ram[map_address(addr + 1)] = 0xC0 | (reg2 << 3) | reg1; // ModR/M
      bytes = 2;
    }
  } else if (strcasecmp(mnemonic, "xchg") == 0) {
    int reg1 = reg_to_code(op1_str);
    int reg2 = reg_to_code(op2_str);
    if (reg1 == 0 && reg2 != -1) { // xchg ax, reg
      ram[map_address(addr)] = 0x90 + reg2;
      bytes = 1;
    } else if (reg2 == 0 && reg1 != -1) { // xchg reg, ax
      ram[map_address(addr)] = 0x90 + reg1;
      bytes = 1;
    }
  } else if (strcasecmp(mnemonic, "loop") == 0) {
    uint32_t target = strtol(op1_str, NULL, 16);
    int8_t offset = target - (addr + 2);
    ram[map_address(addr)] = 0xE2;
    ram[map_address(addr + 1)] = offset;
    bytes = 2;
  } else if (strcasecmp(mnemonic, "jmp") == 0) {
    char *target_str = op1_str;
    if (op1_str && strcasecmp(op1_str, "far") == 0) {
      target_str = op2_str;
    }

    if (!target_str) { // No operand for jmp
      return 0;
    }

    char *colon_pos = strchr(target_str, ':');
    if (colon_pos) {     // Far jump: segment:offset
      *colon_pos = '\0'; // Null-terminate segment part
      uint16_t segment = (uint16_t)strtol(target_str, NULL, 16);
      uint16_t offset = (uint16_t)strtol(colon_pos + 1, NULL,
                                         16); // Offset part starts after colon

      ram[map_address(addr)] = 0xEA; // JMP FAR opcode
      ram[map_address(addr + 1)] = offset & 0xFF;
      ram[map_address(addr + 2)] = (offset >> 8) & 0xFF;
      ram[map_address(addr + 3)] = segment & 0xFF;
      ram[map_address(addr + 4)] = (segment >> 8) & 0xFF;
      bytes = 5;
    } else { // Near jump: relative to current IP
      uint32_t target = strtol(target_str, NULL, 16);
      int8_t offset = target - (addr + 2); // EB opcode is 2 bytes
      ram[map_address(addr)] = 0xEB;       // JMP NEAR rel8 opcode
      ram[map_address(addr + 1)] = offset;
      bytes = 2;
    }
  }
  // NEW HANDLER FOR DB
  else if (strcasecmp(mnemonic, "db") == 0) {
    // The issue is that op1_str and op2_str are tokenized before this handler.
    // We need to process them and then continue tokenizing.
    if (op1_str) {
      ram[map_address(addr + bytes)] = (uint8_t)strtol(op1_str, NULL, 16);
      bytes++;
    } else {
      return 0; // No arguments for db.
    }

    if (op2_str) {
      ram[map_address(addr + bytes)] = (uint8_t)strtol(op2_str, NULL, 16);
      bytes++;
    }

    char *next_op_str;
    while ((next_op_str = strtok(NULL, " ,")) != NULL) {
      ram[map_address(addr + bytes)] = (uint8_t)strtol(next_op_str, NULL, 16);
      bytes++;
    }
  }

  if (bytes > 0) {
    printf(" ->");
    for (int i = 0; i < bytes; i++)
      printf(" %02X", ram[map_address(addr + i)]);
    return bytes;
  } else {
    return 0;
  }
}

/**
 * @brief 'l' (disassemble)
 * コマンドを処理します。指定されたアドレスからメモリの内容を逆アセンブルします。
 * @param arg_str コマンドの引数文字列 (アドレスと長さ)
 * @return なし
 */
void cmd_disasm(const char *arg_str) {
  char args[128];
  strncpy(args, arg_str, sizeof(args) - 1);
  args[sizeof(args) - 1] = 0;
  char *addr_str = strtok(args, " ");
  char *len_str = strtok(NULL, " ");
  uint32_t addr = addr_str ? strtol(addr_str, NULL, 16) : 0;
  int len = len_str ? strtol(len_str, NULL, 10) : 16;

  uint32_t pc = addr;
  while (pc < addr + len) {
    uint32_t current_pc = pc;
    uint8_t opcode = ram[map_address(pc)];
    int bytes = 1;
    char disasm_str[128] = {0};
    char hex_dump[32] = {0};

    if (opcode == 0x90) {
      sprintf(disasm_str, "nop");
    } else if (opcode >= 0xB0 && opcode <= 0xB7) {
      bytes = 2;
      uint8_t imm = ram[map_address(pc + 1)];
      sprintf(disasm_str, "mov %s, 0x%02X", reg_names8[opcode - 0xB0], imm);
    } else if (opcode >= 0xB8 && opcode <= 0xBF) {
      bytes = 3;
      uint16_t imm = ram[map_address(pc + 1)] | (ram[map_address(pc + 2)] << 8);
      sprintf(disasm_str, "mov %s, 0x%04X", code_to_reg(opcode - 0xB8), imm);
    } else if (opcode == 0x04) {
      bytes = 2;
      uint8_t imm = ram[map_address(pc + 1)];
      sprintf(disasm_str, "add al, 0x%02X", imm);
    } else if (opcode == 0xA2) {
      bytes = 3;
      uint16_t mem_addr =
          ram[map_address(pc + 1)] | (ram[map_address(pc + 2)] << 8);
      sprintf(disasm_str, "mov [0x%04X], al", mem_addr);
    } else if (opcode == 0xA3) {
      bytes = 3;
      uint16_t mem_addr =
          ram[map_address(pc + 1)] | (ram[map_address(pc + 2)] << 8);
      sprintf(disasm_str, "mov [0x%04X], ax", mem_addr);
    } else if (opcode == 0x01) {
      bytes = 2;
      uint8_t modrm = ram[map_address(pc + 1)];
      if ((modrm >> 6) == 3) { // reg, reg
        int reg1 = modrm & 7;
        int reg2 = (modrm >> 3) & 7;
        sprintf(disasm_str, "add %s, %s", code_to_reg(reg1), code_to_reg(reg2));
      }
    } else if (opcode >= 0x91 && opcode <= 0x97) {
      bytes = 1;
      sprintf(disasm_str, "xchg ax, %s", code_to_reg(opcode - 0x90));
    } else if (opcode == 0xE2) {
      bytes = 2;
      int8_t offset = ram[map_address(pc + 1)];
      sprintf(disasm_str, "loop 0x%04lX", pc + 2 + offset);
    } else if (opcode == 0xEB) {
      bytes = 2;
      int8_t offset = ram[map_address(pc + 1)];
      sprintf(disasm_str, "jmp 0x%04lX", pc + 2 + offset);
    } else if (opcode == 0xEA) { // JMP FAR segment:offset
      bytes = 5;
      uint16_t offset =
          ram[map_address(pc + 1)] | (ram[map_address(pc + 2)] << 8);
      uint16_t segment =
          ram[map_address(pc + 3)] | (ram[map_address(pc + 4)] << 8);
      sprintf(disasm_str, "jmp far 0x%04X:0x%04X", segment, offset);
    } else if (opcode == 0xF4) {
      bytes = 1;
      sprintf(disasm_str, "hlt");
    } else {
      sprintf(disasm_str, "db 0x%02X", opcode);
    }

    char *p = hex_dump;
    for (int i = 0; i < bytes; i++)
      p += sprintf(p, "%02X ", ram[map_address(current_pc + i)]);

    printf("%05lX: %-12s %s\n", current_pc, hex_dump, disasm_str);
    pc += bytes;
  }
}

// ==========================================
//   Core 0: Main Monitor
// ==========================================
/**
 * @brief メイン関数。Core
 * 0で実行され、シリアルモニタのユーザインタフェースを処理します。
 * ユーザからのコマンド入力を受け付け、対応する処理を呼び出します。
 * @param なし
 * @return 0 (ただし、無限ループのため通常は返らない)
 */
int main() {
  set_sys_clock_khz(250000, true);
  // stdio_init_all();
  stdio_usb_init();

  gpio_init(PIN_LED);
  gpio_set_dir(PIN_LED, GPIO_OUT);

  // Setup V30 clock to default frequency
  setup_clock(current_freq_hz);

  memset(ram, 0xF4, RAM_SIZE); // Default to HLT
  multicore_launch_core1(core1_entry);

  char line[128], *argv[16];
  printf("\n\n=== V30 Monitor v%s ===\nType '?' for help.\n", VERSION_STR);

  while (true) {
    printf("mon> ");
    int pos = 0;
    while (pos < 127) {
      int c = getchar();
      if (c == '\r' || c == '\n') {
        putchar('\n');
        break;
      }
      if (c == 0x08 || c == 0x7F) {
        if (pos > 0) {
          pos--;
          printf("\b \b");
        }
      } else if (isprint(c)) {
        line[pos++] = c;
        putchar(c);
      }
    }
    line[pos] = 0;
    if (pos == 0)
      continue;

    char cmd_line_copy[256];
    strncpy(cmd_line_copy, line, sizeof(cmd_line_copy));

    char *cmd = strtok(cmd_line_copy, " ");

    // Add a check for NULL cmd here
    if (cmd == NULL) {
      continue; // Skip processing if command is empty or just whitespace
    }
    const char *args = pos > strlen(cmd) ? line + strlen(cmd) + 1 : "";

    if (strcmp(cmd, "?") == 0) {
      printf(" d <addr> [len] : Dump memory\n");
      printf(" e <addr> <val> : Edit memory\n");
      printf(" f [val]        : Fill memory with byte (default F4)\n");
      printf(" a <addr>       : Assemble interactively\n");
      printf(" l <addr> [len] : Disassemble\n");
      printf(" r [cycles]     : Run & Log for specified cycles (0 or omit for "
             "infinite)\n");
      printf(" i [cycles]     : Run & Log IO only for specified cycles (0 or "
             "omit for infinite)\n");
      printf(" g              : Run Loop (Key stop)\n");
      printf(" c <kHz>        : Set V30 clock speed\n");
      printf(" xr/xs          : XMODEM Recv/Send RAM\n");
      printf(" xl             : XMODEM Send Log\n");
      printf(" v              : Version\n");
      printf(" autotest [io]  : Full auto test (Rx -> Run -> Tx Log)\n");
      printf(" b              : Reboot to BOOTSEL mode\n");
      printf(" k              : Load boot.img into RAM\n");
      printf(" h              : Start hidos vm\n");
    } else if (strcmp(cmd, "k") == 0)
      cmd_load_boot(args);
    else if (strcmp(cmd, "d") == 0)
      cmd_dump(args);
    else if (strcmp(cmd, "e") == 0)
      cmd_edit(args);
    else if (strcmp(cmd, "f") == 0)
      cmd_fill(args);
    else if (strcmp(cmd, "a") == 0) {
      char args_copy[128];
      strncpy(args_copy, args, sizeof(args_copy));
      args_copy[sizeof(args_copy) - 1] = 0;
      char *addr_str = strtok(args_copy, " ");

      if (!addr_str || strlen(addr_str) == 0) {
        printf("Usage: a <addr>\n");
        continue;
      }
      uint32_t current_addr = strtol(addr_str, NULL, 16);

      while (true) {
        printf("%05lX: ", current_addr);
        char asm_line[128];
        int asm_pos = 0;
        while (asm_pos < 127) {
          int c = getchar();
          if (c == '\r' || c == '\n') { // User presses Enter
            break;                      // Just break, newline handled below
          }
          if (c == 0x08 || c == 0x7F) {
            if (asm_pos > 0) {
              asm_pos--;
              printf("\b \b");
            }
          } else if (isprint(c)) {
            asm_line[asm_pos++] = c;
            putchar(c);
          }
        }
        asm_line[asm_pos] = 0;

        if (strcmp(asm_line, ".") == 0) {
          putchar('\n'); // For the '.' command, print a newline and exit.
          break;
        }
        if (asm_pos == 0) {
          putchar('\n'); // If empty line (user just pressed enter), output a
                         // newline and prompt again.
          continue;
        }

        int bytes = assemble_instruction(
            current_addr, asm_line); // Prints " -> XX XX XX" (no newline)
        if (bytes > 0) {
          putchar('\n'); // Add newline after the assembled instruction output.
          current_addr += bytes;
        } else {
          printf("Error: Unknown instruction or invalid operands.\n");
          putchar('\n'); // Add newline for error message
        }
      }
    } else if (strcmp(cmd, "g") == 0) {
      printf("Running V30 (No Log). Press any key to stop...\n");
      cycle_limit = 0x7FFFFFFF; // Effectively infinite for manual stop
      multicore_fifo_push_blocking(CMD_RUN_NOLOG);
      getchar();
      stop_request = true;
      multicore_fifo_pop_blocking(); // Wait for completion signal
      int cycles = executed_cycles;
      int time_us = execution_time_us; // Read execution time
      printf("Stopped. Ran %d cycles in %d us.\n", cycles, time_us);
    } else if (strcmp(cmd, "c") == 0) {
      if (!args || strlen(args) == 0) {
        printf("Usage: c <freq_khz>\n");
        printf("Available frequencies (kHz):");
        for (const auto &setting : freq_table) {
          printf(" %lu", setting.freq_hz / 1000);
        }
        printf("\nCurrent: %lu kHz\n", current_freq_hz / 1000);
      } else {
        uint32_t new_freq_khz = strtol(args, NULL, 10);
        bool found = false;
        for (const auto &setting : freq_table) {
          if ((setting.freq_hz / 1000) == new_freq_khz) {
            current_freq_hz = setting.freq_hz;
            setup_clock(current_freq_hz);
            found = true;
            break;
          }
        }
        if (!found) {
          printf("Error: Unsupported frequency. Use 'c' to list available "
                 "options.\n");
        }
      }
    } else if (strcmp(cmd, "r") == 0) {
      int run_cycles_val = (strlen(args) > 0) ? strtol(args, NULL, 10) : 0;
      bool is_infinite = (run_cycles_val == 0);

      if (is_infinite) {
        printf("Running V30 (Logging, Infinite cycles). Press any key to "
               "stop...\n");
        cycle_limit = 0x7FFFFFFF;
      } else if (run_cycles_val < 0 || run_cycles_val > MAX_CYCLES) {
        printf("Invalid cycle count (%d). Using default %d.\n",
               run_cycles_val, MAX_CYCLES);
        cycle_limit = MAX_CYCLES;
      } else {
        printf("Running V30 (Logging %d cycles)...\n", run_cycles_val);
        cycle_limit = run_cycles_val;
      }

      memset(trace_log, 0, sizeof(trace_log));
      multicore_fifo_push_blocking(CMD_RUN_FULLLOG);

      if (is_infinite) {
        while (true) {
          // Check if core 1 has finished on its own (e.g. log full, timeout)
          if (multicore_fifo_rvalid()) {
            break;
          }
          // Check if user has pressed a key to stop
          if (getchar_timeout_us(10000) != PICO_ERROR_TIMEOUT) {
            stop_request = true;
            break;
          }
        }
      }

      multicore_fifo_pop_blocking();
      int cycles = executed_cycles;
      int time_us = execution_time_us; // Read execution time
      printf("--- Log (%d bus cycles executed, %d us) ---\n", cycles, time_us);
      printf("ADDR  |B|TY|DATA\n");
      for (int i = 0; i < MAX_CYCLES; i++) {
        if (trace_log[i].type != LOG_UNUSED) {
          const char *types[] = {"RD", "WR", "IR", "IW"};
          // Type is now 1-based (0 is unused)
          if (trace_log[i].type > 0 && trace_log[i].type <= 4) {
            printf("%05lX|%s|%s|%04X\n", trace_log[i].address,
                   (trace_log[i].ctrl & 1 ? "B" : "-"),
                   types[trace_log[i].type - 1], trace_log[i].data);
          }
        }
      }
    } else if (strcmp(cmd, "i") == 0) {
      int run_cycles_val = (strlen(args) > 0) ? strtol(args, NULL, 10) : 0;
      bool is_infinite = (run_cycles_val == 0);

      if (is_infinite) {
        printf("Running V30 (Logging IO, Infinite cycles). Press any key to "
               "stop...\n");
        cycle_limit = 0x7FFFFFFF;
      } else if (run_cycles_val < 0 || run_cycles_val > MAX_CYCLES) {
        printf("Invalid cycle count (%d). Using default %d.\n",
               run_cycles_val, MAX_CYCLES);
        cycle_limit = MAX_CYCLES;
      } else {
        printf("Running V30 (Logging IO %d cycles)...\n", run_cycles_val);
        cycle_limit = run_cycles_val;
      }
      memset(trace_log, 0, sizeof(trace_log));
      multicore_fifo_push_blocking(CMD_RUN_IOLOG);

      if (is_infinite) {
        while (true) {
          // Check if core 1 has finished on its own (e.g. log full, timeout)
          if (multicore_fifo_rvalid()) {
            break;
          }
          // Check if user has pressed a key to stop
          if (getchar_timeout_us(10000) != PICO_ERROR_TIMEOUT) {
            stop_request = true;
            break;
          }
        }
      }

      multicore_fifo_pop_blocking();
      int cycles = executed_cycles;
      int time_us = execution_time_us; // Read execution time
      printf("--- IO Log (%d bus cycles executed, %d us) ---\n", cycles,
             time_us);
      printf("ADDR  |B|TY|DATA\n");
      for (int i = 0; i < MAX_CYCLES; i++) {
        if (trace_log[i].type != LOG_UNUSED) {
          const char *types[] = {"RD", "WR", "IR", "IW"};
          // Type is now 1-based (0 is unused)
          if (trace_log[i].type > 0 && trace_log[i].type <= 4) {
            printf("%05lX|%s|%s|%04X\n", trace_log[i].address,
                   (trace_log[i].ctrl & 1 ? "B" : "-"),
                   types[trace_log[i].type - 1], trace_log[i].data);
          }
        }
      }
    } else if (strcmp(cmd, "xr") == 0) {
      if (xmodem_receive(ram, RAM_SIZE)) {
        printf("XMODEM receive completed successfully.\n");
      } else {
        printf("XMODEM receive failed.\n");
      }
    } else if (strcmp(cmd, "xs") == 0) {
      if (xmodem_send(ram, RAM_SIZE)) {
        printf("XMODEM send completed successfully.\n");
      } else {
        printf("XMODEM send failed.\n");
      }
    } else if (strcmp(cmd, "xl") == 0) {
      int valid_cycles = 0;
      for (int i = 0; i < MAX_CYCLES; i++) {
        if (trace_log[i].type == LOG_UNUSED) {
          break; // Stop at the first unused entry
        }
        valid_cycles++;
      }
      if (valid_cycles > 0) {
        printf("Sending %d valid log entries (%d bytes)...\n", valid_cycles,
               valid_cycles * sizeof(BusLog));
        if (!xmodem_send((uint8_t *)trace_log, valid_cycles * sizeof(BusLog))) {
          printf("Log send failed.\n");
        }
      } else {
        printf("No log data to send.\n");
      }
    } else if (strcmp(cmd, "v") == 0)
      printf("Ver: %s, RAM: %dKB\n", VERSION_STR, RAM_SIZE / 1024);
    else if (strcmp(cmd, "autotest") == 0) {
      // Trim leading whitespace from args
      const char *args_ptr = args;
      while (*args_ptr && isspace((unsigned char)*args_ptr)) {
        args_ptr++;
      }

      uint32_t run_cmd = CMD_RUN_FULLLOG;
      if (strcmp(args_ptr, "io") == 0) {
        run_cmd = CMD_RUN_IOLOG;
        printf("[AUTOTEST] Mode: I/O Log\n");
      } else if (strcmp(args_ptr, "com2") == 0) {
        run_cmd = CMD_RUN_COMLOG;
        printf("[AUTOTEST] Mode: COM Log\n");
      } else {
        printf("[AUTOTEST] Mode: Full Log\n");
      }
      fflush(stdout);

      printf("[AUTOTEST] Receiving test binary...\n");
      fflush(stdout);
      if (xmodem_receive(ram, RAM_SIZE)) {
        printf("[AUTOTEST] Receive success. Running test...\n");
        fflush(stdout);
        memset(trace_log, 0, sizeof(trace_log));
        cycle_limit = 0x7FFFFFFF; // Infinite cycles
        multicore_fifo_push_blocking(run_cmd);
        printf("[AUTOTEST] Waiting for Core1 to complete...\n");
        fflush(stdout);
        multicore_fifo_pop_blocking();
        int bus_cycles_executed = executed_cycles;
        int time_us = execution_time_us; // Read execution time
        printf("[AUTOTEST] Core1 finished. Bus Cycles: %d, Time: %d us\n",
               bus_cycles_executed, time_us);
        fflush(stdout);

        // Count the number of valid log entries
        int valid_log_entries = 0;
        for (int i = 0; i < MAX_CYCLES; i++) {
          if (trace_log[i].type != LOG_UNUSED) {
            valid_log_entries++;
          }
        }

        // Give receiver a moment to get ready
        sleep_ms(500);

        if (valid_log_entries > 0) {
          printf("[AUTOTEST] Sending log data (%d entries, %d bytes)...\n",
                 valid_log_entries, valid_log_entries * (int)sizeof(BusLog));
          fflush(stdout);
          if (!xmodem_send((uint8_t *)trace_log,
                           valid_log_entries * sizeof(BusLog))) {
            printf("[AUTOTEST] Failed to send log data.\n");
            fflush(stdout);
          }
        } else {
          printf("[AUTOTEST] No log data to send.\n");
          fflush(stdout);
        }
        printf("\nDone. Bus Cycles: %d, Log Entries: %d, Time: %d us\n",
               bus_cycles_executed, valid_log_entries, time_us);
        fflush(stdout);
      } else {
        printf("[AUTOTEST] Aborting: Failed to receive test binary.\n");
        fflush(stdout);
      }
      printf("[AUTOTEST] Handler finished. Returning to main loop.\n");
      fflush(stdout);
    } else if (strcmp(cmd, "h") == 0) {
      int loglevel = (strlen(args) > 0) ? strtol(args, NULL, 10) : 9;
      cmd_load_boot("");
      printf("Start embedded HIDOS machine\n");
      multicore_fifo_push_blocking(CMD_RUN_HIDOSVM);
      hidos_host(loglevel);
    } else if (strcmp(cmd, "b") == 0) {
      reset_usb_boot(0, 0);
    } else
      printf("Unknown command: %s\n", cmd);
  }
}
