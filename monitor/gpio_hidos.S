// GPIO clock bus engine for HIDOS mode, hand-scheduled for the Cortex-M0+.
//
// Same protocol as gpio_bus_run() in main.cpp (read that first), but every
// CLK phase is "fixed work + spin": the C side knows how many sys clocks each
// phase's instructions take (gpio_asm_work[] in main.cpp, "W=" below) and
// sets the spin count so the phase is just as long as the requested minimum
// width. Work is spread over the phases so that no phase is much longer than
// the V30 needs.
//
// Cycle counts (M0+, code and stack in SRAM): ALU/mov 1, SIO load/store 1,
// SRAM load/store 2, taken branch 2, untaken branch 1. A spin is
// "ldr r6, [sp, #k]" + n * (subs + bne) = 3n + 1, n >= 1; its "+1" is
// included in W. A phase is counted from its CLK edge store up to (not
// including) the next CLK edge store, along the shortest path through it, so
// the longer paths are only ever longer than requested.
//
// Registers in the loop:
//   r0 SIO base      r1 CLK mask      r2 pins at T1 (address/status)
//   r3 &ram[addr & 0x1FFFE]           r4 data      r5 ram base
//   r6 scratch/spin  r7 0xFFFF (AD0-15 mask)
//   r8 T1/Ti clocks  r9 bus cycles    r10 &stop_request
//   r11 &io_running  r12 &io_value

    .syntax unified
    .cpu cortex-m0plus
    .thumb

    .equ SIO_IN, 0x04
    .equ SIO_OUT, 0x10
    .equ SIO_SET, 0x14
    .equ SIO_CLR, 0x18
    .equ SIO_OE_SET, 0x24
    .equ SIO_OE_CLR, 0x28

    // Stack slots: spin counts, copied from GpioAsmCtx.loops (GA_* order).
    .equ S_T1L, 0
    .equ S_T1H, 4
    .equ S_IDLEH, 8
    .equ S_T2L, 12
    .equ S_T2H, 16
    .equ S_T3L, 20
    .equ S_T3H_RD, 24
    .equ S_T3H_WR, 28
    .equ S_T4L, 32
    .equ S_T4L_WR, 36
    .equ S_T4H, 40
    .equ S_T4H_WR, 44
    .equ S_CTX, 48
    .equ N_LOOPS, 12

    // Exit codes (enum Core1Exit)
    .equ EXIT_STOP, 0
    .equ EXIT_HALT, 3

.macro SPIN slot
    ldr r6, [sp, #\slot]
1:  subs r6, #1
    bne 1b
.endm

    .section .time_critical.gpio_hidos_loop, "ax"
    .global gpio_hidos_loop
    .type gpio_hidos_loop, %function
    .thumb_func
// int gpio_hidos_loop(GpioAsmCtx *ctx)
// Runs until stop_request or HLT, CPU already out of reset. Returns the exit
// code and stores the clock counts into ctx.
gpio_hidos_loop:
    push {r4-r7, lr}
    mov r4, r8
    mov r5, r9
    mov r6, r10
    mov r7, r11
    push {r4-r7}
    mov r4, r12
    push {r0, r4}               // ctx at [sp], r12 at [sp, #4]
    sub sp, #(N_LOOPS * 4)

    // loops[] -> stack
    mov r1, sp
    ldmia r0!, {r2-r7}
    stmia r1!, {r2-r7}
    ldmia r0!, {r2-r7}
    stmia r1!, {r2-r7}
    // ram, stop, io_running, io_value
    ldmia r0!, {r2-r5}
    mov r10, r3
    mov r11, r4
    mov r12, r5
    movs r5, r2
    movs r0, #0
    mov r8, r0
    mov r9, r0
    movs r0, #0xd0
    lsls r0, r0, #24
    movs r1, #1
    lsls r1, r1, #21
    ldr r7, =0xFFFF

// ---- T1 / Ti low: W=12, then sample pins.
t1:
    str r1, [r0, #SIO_CLR]
    mov r6, r8
    adds r6, #1
    mov r8, r6
    mov r6, r10
    ldrb r6, [r6]
    cmp r6, #0
    bne exit_stop
    nop                         // 60ns = 15 clocks at 250MHz with one spin
    SPIN S_T1L
    ldr r2, [r0, #SIO_IN]
// ---- T1 high: W=7 (bus cycle) / W=7 (idle clock). Start the address.
    str r1, [r0, #SIO_SET]
    lsls r6, r2, #15            // ALE -> N
    bpl idle
    uxth r3, r2
    lsrs r3, r3, #1
    lsls r3, r3, #1
    SPIN S_T1H
// ---- T2 low: W=6. RD/WR go low; r3 = (addr & 0x1FFFE).
    str r1, [r0, #SIO_CLR]
    lsrs r4, r2, #26            // A16 (GP26) -> bit 0
    lsls r4, r4, #31
    lsrs r4, r4, #15            // -> bit 16 (128KB mirror)
    adds r3, r4
    SPIN S_T2L
// ---- T2 high: W=6. Fetch the read data.
    str r1, [r0, #SIO_SET]
    lsls r6, r2, #12            // IO/M# -> N, clear = I/O
    bpl t2h_io
    ldrh r4, [r5, r3]
t2h_spin:
    SPIN S_T2H
// ---- T3 low: W=7. Sample RD/WR, put read data on the bus.
    str r1, [r0, #SIO_CLR]
    SPIN S_T3L
    ldr r6, [r0, #SIO_IN]
    lsls r6, r6, #14            // RD# -> N, WR# -> C
    bmi t3_not_read
    str r4, [r0, #SIO_OUT]      // CLK stays low, RESET low
    str r7, [r0, #SIO_OE_SET]
// ---- T3 high (read): W=5. Data setup before T4.
    str r1, [r0, #SIO_SET]
    mov r6, r9
    adds r6, #1
    mov r9, r6
t3h_rd_spin:
    SPIN S_T3H_RD
// ---- T4 low: W=3. The V30 latched the data at the edge: release now.
t4:
    str r1, [r0, #SIO_CLR]
    str r7, [r0, #SIO_OE_CLR]
    SPIN S_T4L
// ---- T4 high: W=4.
    str r1, [r0, #SIO_SET]
    SPIN S_T4H
    b t1

// ---- T1 high, no ALE: idle clock.
idle:
    SPIN S_IDLEH
    b t1

// ---- T2 high, I/O read: IN 88h returns io_running, others 0FFFFh.
t2h_io:
    uxth r4, r2
    cmp r4, #0x88
    bne 2f
    mov r4, r11
    ldrb r4, [r4]
    b t2h_spin
2:  movs r4, r7
    b t2h_spin

// ---- T3 low, not a read: write or HLT. r6 = pins << 14, so C = WR#.
t3_not_read:
    bcs exit_halt
// ---- T3 high (write): W=7. The data stays valid until T4 ends.
    str r1, [r0, #SIO_SET]
    lsrs r4, r6, #14
    uxth r4, r4
    lsls r6, r2, #12            // IO/M#
    bpl t3h_io
    nop                         // 40ns = 10 clocks at 250MHz with one spin
    SPIN S_T3H_WR
// ---- T4 low (write): W=8 (word). Commit the write.
    str r1, [r0, #SIO_CLR]
    lsls r6, r2, #11            // BHE# -> N, set = no high byte
    bmi 4f
    lsrs r6, r2, #1             // A0 -> C
    bcs 3f
    strh r4, [r5, r3]
t4l_wr_spin:
    SPIN S_T4L_WR
// ---- T4 high (write): W=7.
    str r1, [r0, #SIO_SET]
    mov r6, r9
    adds r6, #1
    mov r9, r6
    SPIN S_T4H_WR
    b t1
3:  lsrs r4, r4, #8             // high byte to an odd address
    adds r3, #1
    strb r4, [r5, r3]
    b t4l_wr_spin
4:  lsrs r6, r2, #1             // low byte to an even address
    bcs t4l_wr_spin
    strb r4, [r5, r3]
    b t4l_wr_spin

// ---- T3 high, I/O write: OUT 86h hands the request to core 0, then the
// plain T4.
t3h_io:
    uxth r6, r2
    cmp r6, #0x86
    bne 5f
    mov r6, r12
    strh r4, [r6]
    dmb
    mov r6, r11
    movs r4, #1
    strb r4, [r6]
5:  mov r6, r9
    adds r6, #1
    mov r9, r6
    b t3h_rd_spin

exit_halt:
    movs r0, #EXIT_HALT
    b exit
exit_stop:
    movs r0, #EXIT_STOP
exit:
    ldr r1, [sp, #S_CTX]
    mov r2, r8
    mov r3, r9
    str r2, [r1, #(N_LOOPS + 4) * 4]  // t1_clocks
    str r3, [r1, #(N_LOOPS + 5) * 4]  // bus_cycles
    add sp, #(N_LOOPS * 4)
    pop {r1, r4}
    mov r12, r4
    pop {r4-r7}
    mov r8, r4
    mov r9, r5
    mov r10, r6
    mov r11, r7
    pop {r4-r7, pc}

    .ltorg
    .size gpio_hidos_loop, . - gpio_hidos_loop
