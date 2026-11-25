; SANITY.COM - sanity check for cradle86 running HIDOS (V30 / 80C88 / 8086 / 8088).
;
; Tests, in order:
;   CPU     detects CPU type (V30/V20/8086/8088/186+), arithmetic, flags,
;           string ops, far call, and 80186 instructions (when supported)
;   Memory  all free conventional memory: solid patterns, then address
;           patterns written as words / read as bytes and vice versa
;           (checks A0/BHE# handling and address aliasing)
;   Clock   the time advances; prints INT 21h/2Ch calls per second
;   AUX     writes a line to AUX (USB port 2)
;   Disk A: reads A:\COMMAND.COM twice and compares the checksums
;   Disk B: creates B:\SANITY.TMP, writes/verifies it, deletes it and checks
;           the free space is back. Skipped if B: is not ready
;           (disk_server.py not running).
;
; The exit code (ERRORLEVEL) is the number of failed tests.
;
; Build: nasm -f bin -o SANITY.COM sanity.asm

        cpu     8086
        org     100h

%define CRLF 13,10
NBLK    equ     40              ; disk B: test size in 512-byte blocks

start:
        mov     sp, stack_top
        cld
        mov     dx, s_title
        call    puts
        call    test_cpu
        call    test_mem
        call    test_clock
        call    test_aux
        call    test_disk_a
        call    test_disk_b
        mov     al, [fails]
        or      al, al
        jnz     .ng
        mov     dx, s_all_ok
        call    puts
        jmp     .exit
.ng:    xor     ah, ah
        call    print_u16
        mov     dx, s_failed
        call    puts
.exit:  mov     al, [fails]
        mov     ah, 4Ch
        int     21h

; ---------------------------------------------------------------- CPU

; Detect CPU family (8086/8088 vs 186+/NEC V20/V30) and prefetch queue length
; (4 bytes = 8-bit bus 8088/V20, 6 bytes = 16-bit bus 8086/V30).
detect_cpu:
        ; 1) NEC V20/V30 ignore AAD's immediate operand (always multiply by 10).
        ;    Note: V20/V30 do NOT mask shift counts by 31 like Intel 186+, so
        ;    check AAD first, then check shift masking for Intel 186+.
        mov     byte [cpu_is_nec], 0
        mov     byte [cpu_has_186], 0
        mov     ax, 0100h
        db      0D5h, 00h       ; AAD 00h: NEC V20/V30 -> AL=0Ah, Intel -> AL=00h
        cmp     al, 0Ah
        jne     .chk_186
        mov     byte [cpu_is_nec], 1
        mov     byte [cpu_has_186], 1
        jmp     short .queue
.chk_186:
        ; 2) Intel 8086/8088 do not mask shift count by 31; 186+ do.
        mov     al, 1
        mov     cl, 32
        shr     al, cl
        mov     [cpu_has_186], al

.queue: ; 3) Prefetch queue length test (4 bytes vs 6 bytes).
        ; `mul bx` computes 0x0012 * 0x0008 = 0x0000:0090 (so DX=0, AL=90h=NOP)
        ; while taking enough clocks for the BIU to fill the prefetch queue:
        ;   8088/V20 (4B): [stosb][nop][nop][nop] -> .q_target (+5) not queued
        ;   8086/V30 (6B): [stosb][nop][nop][nop][nop][inc dx] -> queued!
        push    es
        push    cs
        pop     es
        mov     byte [.q_target], 42h   ; restore `inc dx`
        mov     di, .q_target
        mov     ax, 0012h
        mov     bx, 0008h
        cli
        jmp     short .q_go     ; flush queue before mul
.q_go:  mul     bx              ; DX=0, AL=90h (NOP); fills prefetch queue
        stosb                   ; +0: overwrite .q_target in RAM with NOP
        nop                     ; +1
        nop                     ; +2
        nop                     ; +3
        nop                     ; +4
.q_target:
        inc     dx              ; +5: executed on 6B queue (8086/V30) only
        sti
        mov     byte [.q_target], 42h   ; restore for cleanliness
        mov     [cpu_is_16bit], dl
        pop     es
        ret

print_cpu_name:
        cmp     byte [cpu_has_186], 0
        je      .c86
        cmp     byte [cpu_is_nec], 0
        je      .c186
        cmp     byte [cpu_is_16bit], 0
        je      .v20
        mov     dx, s_cpu_v30
        jmp     puts
.v20:   mov     dx, s_cpu_v20
        jmp     puts
.c186:  mov     dx, s_cpu_186
        jmp     puts
.c86:   cmp     byte [cpu_is_16bit], 0
        je      .c88
        mov     dx, s_cpu_8086
        jmp     puts
.c88:   mov     dx, s_cpu_8088
        jmp     puts

test_cpu:
        mov     dx, s_cpu
        call    puts
        call    detect_cpu
        call    print_cpu_name
        mov     byte [step], 1
        mov     ax, 1234h
        mov     bx, 5678h
        mul     bx
        cmp     dx, 0626h
        jne     .fail
        cmp     ax, 0060h
        jne     .fail

        inc     byte [step]     ; 2
        div     bx
        cmp     ax, 1234h
        jne     .fail
        or      dx, dx
        jnz     .fail

        inc     byte [step]     ; 3
        mov     ax, -3
        mov     bx, 7
        imul    bx
        cmp     ax, -21
        jne     .fail
        cmp     dx, -1
        jne     .fail

        inc     byte [step]     ; 4
        mov     ax, -100
        cwd
        idiv    bx
        cmp     ax, -14
        jne     .fail
        cmp     dx, -2
        jne     .fail

        inc     byte [step]     ; 5
        mov     ax, 8001h
        rol     ax, 1
        jnc     .fail
        cmp     ax, 0003h
        jne     .fail

        inc     byte [step]     ; 6
        mov     al, 19h
        add     al, 28h
        daa
        cmp     al, 47h
        jne     .fail

        inc     byte [step]     ; 7
        mov     ax, 0FFFFh
        add     ax, 1
        jnz     .fail
        jnc     .fail

        inc     byte [step]     ; 8
        mov     ax, 63
        aam
        cmp     ax, 0603h
        jne     .fail

        inc     byte [step]     ; 9: 80186 instructions (V20/V30/186+ only)
        cmp     byte [cpu_has_186], 0
        je      .skip_186
        cpu     186
        push    1234h
        pop     ax
        cmp     ax, 1234h
        jne     .fail
        shl     ax, 4
        cmp     ax, 2340h
        jne     .fail
        cpu     8086
.skip_186:

        inc     byte [step]     ; 10: string ops
        mov     si, s_title
        mov     di, buf
        mov     cx, 20
        rep     movsb
        mov     si, s_title
        mov     di, buf
        mov     cx, 20
        repe    cmpsb
        jne     .fail

        inc     byte [step]     ; 11
        mov     bx, hexdigits
        mov     al, 12
        xlat
        cmp     al, 'C'
        jne     .fail

        inc     byte [step]     ; 12: far call
        mov     [farptr+2], cs
        xor     ax, ax
        call    far [farptr]
        cmp     ax, 0BEEFh
        jne     .fail

        inc     byte [step]     ; 13
        mov     cx, 1000
        xor     ax, ax
.lp:    inc     ax
        loop    .lp
        cmp     ax, 1000
        jne     .fail

        inc     byte [step]     ; 14: word access at an odd address
        mov     word [buf+1], 0A55Ah
        cmp     byte [buf+1], 5Ah
        jne     .fail
        cmp     byte [buf+2], 0A5h
        jne     .fail
        mov     byte [buf+3], 3Ch
        mov     ax, [buf+2]
        cmp     ax, 3CA5h
        jne     .fail
        jmp     pass

.fail:  call    fail
        mov     dx, s_step
        call    puts
        mov     al, [step]
        xor     ah, ah
        call    print_u16
        jmp     newline

far_target:
        mov     ax, 0BEEFh
        retf

; ---------------------------------------------------------------- Memory

test_mem:
        mov     dx, s_mem
        call    puts
        mov     ax, cs
        add     ax, (prog_end - $$ + 100h + 15) / 16
        mov     [mem_start], ax
        mov     ax, [2]         ; PSP: top of memory (paragraph)
        mov     [mem_top], ax
        sub     ax, [mem_start]
        jbe     .fail_size
        mov     cl, 6
        shr     ax, cl
        call    print_u16
        mov     dx, s_kb
        call    puts

        mov     si, patterns
.solid: lodsw
        mov     [pat], ax
        mov     bx, p_fill
        call    mem_pass
        mov     bx, p_check
        call    mem_pass
        jc      .fail
        call    dot
        cmp     si, patterns_end
        jb      .solid

        mov     bx, p_waddr_write
        call    mem_pass
        mov     bx, p_waddr_vbytes
        call    mem_pass
        jc      .fail
        call    dot
        mov     bx, p_baddr_write
        call    mem_pass
        mov     bx, p_baddr_vwords
        call    mem_pass
        jc      .fail
        jmp     pass

.fail_size:
        call    fail
        ret
.fail:  call    fail
        mov     dx, s_at
        call    puts
        mov     ax, [err_seg]
        call    print_hex16
        mov     dl, ':'
        call    putc
        mov     ax, [err_off]
        call    print_hex16
        mov     dx, s_expected
        call    puts
        mov     ax, [err_exp]
        call    print_hex16
        mov     dx, s_got
        call    puts
        mov     ax, [err_got]
        call    print_hex16
        jmp     newline

; Calls BX for every paragraph in [mem_start, mem_top) with ES = DX = the
; paragraph. The procedure returns CF=1 on a mismatch with DI = offset,
; AX = expected, CX = read value. Preserves SI.
mem_pass:
        mov     dx, [mem_start]
.next:  cmp     dx, [mem_top]
        jae     .done
        mov     es, dx
        call    bx
        jc      .err
        inc     dx
        jmp     .next
.done:  push    ds
        pop     es
        clc
        ret
.err:   mov     [err_seg], dx
        mov     [err_off], di
        mov     [err_exp], ax
        mov     [err_got], cx
        push    ds
        pop     es
        stc
        ret

p_fill:
        mov     ax, [pat]
        xor     di, di
        mov     cx, 8
        rep     stosw
        clc
        ret

p_check:
        mov     ax, [pat]
        xor     di, di
        mov     cx, 8
        repe    scasw
        je      .ok
        sub     di, 2
        mov     cx, [es:di]
        stc
        ret
.ok:    clc
        ret

; Address pattern: word i of paragraph DX is (DX << 3) | i, unique in 1MB.
p_waddr_write:
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        xor     di, di
.l:     stosw
        inc     ax
        cmp     di, 16
        jb      .l
        clc
        ret

p_waddr_vbytes:
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        xor     di, di
.l:     mov     cl, [es:di]
        mov     ch, [es:di+1]
        cmp     cx, ax
        jne     .bad
        inc     ax
        add     di, 2
        cmp     di, 16
        jb      .l
        clc
        ret
.bad:   stc
        ret

; Inverted, byte-swapped address pattern, written as bytes (odd byte first).
p_baddr_write:
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        xor     di, di
.l:     mov     cx, ax
        not     cx
        xchg    cl, ch
        mov     [es:di+1], ch
        mov     [es:di], cl
        inc     ax
        add     di, 2
        cmp     di, 16
        jb      .l
        clc
        ret

p_baddr_vwords:
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        xor     di, di
.l:     mov     cx, [es:di]
        push    ax
        not     ax
        xchg    al, ah
        cmp     cx, ax
        je      .ok
        add     sp, 2
        stc
        ret
.ok:    pop     ax
        inc     ax
        add     di, 2
        cmp     di, 16
        jb      .l
        clc
        ret

; ---------------------------------------------------------------- Clock

test_clock:
        mov     dx, s_clock
        call    puts
        mov     ah, 2Ch
        int     21h
        mov     [t_sec], dh
        mov     [t_dx], dx
        xor     si, si
        xor     di, di
.w0:    call    .tick           ; the time must move within 65536 reads
        cmp     dx, [t_dx]
        jne     .w1
        or      di, di
        jz      .w0
        jmp     .fail
.w1:    call    .tick           ; wait for the next second
        jne     .edge
        cmp     di, 16
        jb      .w1
        jmp     .fail
.edge:  mov     [t_sec], dh
        xor     si, si
        xor     di, di
.w2:    call    .tick           ; count calls during one second
        jne     .done
        cmp     di, 16
        jb      .w2
        jmp     .fail
.done:  mov     ax, si
        mov     dx, di
        call    print_u32
        mov     dx, s_reads
        call    puts
        jmp     pass
.fail:  call    fail
        mov     dx, s_noclock
        call    puts
        ret
; DI:SI += 1, reads the time. ZF=1 while the second is unchanged.
.tick:  add     si, 1
        adc     di, 0
        mov     ah, 2Ch
        int     21h
        cmp     dh, [t_sec]
        ret

; ---------------------------------------------------------------- AUX

test_aux:
        mov     dx, s_aux
        call    puts
        mov     ah, 40h
        mov     bx, 3           ; stdaux
        mov     cx, aux_msg_len
        mov     dx, aux_msg
        int     21h
        jc      .fail
        cmp     ax, aux_msg_len
        jne     .fail
        mov     dx, s_aux_sent
        call    puts
        jmp     pass
.fail:  jmp     fail

; ---------------------------------------------------------------- Disk A:

test_disk_a:
        mov     dx, s_diska
        call    puts
        call    read_sum
        jc      .fail
        mov     ax, [sum]
        mov     [sum1], ax
        mov     ax, [fsize]
        mov     [fsize1], ax
        mov     ax, [fsize+2]
        mov     [fsize1+2], ax
        call    read_sum
        jc      .fail
        mov     ax, [sum]
        cmp     ax, [sum1]
        jne     .fail
        mov     ax, [fsize]
        cmp     ax, [fsize1]
        jne     .fail
        mov     dx, [fsize+2]
        cmp     dx, [fsize1+2]
        jne     .fail
        or      ax, dx
        jz      .fail
        mov     dx, fname_a
        call    puts
        mov     dl, ' '
        call    putc
        mov     ax, [fsize]
        mov     dx, [fsize+2]
        call    print_u32
        mov     dx, s_bytes_sum
        call    puts
        mov     ax, [sum]
        call    print_hex16
        jmp     pass
.fail:  jmp     fail

; Reads fname_a to the end. Sets [sum] and [fsize]. CF=1 on error.
read_sum:
        mov     ax, 3D00h
        mov     dx, fname_a_z
        int     21h
        jc      .ret
        mov     bx, ax
        xor     ax, ax
        mov     [sum], ax
        mov     [fsize], ax
        mov     [fsize+2], ax
.l:     mov     ah, 3Fh
        mov     cx, 512
        mov     dx, buf
        int     21h
        jc      .err
        or      ax, ax
        jz      .eof
        add     [fsize], ax
        adc     word [fsize+2], 0
        mov     cx, ax
        mov     si, buf
        mov     dx, [sum]
        xor     ax, ax
.s:     lodsb
        rol     dx, 1
        add     dx, ax
        loop    .s
        mov     [sum], dx
        jmp     .l
.eof:   mov     ah, 3Eh
        int     21h
        clc
.ret:   ret
.err:   mov     ah, 3Eh
        int     21h
        stc
        ret

; ---------------------------------------------------------------- Disk B:

; DOS restores INT 24h from the PSP when the program exits.
%macro CHECK_CRIT 0
        cmp     byte [crit], 0
        jne     .fail
%endmacro

test_disk_b:
        mov     dx, s_diskb
        call    puts
        mov     ax, 2524h
        mov     dx, int24
        int     21h
        mov     byte [crit], 0
        mov     ah, 36h         ; free space (reads the FAT)
        mov     dl, 2
        int     21h
        cmp     byte [crit], 0
        jne     .notready
        cmp     ax, 0FFFFh
        je      .fail
        mov     [free0], bx

        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname_b
        int     21h
        jc      .fail
        CHECK_CRIT
        mov     [handle], ax
        xor     bp, bp
.wl:    call    fill_block
        mov     ah, 40h
        mov     bx, [handle]
        mov     cx, 512
        mov     dx, buf
        int     21h
        jc      .fail_close
        cmp     ax, 512
        jne     .fail_close
        cmp     byte [crit], 0
        jne     .fail_close
        inc     bp
        cmp     bp, NBLK
        jb      .wl
        mov     ah, 3Eh
        mov     bx, [handle]
        int     21h
        jc      .fail
        CHECK_CRIT

        mov     ax, 3D00h
        mov     dx, fname_b
        int     21h
        jc      .fail
        CHECK_CRIT
        mov     [handle], ax
        xor     bp, bp
.rl:    mov     di, buf         ; clear so stale data can't pass
        mov     cx, 256
        xor     ax, ax
        rep     stosw
        mov     ah, 3Fh
        mov     bx, [handle]
        mov     cx, 512
        mov     dx, buf
        int     21h
        jc      .fail_close
        cmp     ax, 512
        jne     .fail_close
        cmp     byte [crit], 0
        jne     .fail_close
        call    check_block
        jne     .fail_close
        inc     bp
        cmp     bp, NBLK
        jb      .rl
        mov     ah, 3Fh         ; must be at EOF now
        mov     bx, [handle]
        mov     cx, 512
        mov     dx, buf
        int     21h
        jc      .fail_close
        or      ax, ax
        jnz     .fail_close
        mov     ah, 3Eh
        mov     bx, [handle]
        int     21h
        CHECK_CRIT

        mov     ah, 41h
        mov     dx, fname_b
        int     21h
        jc      .fail
        CHECK_CRIT
        mov     ah, 36h
        mov     dl, 2
        int     21h
        CHECK_CRIT
        cmp     bx, [free0]
        jne     .fail

        mov     ax, NBLK / 2
        call    print_u16
        mov     dx, s_kb_rw
        call    puts
        jmp     pass

.notready:
        mov     dx, s_notready
        jmp     puts
.fail_close:
        mov     ah, 3Eh
        mov     bx, [handle]
        int     21h
.fail:  call    fail
        cmp     byte [crit], 0
        je      .ret
        mov     dx, s_crit
        call    puts
        mov     al, [crit_code]
        xor     ah, ah
        call    print_u16
        call    newline
.ret:   ret

; Block BP: first word is BP, then bytes BP+7, BP+14, ...
fill_block:
        mov     di, buf
        mov     ax, bp
        stosw
        mov     cx, 510
        mov     dx, bp
.l:     add     dl, 7
        mov     al, dl
        stosb
        loop    .l
        ret

; ZF=1 if buf holds block BP.
check_block:
        mov     si, buf
        lodsw
        cmp     ax, bp
        jne     .ret
        mov     cx, 510
        mov     dx, bp
.l:     add     dl, 7
        lodsb
        cmp     al, dl
        jne     .ret
        loop    .l
.ret:   ret

; Critical error handler: remember it and answer Ignore (DOS 2 has no Fail).
int24:
        mov     byte [cs:crit], 1
        mov     ax, di
        mov     [cs:crit_code], al
        mov     al, 0
        iret

; ---------------------------------------------------------------- Helpers

pass:
        mov     dx, s_ok
        jmp     puts

fail:
        inc     byte [fails]
        mov     dx, s_ng
        jmp     puts

dot:
        mov     dl, '.'
putc:
        mov     ah, 02h
        int     21h
        ret

newline:
        mov     dx, s_crlf
puts:
        mov     ah, 09h
        int     21h
        ret

print_u16:
        xor     dx, dx
; Prints DX:AX in decimal.
print_u32:
        push    si
        mov     bx, 10
        xor     cx, cx
.d:     push    ax
        mov     ax, dx
        xor     dx, dx
        div     bx
        mov     si, ax          ; high quotient
        pop     ax
        div     bx              ; DX:AX / 10, DX < 10
        push    dx
        inc     cx
        mov     dx, si
        or      si, ax
        jnz     .d
.p:     pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        loop    .p
        pop     si
        ret

print_hex16:
        mov     cx, 4
        mov     bx, hexdigits
.l:     rol     ax, 1
        rol     ax, 1
        rol     ax, 1
        rol     ax, 1
        push    ax
        and     al, 0Fh
        xlat
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     ax
        loop    .l
        ret

; ---------------------------------------------------------------- Data

s_title     db  "cradle86 sanity check", CRLF, '$'
s_cpu       db  "CPU ......... $"
s_cpu_v30   db  "NEC V30 (16-bit)$"
s_cpu_v20   db  "NEC V20 (8-bit)$"
s_cpu_8086  db  "Intel 8086/80C86 (16-bit)$"
s_cpu_8088  db  "Intel 8088/80C88 (8-bit)$"
s_cpu_186   db  "80186+$"
s_mem       db  "Memory ...... $"
s_clock     db  "Clock ....... $"
s_aux       db  "AUX ......... $"
s_diska     db  "Disk A: ..... $"
s_diskb     db  "Disk B: ..... $"
s_ok        db  " OK", CRLF, '$'
s_ng        db  " NG", CRLF, '$'
s_crlf      db  CRLF, '$'
s_all_ok    db  "All tests passed.", CRLF, '$'
s_failed    db  " test(s) FAILED.", CRLF, '$'
s_step      db  "  failed at step $"
s_kb        db  " KB $"
s_at        db  "  at $"
s_expected  db  " expected $"
s_got       db  " got $"
s_reads     db  " time reads/s$"
s_noclock   db  "  time does not advance", CRLF, '$'
s_aux_sent  db  "sent a line (USB port 2)$"
s_bytes_sum db  " bytes, sum $"
s_kb_rw     db  " KB written/verified$"
s_notready  db  "SKIP (not ready: run 'make disk-server')", CRLF, '$'
s_crit      db  "  critical error code $"
fname_a     db  "A:\COMMAND.COM$"
fname_a_z   db  "A:\COMMAND.COM", 0
fname_b     db  "B:\SANITY.TMP", 0
aux_msg     db  "cradle86 sanity check: AUX OK", CRLF
aux_msg_len equ $ - aux_msg
hexdigits   db  "0123456789ABCDEF"
patterns    dw  0000h, 0FFFFh, 5555h, 0AAAAh
patterns_end:

farptr      dw  far_target, 0
cpu_has_186 db  0
cpu_is_nec  db  0
cpu_is_16bit db 0
fails       db  0
step        db  0
crit        db  0
crit_code   db  0
t_sec       db  0
t_dx        dw  0
pat         dw  0
mem_start   dw  0
mem_top     dw  0
err_seg     dw  0
err_off     dw  0
err_exp     dw  0
err_got     dw  0
sum         dw  0
sum1        dw  0
fsize       dd  0
fsize1      dd  0
free0       dw  0
handle      dw  0

buf         times 512 db 0
            times 512 db 0
stack_top:
prog_end:
