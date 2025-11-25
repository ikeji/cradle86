/**
 * V30 Monitor & Controller for Raspberry Pi Pico
 * Features: Dual-core control, Memory Monitor, XMODEM, Disassembler stub
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/gpio.h"
#include "hardware/clocks.h"
#include "hardware/structs/sio.h"
#include "hardware/pwm.h" // Added for clock generation

// --- Config ---
#define VERSION_STR "1.0.2"
#define RAM_SIZE    0x10000   // 64KB Virtual RAM
#define MAX_CYCLES  5000      // Log buffer size

// --- Pin Definitions ---
#define PIN_AD_BASE 0
#define PIN_ALE     16
#define PIN_RD      17
#define PIN_WR      18
#define PIN_IOM     19
#define PIN_BHE     20
#define PIN_CLK_OUT 21
#define PIN_RESET   22
#define PIN_SW      23
#define PIN_LED     25
#define PIN_A16     26 // A16-A19 are on GP26, 27, 28, 29
#define PIN_A17     27
#define PIN_A18     28
#define PIN_A19     29

// --- Data Structures ---
enum LogType {
    LOG_UNUSED = 0,
    LOG_MEM_RD,
    LOG_MEM_WR,
    LOG_IO_RD,
    LOG_IO_WR
};

// Use `packed` attribute to ensure 8-byte alignment for cross-platform compatibility
struct __attribute__((packed)) BusLog {
    uint32_t address; // 4 bytes
    uint16_t data;    // 2 bytes
    uint8_t  type;    // See LogType. 0 is unused.
    uint8_t  dummy;   // 1 byte padding
};

// --- Globals ---
uint8_t ram[RAM_SIZE];
BusLog trace_log[MAX_CYCLES];
volatile bool core1_running = false;
volatile bool stop_request = false;

// --- Clock Config ---
struct FreqSetting {
    uint32_t freq_hz;
    uint16_t wrap;
    float    div;
};

const FreqSetting freq_table[] = {
    { 8000000, 4, 6.25f },
    { 4000000, 4, 12.5f },
    { 1000000, 4, 50.0f },
    {  125000, 99, 20.0f }
};
static uint32_t current_freq_hz = 4000000;

// --- XMODEM Constants ---
#define SOH 0x01
#define EOT 0x04
#define ACK 0x06
#define NAK 0x15
#define CAN 0x18

// ==========================================
//   Hardware Helper Functions
// ==========================================
inline void set_ad_dir(bool output) {
    uint32_t mask = (1 << 16) - 1; // Mask for GP0-15
    if (output) sio_hw->gpio_oe_set = mask;
    else        sio_hw->gpio_oe_clr = mask;
}

inline uint32_t read_addr() {
    uint32_t r = sio_hw->gpio_in;
    uint32_t addr = r & 0xFFFF;
    uint32_t high_addr_bits = (r >> PIN_A16) & 0b1111;
    addr |= (high_addr_bits << 16);
    return addr;
}

inline void write_data(uint16_t d) {
    uint32_t old_out = sio_hw->gpio_out;
    sio_hw->gpio_out = (old_out & 0xFFFF0000) | d;
}

inline uint16_t read_data() {
    return sio_hw->gpio_in & 0xFFFF;
}

inline uint32_t map_address(uint32_t v30_addr) {
    return v30_addr & (RAM_SIZE - 1);
}

void setup_clock(uint32_t freq_hz) {
    const FreqSetting* setting = nullptr;
    for (const auto& s : freq_table) {
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
#define CMD_LOG_RUN  1
#define CMD_FAST_RUN 2

void core1_entry() {
    set_ad_dir(false);
    const uint32_t ctrl_mask = (1<<PIN_ALE)|(1<<PIN_RD)|(1<<PIN_WR)|(1<<PIN_IOM)|(1<<PIN_BHE);
    gpio_init_mask(ctrl_mask);
    gpio_set_dir_in_masked(ctrl_mask);
    const uint32_t addr_mask = (1<<PIN_A16)|(1<<PIN_A17)|(1<<PIN_A18)|(1<<PIN_A19);
    gpio_init_mask(addr_mask);
    gpio_set_dir_in_masked(addr_mask);

    gpio_init(PIN_RESET); gpio_set_dir(PIN_RESET, GPIO_OUT);
    gpio_put(PIN_RESET, 0);

    while (true) {
        uint32_t cmd = multicore_fifo_pop_blocking();
        core1_running = true;
        stop_request = false;

        gpio_put(PIN_RESET, 1); sleep_ms(1); gpio_put(PIN_RESET, 0);

        int cycles = 0;
        bool logging = (cmd == CMD_LOG_RUN);
        bool infinite = (cmd == CMD_FAST_RUN);

        while (true) {
            if (!infinite && cycles >= MAX_CYCLES) break;
            if (infinite && stop_request) break;

            absolute_time_t t_start = get_absolute_time();
            bool ale_detected = false;
            while (absolute_time_diff_us(t_start, get_absolute_time()) < 100000) {
                if (sio_hw->gpio_in & (1 << PIN_ALE)) {
                    ale_detected = true;
                    break;
                }
            }
            if (!ale_detected) break;

            uint32_t addr = read_addr();
            bool is_io = (sio_hw->gpio_in & (1 << PIN_IOM));
            
            while (sio_hw->gpio_in & (1 << PIN_ALE));

            bool done = false;
            while (!done) {
                uint32_t pins = sio_hw->gpio_in;
                
                if (!(pins & (1 << PIN_RD))) {
                    set_ad_dir(true);
                    uint16_t out_data = 0xFFFF;
                    if (!is_io) {
                         uint32_t mapped_addr = map_address(addr);
                         out_data = ram[mapped_addr] | (ram[map_address(mapped_addr + 1)] << 8);
                    }
                    write_data(out_data);

                    if (logging) trace_log[cycles] = {addr, out_data, (uint8_t)(is_io ? LOG_IO_RD : LOG_MEM_RD), 0};

                    while (!(sio_hw->gpio_in & (1 << PIN_RD)));
                    set_ad_dir(false);
                    done = true;
                }
                else if (!(pins & (1 << PIN_WR))) {
                    while (!(sio_hw->gpio_in & (1 << PIN_WR)));
                    uint16_t in_data = read_data();
                    
                    if (!is_io) {
                        uint32_t mapped_addr = map_address(addr);
                        if (!(pins & (1u << PIN_BHE))) ram[map_address(mapped_addr + 1)] = in_data >> 8;
                        if (!(addr & 1)) ram[mapped_addr] = in_data & 0xFF;
                    }

                    if (logging) trace_log[cycles] = {addr, in_data, (uint8_t)(is_io ? LOG_IO_WR : LOG_MEM_WR), 0};
                    done = true;
                }
                if (sio_hw->gpio_in & (1 << PIN_ALE)) break;
            }
            if(done) cycles++;
        }
        
        core1_running = false;
        multicore_fifo_push_blocking(cycles);
    }
}

// ==========================================
//   XMODEM Implementation (Simple)
// ==========================================
int _inbyte(unsigned int timeout) { return getchar_timeout_us(timeout * 1000); }
void _outbyte(int c) { putchar(c); }

uint16_t crc16_ccitt(const uint8_t *buf, int len) {
    uint16_t crc = 0;
    while (len--) {
        crc ^= *buf++ << 8;
        for (int i = 0; i < 8; ++i) {
            if (crc & 0x8000) crc = (crc << 1) ^ 0x1021;
            else crc = crc << 1;
        }
    }
    return crc;
}

void xmodem_receive(uint8_t *dest, int max_len) {
    printf("Ready to RECEIVE XMODEM (CRC)... C to cancel\n");
    uint8_t packetno = 1;
    int len = 0, retry = 0;
    while(1) {
        if (len >= max_len) { _outbyte(CAN); _outbyte(CAN); return; }
        _outbyte(retry > 0 ? NAK : 'C');
        int c = _inbyte(2000);
        if (c < 0) { retry++; continue; }
        if (c == SOH) {
            uint8_t blk = _inbyte(1000), cblk = _inbyte(1000);
            if (blk != packetno || blk != (255 - cblk)) { retry++; continue; }
            uint8_t buff[128];
            for (int i=0; i<128; i++) buff[i] = _inbyte(1000);
            uint16_t crc = (_inbyte(1000) << 8) | _inbyte(1000);
            if (crc == crc16_ccitt(buff, 128)) {
                memcpy(&dest[len], buff, 128); len += 128;
                _outbyte(ACK); packetno++; retry = 0;
            } else { retry++; }
        } else if (c == EOT) {
            _outbyte(ACK); printf("\nTransfer complete. %d bytes.\n", len); return;
        } else if (c == CAN) { printf("\nCanceled by remote.\n"); return; }
    }
}

void xmodem_send(uint8_t *src, int len) {
    printf("Ready to SEND XMODEM...\n");
    int c;
    while ((c = _inbyte(10000)) != 'C' && c != NAK) if (c == CAN) return;
    
    uint8_t packetno = 1;
    for (int sent_len = 0; sent_len < len; sent_len += 128) {
        _outbyte(SOH); _outbyte(packetno); _outbyte(255 - packetno);
        uint8_t buff[128];
        memset(buff, 0x1A, 128);
        memcpy(buff, &src[sent_len], (len - sent_len) > 128 ? 128 : (len - sent_len));
        for (int i=0; i<128; i++) _outbyte(buff[i]);
        uint16_t crc = crc16_ccitt(buff, 128);
        _outbyte(crc >> 8); _outbyte(crc & 0xFF);
        if (_inbyte(5000) != ACK) { sent_len -= 128; }
        packetno++;
    }
    _outbyte(EOT); _inbyte(2000);
    printf("\nSend complete.\n");
}

// ==========================================
//   Monitor Commands
// ==========================================
void cmd_dump(const char *arg_str) {
    char args[128];
    strncpy(args, arg_str, sizeof(args)-1);
    args[sizeof(args)-1] = 0;
    char *addr_str = strtok(args, " ");
    char *len_str = strtok(NULL, " ");
    uint32_t addr = addr_str ? strtol(addr_str, NULL, 16) : 0;
    int len = len_str ? strtol(len_str, NULL, 10) : 256;

    for (int i = 0; i < len; i += 16) {
        printf("%05lX: ", addr + i);
        for (int j = 0; j < 16; j++) printf(i + j < len ? "%02X " : "   ", ram[map_address(addr + i + j)]);
        printf("|");
        for (int j = 0; j < 16; j++) putchar(i + j < len && isprint(ram[map_address(addr + i + j)]) ? ram[map_address(addr + i + j)] : '.');
        printf("|\n");
    }
}

void cmd_edit(const char *arg_str) {
    char args[128];
    strncpy(args, arg_str, sizeof(args)-1);
    args[sizeof(args)-1] = 0;
    char *addr_str = strtok(args, " ");
    if (!addr_str) { printf("Usage: e <addr> <val> ...\n"); return; }
    uint32_t addr = strtol(addr_str, NULL, 16);
    char *val_str;
    while ((val_str = strtok(NULL, " ")) != NULL) {
        ram[map_address(addr++)] = (uint8_t)strtol(val_str, NULL, 16);
    }
    printf("Updated.\n");
}

void cmd_disasm(const char *arg) {
    printf("Disassembly not yet fully implemented.\n");
}

// ==========================================
//   Core 0: Main Monitor
// ==========================================
int main() {
    set_sys_clock_khz(250000, true);
    stdio_init_all();
    
    gpio_init(PIN_LED); gpio_set_dir(PIN_LED, GPIO_OUT);

    // Setup V30 clock to default frequency
    setup_clock(current_freq_hz);

    memset(ram, 0x90, RAM_SIZE);
    multicore_launch_core1(core1_entry);

    char line[128], *argv[16];
    printf("\n\n=== V30 Monitor v%s ===\nType '?' for help.\n", VERSION_STR);

    while (true) {
        printf("mon> ");
        int pos = 0;
        while(pos < 127) {
            int c = getchar();
            if (c == '\r' || c == '\n') { putchar('\n'); break; }
            if (c == 0x08 || c == 0x7F) { if(pos > 0) { pos--; printf("\b \b"); }}
            else if (isprint(c)) { line[pos++] = c; putchar(c); }
        }
        line[pos] = 0;
        if (pos == 0) continue;

        char cmd_line_copy[128];
        strncpy(cmd_line_copy, line, sizeof(cmd_line_copy));
        
        char* cmd = strtok(cmd_line_copy, " ");
        // FIX: Handle `strtok` modifying the string by using a copy for parsing args
        const char* args = pos > strlen(cmd) ? line + strlen(cmd) + 1 : "";

        if (strcmp(cmd, "?") == 0) {
            printf(" d <addr> [len] : Dump memory\n");
            printf(" e <addr> <val> : Edit memory\n");
            printf(" l <addr> [len] : Disassemble\n");
            printf(" r              : Run & Log\n");
            printf(" g              : Run Loop (Key stop)\n");
            printf(" c <kHz>        : Set V30 clock speed\n");
            printf(" xr/xs          : XMODEM Recv/Send RAM\n");
            printf(" xl             : XMODEM Send Log\n");
            printf(" v              : Version\n");
            printf(" autotest       : Full auto test (Rx -> Run -> Tx Log)\n");
        } else if (strcmp(cmd, "d") == 0) cmd_dump(args);
        else if (strcmp(cmd, "e") == 0) cmd_edit(args);
        else if (strcmp(cmd, "l") == 0) cmd_disasm(args);
        else if (strcmp(cmd, "g") == 0) {
            printf("Running V30 (No Log). Press any key to stop...\n");
            multicore_fifo_push_blocking(CMD_FAST_RUN); getchar(); stop_request = true;
            multicore_fifo_pop_blocking(); printf("Stopped.\n");
        } else if (strcmp(cmd, "c") == 0) {
            if (!args || strlen(args) == 0) {
                printf("Usage: c <freq_khz>\n");
                printf("Available frequencies (kHz):");
                for (const auto& setting : freq_table) {
                    printf(" %lu", setting.freq_hz / 1000);
                }
                printf("\nCurrent: %lu kHz\n", current_freq_hz / 1000);
            } else {
                uint32_t new_freq_khz = strtol(args, NULL, 10);
                bool found = false;
                for (const auto& setting : freq_table) {
                    if ((setting.freq_hz / 1000) == new_freq_khz) {
                        current_freq_hz = setting.freq_hz;
                        setup_clock(current_freq_hz);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    printf("Error: Unsupported frequency. Use 'c' to list available options.\n");
                }
            }
        } else if (strcmp(cmd, "r") == 0) {
            printf("Running V30 (Logging %d cycles)...\n", MAX_CYCLES);
            memset(trace_log, 0, sizeof(trace_log));
            multicore_fifo_push_blocking(CMD_LOG_RUN);
            int cycles = multicore_fifo_pop_blocking();
            printf("--- Log (%d cycles) ---\n", cycles);
            for(int i=0; i<cycles; i++) {
                const char *types[] = {"RD", "WR", "IO_R", "IO_W"};
                // Type is now 1-based (0 is unused)
                if (trace_log[i].type > 0 && trace_log[i].type <= 4) {
                    printf("%05lX|%s|%04X\n", trace_log[i].address, types[trace_log[i].type - 1], trace_log[i].data);
                }
            }
        } else if (strcmp(cmd, "xr") == 0) xmodem_receive(ram, RAM_SIZE);
        else if (strcmp(cmd, "xs") == 0) xmodem_send(ram, RAM_SIZE);
        else if (strcmp(cmd, "xl") == 0) {
            int valid_cycles = 0;
            for (int i = 0; i < MAX_CYCLES; i++) {
                if (trace_log[i].type == LOG_UNUSED) {
                    break; // Stop at the first unused entry
                }
                valid_cycles++;
            }
            if (valid_cycles > 0) {
                printf("Sending %d valid log entries (%d bytes)...\n", valid_cycles, valid_cycles * sizeof(BusLog));
                xmodem_send((uint8_t*)trace_log, valid_cycles * sizeof(BusLog));
            } else {
                printf("No log data to send.\n");
            }
        }
        else if (strcmp(cmd, "v") == 0) printf("Ver: %s, RAM: %dKB\n", VERSION_STR, RAM_SIZE/1024);
        else if (strcmp(cmd, "autotest") == 0) {
            xmodem_receive(ram, RAM_SIZE);
            memset(trace_log, 0, sizeof(trace_log));
            multicore_fifo_push_blocking(CMD_LOG_RUN);
            int cycles = multicore_fifo_pop_blocking();
            xmodem_send((uint8_t*)trace_log, cycles * sizeof(BusLog));
            printf("\nDone. Cycles: %d\n", cycles);
        }
        else printf("Unknown command: %s\n", cmd);
    }
}
