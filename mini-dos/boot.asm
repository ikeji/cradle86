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

org 0x7C00

; ==============================================================================
; Main execution starts here, at the very beginning (0x7C00)
; ==============================================================================
start:
    ; Save the boot drive number passed by the BIOS in DL into BH for later use
    mov bh, dl

    ; Set DS explicitly to ensure it points to 0x7C00
    mov ax, 0x07C0
    mov ds, ax

    log_char 'B'
    
    log_char '1'
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov es, ax
    xor di, di
    xor si, si ; Source is start of bootloader (0x7C00), which is offset 0 from CS
    mov cx, 256
    rep movsw
    log_char '2'

    jmp BOOTLOADER_RELOCATE_SEG:(relocated_code - start)

; ==============================================================================
; This code runs from the new address (0x90000)
; ==============================================================================
relocated_code:
    log_char 'S'
    cli
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STACK_PTR
    sti

    log_char 'L'
    
    ; First, reset the disk system
    mov ah, 0x00
    mov dl, bh ; Use saved boot drive number
    int 0x13
    mov cl, al ; Save AL from reset
    mov al, cl ; Restore AL from CL for log_al
    log_al 'R' ; Log Reset attempt and AL from reset
    mov cl, 0x02 ; Restore CL for sector number

    ; Now, try to read
    mov ah, 0x02
    mov al, MINIDOS_SECTORS_TO_READ
    mov ch, 0
    mov cl, 2 ; Back to original sector 2
    mov dl, bh  ; Restore boot drive number from BH
    mov dh, 0   ; Set head number to 0
    mov bx, MINIDOS_TEMP_LOAD_SEG
    mov es, bx
    mov bx, MINIDOS_LOAD_OFF
    clc ; Clear carry flag before INT 13h call for safety
    int 0x13
    jc load_error

    log_char 'C'
    
    log_char 'M'
    mov ax, MINIDOS_TEMP_LOAD_SEG
    mov ds, ax
    mov si, MINIDOS_LOAD_OFF
    mov ax, MINIDOS_FINAL_LOAD_SEG
    mov es, ax
    mov di, MINIDOS_LOAD_OFF
    mov cx, 0 ; 0 means 65536 for rep movsw
    rep movsw
    log_char 'D'

    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax

    log_char 'J'
    push word OS_JUMP_SEG
    push word OS_JUMP_OFF
    retf

load_error:
    log_al 'E' ; Log error code in AL
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
