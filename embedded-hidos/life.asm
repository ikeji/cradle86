; LIFE.COM - Conway's Game of Life for cradle86 (pure 8086, VT100/ANSI).
;
; Starts with Gosper's Glider Gun on a 76x20 grid.
; Keys: r = random board, g = glider gun, q / ESC = quit.
;
; Build: nasm -f bin -o LIFE.COM life.asm

        cpu     8086
        org     100h

%define ESC  27
%define CRLF 13,10

W       equ     76              ; visible width
H       equ     20              ; visible height
STRIDE  equ     (W + 2)         ; 1-cell zero border on left & right
ROWS    equ     (H + 2)         ; 1-cell zero border on top & bottom
GRID_SZ equ     (STRIDE * ROWS)

start:
        cld
        ; Seed PRNG from system clock
        mov     ah, 2Ch
        int     21h
        xor     cx, dx
        or      cx, 1
        mov     [rng_seed], cx

        ; Clear screen and hide cursor
        mov     dx, s_init
        mov     ah, 09h
        int     21h

        call    load_gun

.main_loop:
        call    render
        call    step_gen

        ; Non-blocking key check
        mov     ah, 0Bh
        int     21h
        or      al, al
        jz      .main_loop

        mov     ah, 08h         ; read key without echo
        int     21h
        cmp     al, 'q'
        je      .quit
        cmp     al, 'Q'
        je      .quit
        cmp     al, ESC
        je      .quit
        cmp     al, 'r'
        je      .do_rand
        cmp     al, 'R'
        je      .do_rand
        cmp     al, 'g'
        je      .do_gun
        cmp     al, 'G'
        je      .do_gun
        jmp     short .main_loop

.do_rand:
        call    load_random
        jmp     short .main_loop
.do_gun:
        call    load_gun
        jmp     short .main_loop

.quit:
        mov     dx, s_exit
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

; Clear grid_a and reset generation counter.
clear_grid:
        push    cs
        pop     es
        mov     di, grid_a
        mov     cx, GRID_SZ
        xor     al, al
        rep     stosb
        mov     word [gen], 0
        ret

; Load Gosper's Glider Gun at (2, 2).
load_gun:
        call    clear_grid
        mov     si, gun_coords
.lp:    lodsb                   ; y (0xFF = end)
        cmp     al, 0FFh
        je      .done
        mov     bl, al          ; y
        lodsb                   ; x
        mov     bh, 0
        push    ax
        mov     al, bl
        add     al, 2           ; y + 2 (1 border + 1 margin)
        mov     ah, STRIDE
        mul     ah
        pop     dx
        mov     dh, 0
        add     ax, dx
        add     ax, 2           ; x + 2
        mov     di, ax
        mov     byte [grid_a + di], 1
        jmp     short .lp
.done:  ret

; Fill visible grid with pseudo-random cells (~25% density).
load_random:
        call    clear_grid
        mov     si, grid_a + STRIDE + 1
        mov     dx, H
.r:     mov     cx, W
.c:     call    rng_next
        and     al, 3
        cmp     al, 0
        jne     .dead
        mov     byte [si], 1
.dead:  inc     si
        loop    .c
        add     si, 2           ; skip right & left border
        dec     dx
        jnz     .r
        ret

; 16-bit xorshift PRNG -> AL.
rng_next:
        mov     ax, [rng_seed]
        mov     bx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        xor     ax, bx
        mov     bx, ax
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        xor     ax, bx
        mov     bx, ax
        shl     ax, 1
        shl     ax, 1
        xor     ax, bx
        mov     [rng_seed], ax
        ret

; Compute next generation: grid_a -> grid_b, then copy grid_b -> grid_a.
step_gen:
        mov     si, grid_a + STRIDE + 1
        mov     di, grid_b + STRIDE + 1
        mov     dx, H
.r:     mov     cx, W
.c:     ; Sum 8 neighbors around [si]
        mov     al, [si - STRIDE - 1]
        add     al, [si - STRIDE]
        add     al, [si - STRIDE + 1]
        add     al, [si - 1]
        add     al, [si + 1]
        add     al, [si + STRIDE - 1]
        add     al, [si + STRIDE]
        add     al, [si + STRIDE + 1]

        mov     bl, 0
        cmp     al, 3
        je      .alive
        cmp     al, 2
        jne     .store
        cmp     byte [si], 0
        je      .store
.alive: mov     bl, 1
.store: mov     [di], bl
        inc     si
        inc     di
        loop    .c
        add     si, 2
        add     di, 2
        dec     dx
        jnz     .r

        ; Copy grid_b -> grid_a
        push    cs
        pop     es
        mov     si, grid_b
        mov     di, grid_a
        mov     cx, GRID_SZ
        rep     movsb
        inc     word [gen]
        ret

; Render grid_a to ANSI terminal.
render:
        mov     dx, s_home
        mov     ah, 09h
        int     21h

        mov     si, grid_a + STRIDE + 1
        mov     dx, H
.r:     mov     di, linebuf
        mov     cx, W
.c:     lodsb
        or      al, al
        jz      .sp
        mov     al, '#'
        jmp     short .put
.sp:    mov     al, ' '
.put:   mov     [di], al
        inc     di
        loop    .c
        mov     byte [di], 13
        mov     byte [di+1], 10
        mov     byte [di+2], '$'

        push    dx
        push    si
        mov     dx, linebuf
        mov     ah, 09h
        int     21h
        pop     si
        pop     dx

        add     si, 2
        dec     dx
        jnz     .r

        ; Status line
        mov     dx, s_status
        mov     ah, 09h
        int     21h
        mov     ax, [gen]
        call    print_u16
        mov     dx, s_help
        mov     ah, 09h
        int     21h
        ret

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

s_init      db  ESC, "[2J", ESC, "[?25l$"
s_home      db  ESC, "[H$"
s_exit      db  ESC, "[?25h", CRLF, '$'
s_status    db  "Game of Life  Gen: $"
s_help      db  "   [r:random  g:gun  q:quit]   $"

; Gosper's Glider Gun (y, x) pairs, terminated by 0FFh
gun_coords:
        db 4,0, 5,0, 4,1, 5,1
        db 4,10, 5,10, 6,10
        db 3,11, 7,11
        db 2,12, 8,12, 2,13, 8,13
        db 5,14
        db 3,15, 7,15
        db 4,16, 5,16, 6,16
        db 5,17
        db 2,20, 3,20, 4,20
        db 2,21, 3,21, 4,21
        db 1,22, 5,22
        db 0,24, 1,24, 5,24, 6,24
        db 2,34, 3,34, 2,35, 3,35
        db 0FFh

rng_seed    dw  1
gen         dw  0
linebuf     times (W + 4) db 0
grid_a      times GRID_SZ db 0
grid_b      times GRID_SZ db 0
