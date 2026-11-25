; MANDEL.COM - Mandelbrot set ASCII renderer for cradle86 (pure 8086).
;
; Renders 78x22 fixed-point Q4.12 Mandelbrot set and prints elapsed time.
; Build: nasm -f bin -o MANDEL.COM mandel.asm

        cpu     8086
        org     100h

%define CRLF 13,10
COLS        equ 78
ROWS        equ 22
MAX_ITER    equ 31
; Q4.12 fixed point: 1.0 = 4096
CR_MIN      equ -8600           ; -2.10
CR_STEP     equ 158             ; ~3.0 / 78
CI_MIN      equ -4915           ; -1.20
CI_STEP     equ 447             ; ~2.4 / 22

start:
        ; Record start time (INT 21h / AH=2Ch)
        call    get_csec
        mov     [t0_lo], ax
        mov     [t0_hi], dx

        mov     word [ci], CI_MIN
        mov     word [row], ROWS

.row_loop:
        mov     word [cr], CR_MIN
        mov     di, linebuf
        mov     word [col], COLS

.col_loop:
        xor     si, si          ; x = 0
        xor     bx, bx          ; y = 0
        mov     word [iter], 0

.iter_loop:
        ; x2 = (x * x) >> 12
        mov     ax, si
        imul    ax
        call    shr12_dxax
        mov     [x2], ax

        ; y2 = (y * y) >> 12
        mov     ax, bx
        imul    ax
        call    shr12_dxax
        mov     [y2], ax

        ; Escape check: x2 + y2 >= 4.0 (16384) or signed overflow
        add     ax, [x2]
        jo      .escaped
        cmp     ax, 16384
        jae     .escaped

        ; y_new = ((x * y) >> 11) + ci
        mov     ax, si
        imul    bx
        call    shr12_dxax
        shl     ax, 1
        add     ax, [ci]
        mov     bx, ax          ; y = y_new

        ; x_new = x2 - y2 + cr
        mov     ax, [x2]
        sub     ax, [y2]
        add     ax, [cr]
        mov     si, ax          ; x = x_new

        inc     word [iter]
        cmp     word [iter], MAX_ITER
        jb      .iter_loop

        ; Inside the set
        mov     al, ' '
        jmp     short .store

.escaped:
        mov     bx, [iter]
        and     bx, 1Fh
        mov     al, [palette + bx]

.store:
        mov     [di], al
        inc     di
        add     word [cr], CR_STEP
        dec     word [col]
        jnz     .col_loop

        ; Print completed line
        mov     byte [di], 13
        mov     byte [di+1], 10
        mov     byte [di+2], '$'
        mov     dx, linebuf
        mov     ah, 09h
        int     21h

        add     word [ci], CI_STEP
        dec     word [row]
        jnz     .row_loop

        ; Compute elapsed time in centiseconds
        call    get_csec
        sub     ax, [t0_lo]
        sbb     dx, [t0_hi]
        jnc     .no_wrap
        ; Wrapped past midnight (+8640000 centiseconds = 0x0083D600)
        add     ax, 0D600h
        adc     dx, 0083h
.no_wrap:
        ; Divide DX:AX by 100 -> AX = seconds, DX = centiseconds
        mov     bx, 100
        div     bx
        push    dx              ; save centiseconds
        push    ax              ; save seconds (AH is clobbered by INT 21h/09h)

        mov     dx, s_elapsed
        mov     ah, 09h
        int     21h
        pop     ax
        call    print_u16       ; seconds
        mov     dl, '.'
        mov     ah, 02h
        int     21h
        pop     ax              ; centiseconds (0..99)
        xor     dx, dx
        mov     bx, 10
        div     bx
        push    dx
        add     al, '0'
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        mov     dx, s_sec
        mov     ah, 09h
        int     21h

        mov     ax, 4C00h
        int     21h

; Signed 32-bit DX:AX >> 12 -> AX (preserves BX, SI, DI).
shr12_dxax:
        mov     cl, 4
        shl     dx, cl
        mov     al, ah
        shr     al, cl
        xor     ah, ah
        or      ax, dx
        ret

; Returns current time of day in centiseconds in DX:AX.
get_csec:
        mov     ah, 2Ch
        int     21h             ; CH=hr, CL=min, DH=sec, DL=csec
        push    dx
        mov     al, ch
        mov     ah, 0
        mov     bx, 60
        mul     bx
        mov     bl, cl
        mov     bh, 0
        add     ax, bx          ; AX = total minutes (0..1439)
        mov     bx, 60
        mul     bx              ; DX:AX = total seconds (0..86340)
        pop     bx              ; BH=sec, BL=csec
        push    bx
        mov     bl, bh
        mov     bh, 0
        add     ax, bx
        adc     dx, 0           ; DX:AX = total seconds
        ; Multiply DX:AX by 100
        mov     cx, dx
        mov     bx, 100
        mul     bx              ; DX:AX = low * 100
        push    ax
        push    dx
        mov     ax, cx
        mul     bx              ; AX = high * 100
        pop     dx
        add     dx, ax
        pop     ax
        pop     bx
        mov     bh, 0           ; BX = csec
        add     ax, bx
        adc     dx, 0
        ret

; Prints unsigned 16-bit AX in decimal.
print_u16:
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .div
.out:   pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        loop    .out
        ret

; ---------------------------------------------------------------- Data

palette     db  " .,:;i1tfLCG08@# .,:;i1tfLCG08@#"
s_elapsed   db  "Elapsed: $"
s_sec       db  " s", CRLF, '$'

t0_lo       dw  0
t0_hi       dw  0
cr          dw  0
ci          dw  0
x2          dw  0
y2          dw  0
row         dw  0
col         dw  0
iter        dw  0

linebuf     times (COLS + 4) db 0
