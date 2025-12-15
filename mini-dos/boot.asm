bits 16

; --- DEFINITIONS (must come before org) ---
COM1                    equ 0x3F8
BOOTLOADER_ORIGINAL_SEG equ 0x0000
BOOTLOADER_RELOCATE_SEG equ 0x4000
BOOTLOADER_ORIGINAL_OFF equ 0x7C00

STACK_PTR               equ 0xFC00
MINIDOS_TEMP_LOAD_SEG   equ 0x3000 ; Test loading to another safe address
MINIDOS_FINAL_LOAD_SEG  equ 0x0000
MINIDOS_LOAD_OFF        equ 0x0000
MINIDOS_SECTORS_TO_READ equ 255 ; Read 255 sectors (almost 128KB)
FLOPPY_DRIVE_NUMBER     equ 0x00
OS_JUMP_SEG             equ 0x1FFF
OS_JUMP_OFF             equ 0x0000

; Macro to print a literal character, followed by CR+LF
%macro log_char 1
    push ax
    mov al, %1
    call print_al_char
    call print_crlf
    pop ax
%endmacro

%macro log_al 1
    push ax                 ; 呼び出し元のaxを保護
    push cx                 ; 呼び出し元のcxを保護

    ; 呼び出し時点のALの値をCLに一時保存
    mov cl, al

    ; 1. 引数の文字を出力
    mov al, %1              ; 引数の文字をALにロード
    call print_al_char      ; 文字を出力

    ; 2. 保存しておいたALの値を16進数で出力
    mov al, cl              ; 保存しておいたALの値をALに戻す
    call print_hex_byte     ; ALの中身を16進数で出力

    ; 3. 改行を送信
    call print_crlf

    pop cx                  ; cxを復元
    pop ax                  ; axを復元
%endmacro

%macro log_ax 1
    push ax                 ; Preserve original AX
    push bx                 ; Preserve original BX (used for temp storage of AX)
    push cx                 ; Preserve original CX (print_hex_byte uses it)
    push dx                 ; Preserve original DX (print_hex_byte uses it)

    mov bx, ax              ; Save original AX value into BX

    mov al, %1              ; Load character argument into AL
    call print_al_char      ; Print character

    ; Print high byte of original AX (now in BH)
    mov al, bh              ; Move high byte to AL
    call print_hex_byte     ; Print as hex

    ; Print low byte of original AX (now in BL)
    mov al, bl              ; Move low byte to AL
    call print_hex_byte     ; Print as hex

    call print_crlf         ; Print CR+LF

    pop dx                  ; Restore DX
    pop cx                  ; Restore CX
    pop bx                  ; Restore BX
    pop ax                  ; Restore AX
%endmacro

%macro dump_memory 2 ; segment, offset
    pusha
    push ds

    ; Log the address being dumped
    mov ax, %1
    log_ax '>' ; Address marker
    mov ax, %2
    log_ax ':' ; Address marker

    ; Set DS to the target segment for lodsb
    mov ax, %1
    mov ds, ax
    mov si, %2

    ; Loop and print bytes
    mov bx, 0x1000
%%dump_loop2:
    mov cx, 0x10
%%dump_loop:
    lodsb               ; Load byte from DS:SI into AL, increments SI
    call print_hex_byte
    mov al, ' '
    call print_al_char
    loop %%dump_loop
    call print_crlf
    dec bx
    jnz %%dump_loop2

    pop ds  ; Restore original DS
    popa    ; Restore general purpose registers
%endmacro

org 0x7C00

; ==============================================================================
; Main execution starts here, at the very beginning (0x7C00)
; ==============================================================================
start:
    ; Initialize segment registers and stack before using stack-dependent macros
    mov ax, 0x0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STACK_PTR ; Initialize SP

    ; Log the boot drive number (which is in DL)
    mov al, dl
    log_al 'A'

    log_char 'B'
 
    cli 
    cld 
    mov ax, BOOTLOADER_ORIGINAL_SEG 
    mov ds, ax
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov es, ax
    mov di, BOOTLOADER_ORIGINAL_OFF
    mov si, BOOTLOADER_ORIGINAL_OFF
    mov cx, 512/2
    rep movsw  ; es:di ← ds:si * cx
    log_char 'C'

    jmp BOOTLOADER_RELOCATE_SEG:relocated_code

; ==============================================================================
; This code runs from the new address (0x90000)
; ==============================================================================
relocated_code:
    log_char 'D'
    cli
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax ; Stack re-initialized to relocated segment
    mov sp, STACK_PTR ; Stack re-initialized to relocated segment
    ;sti

    ; mov ax, 0x4100
    ; mov bx, 0x55AA
    ; mov dl, 0x80        ; HDD
    ; int 0x13
    ; jc load_error ; CF=1 → 非対応
    ; mov ax, bx
    ; log_ax 'b'
    ; mov ax, cx
    ; log_ax 'c'

    ; Now, try to read
    log_char 'H'
    mov si, dap
    mov dl, 0x80
    mov ah, 0x42
    clc ; Clear carry flag before INT 13h call for safety
    int 0x13
    jc load_error
    
    log_char 'I'
    mov si, dap2
    mov dl, 0x80
    mov ah, 0x42
    clc ; Clear carry flag before INT 13h call for safety
    int 0x13
    jc load_error

    ;dump_memory 0x2000, 0x0000
    ;dump_memory 0x3000, 0x0000

    log_char 'J'
    mov ax, 0x2000
    mov ds, ax
    mov si, 0
    mov ax, 0x0000
    mov es, ax
    mov di, 0
    mov cx, 32768
    rep movsw  ; es:di ← ds:si * cx

    mov ax, 0x3000
    mov ds, ax
    mov si, 0
    mov ax, 0x1000
    mov es, ax
    mov di, 0
    mov cx, 32768 ; 0 means 65536 for rep movsw
    rep movsw  ; es:di ← ds:si * cx

    ;dump_memory 0x0000, 0x0000
    ;dump_memory 0x1000, 0x0000

    log_char 'K'
    push word OS_JUMP_SEG
    push word OS_JUMP_OFF
    retf

load_error:
    log_al 'e' ; Log error code in AL
    mov al, ah
    log_al 'e' ; Log error code in AL
.hang:
    hlt
    jmp .hang

; --- SUBROUTINES (placed after main execution flow) ---
print_al_char:
    push dx
    mov dx, COM1
    out dx, al
    pop dx
    ret
print_crlf:
    push ax
    mov al, 0x0D ; CR
    call print_al_char
    mov al, 0x0A ; LF
    call print_al_char
    pop ax
    ret
print_hex_byte:
    push ax
    push cx
    push dx
    mov cl, al
    shr al, 4
    call .to_hex_char
    call print_al_char
    mov al, cl
    and al, 0x0F
    call .to_hex_char
    call print_al_char
    pop dx
    pop cx
    pop ax
    ret
.to_hex_char:
    cmp al, 9
    jle .is_digit
    add al, 'A' - 10
    ret
.is_digit:
    add al, '0'
    ret

dap:
    db 0x10               ; size
    db 0x00               ; reserved
.sectors:
    dw 128
.offset:
    dw 0
.segment:
    dw 0x2000
.lba_lo:
    dd 1
.lba_hi:
    dd 0

dap2:
    db 0x10               ; size
    db 0x00               ; reserved
.sectors:
    dw 128
.offset:
    dw 0
.segment:
    dw 0x3000
.lba_lo:
    dd 129
.lba_hi:
    dd 0

; --- Padding and Boot Signature ---
times 510 - ($ - $$) db 0
dw 0xAA55
