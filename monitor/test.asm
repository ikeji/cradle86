; V30 (8086) Test Program for Pico Monitor
; Calculates 1+2 and stores the result '3' at address 0x0100.
cpu 8086        ; Specify 8086 mode
org 0           ; Assume code is loaded at address 0

; ==========================================
;  Main Program (at 0x0000)
; ==========================================
start:
    mov al, 1       ; Load 1 into AL register
    add al, 2       ; Add 2 to AL (result is 3)
    
    mov [0x0100], al ; Write the result to memory address 0x0100
                     ; This will appear in the bus log as a WR cycle.
    out 5, al      ; Output the result to IO port 5

    hlt             ; Halt the CPU. The Pico will detect this via timeout.

; ==========================================
;  Padding up to the reset vector
; ==========================================
; Fill the space from the current address ($) up to just before
; the reset vector (0x1FFF0) with NOP (0x90) instructions.
; `$$` is the start of the section (0), so `$` is the current offset.
times 0x1FFF0 - ($ - $$) db 0x90

; ==========================================
;  Reset Vector (at 0xFFF0)
; ==========================================
; The V30 CPU starts execution here (CS:IP = FFFF:0000) after a reset.
; This location is mapped to 0x1FFF0 in our 128KB RAM simulation.
reset_vec:
    jmp 0x0000:0x0000  ; Jump to address 0 (where `start` is)
    ; The resulting machine code is: EA 00 00 00 00

; ==========================================
;  Fill the rest of the file to make it exactly 128KB
; ==========================================
times 0x20000 - ($ - $$) db 0x90
