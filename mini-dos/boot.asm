bits 16

; --- DEFINITIONS (must come before org) ---
COM1                    equ 0x3F8
BOOTLOADER_RELOCATE_SEG equ 0x9000
STACK_PTR               equ 0xFC00
MINIDOS_TEMP_LOAD_SEG   equ 0x8000 ; Test loading to another safe address
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

org 0x7C00

; ==============================================================================
; Main execution starts here, at the very beginning (0x7C00)
; ==============================================================================
start:
    ; Save the boot drive number passed by the BIOS in DL into BH for later use
    mov bh, dl

    ; Initialize segment registers and stack before using stack-dependent macros
    mov ax, 0x07C0
    mov ds, ax
    mov es, ax ; ES is also used before relocation by movsw
    mov ss, ax ; Initialize SS
    mov sp, STACK_PTR ; Initialize SP

    ; Log the boot drive number (which is in DL)
    mov al, dl
    log_al 'A'

    log_char 'B'
    
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov es, ax
    xor di, di
    xor si, si ; Source is start of bootloader (0x7C00), which is offset 0 from CS
    mov cx, 256
    rep movsw
    log_char 'C'

    jmp BOOTLOADER_RELOCATE_SEG:(relocated_code - start)

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
    sti

    ; Log Stack Segment (SS)
    mov ax, ss
    log_ax 'E'

    ; ; First, reset the disk system
    ; log_char 'F'
    ; mov ah, 0x00
    ; mov dl, bh ; Use saved boot drive number
    ; int 0x13
    ; mov al, ah
    ; log_al 'r' ; Log Reset attempt and AL from reset

    ; ; Get result status
    ; log_char 'G'
    ; mov ah, 0x01
    ; mov dl, bh ; Use saved boot drive number
    ; int 0x13
    ; mov al, ah
    ; log_al 'r' ; Log Reset attempt and AL from status

    ; Now, try to read
    log_char 'H'
    mov ah, 0x02
    mov al, 0x80
    mov ch, 0 ; Cylinder
    mov cl, 2 ; Back to original sector 2
    mov dl, bh  ; Restore boot drive number from BH
    mov dh, 0   ; Set head number to 0
    mov bx, MINIDOS_TEMP_LOAD_SEG
    mov es, bx
    mov bx, MINIDOS_LOAD_OFF
    clc ; Clear carry flag before INT 13h call for safety
    int 0x13
    jc load_error
    log_al 's' ; Log error code in AL
    mov al, ah
    log_al 's' ; Log error code in AL

    ; ; Get result status
    ; log_char 'G'
    ; mov ah, 0x01
    ; mov dl, bh ; Use saved boot drive number
    ; int 0x13
    ; mov al, ah
    ; log_al 'r' ; Log Reset attempt and AL from status

    log_char 'I'
    mov ah, 0x02
    mov al, 0x80
    mov ch, 0
    mov cl, 2
    mov dh, 0   ; Set head number to 0
    mov bx, MINIDOS_TEMP_LOAD_SEG
    mov es, bx
    mov bx, MINIDOS_LOAD_OFF
    clc ; Clear carry flag before INT 13h call for safety
    int 0x13
    jc load_error
    log_al 's' ; Log error code in AL
    mov al, ah
    log_al 's' ; Log error code in AL

    ; Get result status
    log_char 'G'
    mov ah, 0x01
    mov dl, bh ; Use saved boot drive number
    int 0x13
    mov al, ah
    log_al 'r' ; Log Reset attempt and AL from status

    log_char 'J'
    mov ax, MINIDOS_TEMP_LOAD_SEG
    mov ds, ax
    mov si, MINIDOS_LOAD_OFF
    mov ax, MINIDOS_FINAL_LOAD_SEG
    mov es, ax
    mov di, MINIDOS_LOAD_OFF
    mov cx, 0 ; 0 means 65536 for rep movsw
    rep movsw

    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax

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

; --- Padding and Boot Signature ---
times 510 - ($ - $$) db 0
dw 0xAA55
