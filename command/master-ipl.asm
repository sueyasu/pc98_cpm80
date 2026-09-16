; master-ipl.asm
; PC-9801 SCSI HDD CP/M-only master IPL menu.
;
; NASM syntax, 8086/V30 compatible, target size exactly 512 bytes.
;
; Policy:
;   - Scan only this HDD's 16 partition entries.
;   - Show bootable type-70h CP/M-80 / CP/M-86 partitions.
;   - CP/M-80 / CP/M-86 are distinguished by the HDFORMAT sysm label.
;   - Menu entry format: "1:S0-P01 CP/M-80".
;   - N: search higher SCSI IDs for the next "CPM8MIPL" master IPL and chain.
;   - NEC/DOS masters are intentionally skipped.
;
; PC-98 partition layout used here:
;   +00 MID (95h = project bootable CP/M marker)
;   +01 SID (low 7 bits 70h = CP/M)
;   +04 IPL sector, +05 IPL head, +06 IPL cylinder
;   +10 sysm = "CP/M-80         " or "CP/M-86         "
;
; Identification layout retained:
;   +00FE = 55 AA
;   +0100 = "CPM8MIPL"
;   +0108 = version word
;   +01FE = 55 AA
; Build:
;   nasm -f bin master-ipl.asm -o MASTERIPL80.BIN

bits 16
cpu 8086
org 0x8000

BOOT_DAUA        equ 0x0584
SELF_ADDR        equ 0x8000
PT_ADDR          equ 0x8200
IPL_SEG          equ 0x07c0
IPL_ADDR         equ 0x7c00
TEXT_SEG         equ 0xa000

SECTOR_BYTES     equ 512
PART_COUNT       equ 16
PART_SIZE        equ 32
BOOT_MARK        equ 0x95
CPM_SYS          equ 0x70
MAX_RETRY        equ 5
LAST_SCSI_DA     equ 0xa6
ROW_BYTES        equ 160
MASTER_VERSION   equ 4

start:
        ; Relocate the whole sector to 0000:8000.
        cli
        push    cs
        pop     ds
        xor     si,si
        xor     ax,ax
        mov     es,ax
        mov     di,SELF_ADDR
        mov     cx,SECTOR_BYTES/2
        cld
        rep     movsw
        jmp     0x0000:relocated

relocated:
        xor     ax,ax
        mov     ds,ax
        mov     es,ax
        mov     ss,ax
        mov     sp,0x9000
        sti
        cld

        mov     al,[BOOT_DAUA]
        mov     [boot_drive],al

        ; Read this HDD's partition table, absolute C0/H0/S1.
        mov     bp,PT_ADDR
        xor     cx,cx
        mov     dx,1
        call    read_sector
        jc      boot_error
        jmp     show_menu

; AL = 1-based CP/M candidate number.  Return SI = partition entry.
find_nth_cpm:
        mov     dl,al
        mov     si,PT_ADDR
        mov     cx,PART_COUNT
.find:
        call    is_cpm
        jc      .skip
        dec     dl
        jz      .found
.skip:
        add     si,PART_SIZE
        loop    .find
        jmp     boot_error
.found:
        ret

; SI -> partition entry.  CF=0 for project bootable CP/M-80/86 entry.
is_cpm:
        cmp     byte [si+0x00],BOOT_MARK
        jne     .no
        mov     al,[si+0x01]
        and     al,0x7f
        cmp     al,CPM_SYS
        jne     .no
        mov     al,[si+0x16]            ; '0' or '6' in "CP/M-8x"
        cmp     al,'0'
        je      .yes
        cmp     al,'6'
        jne     .no
.yes:
        clc
        ret
.no:
        stc
        ret

; SI = selected partition entry.
boot_partition:
        mov     dl,[si+0x04]
        mov     dh,[si+0x05]
        mov     cx,[si+0x06]
        mov     ax,IPL_SEG
        mov     es,ax
        xor     bp,bp
        call    read_sector
        jc      boot_error

        ; BOOT_DAUA already names this HDD; preserve AL for the IPL.
        mov     al,[boot_drive]
        jmp     IPL_SEG:0x0000

; N: find the next higher SCSI ID containing our own common master IPL.
chain_next:
        inc     byte [boot_drive]
        cmp     byte [boot_drive],LAST_SCSI_DA+1
        jae     boot_error

        mov     ax,IPL_SEG
        mov     es,ax
        xor     bp,bp
        xor     cx,cx
        xor     dx,dx
        call    read_sector
        jc      chain_next

        ; Compare the 8-byte project magic at +0100h.
        mov     si,SELF_ADDR+0x0100
        mov     di,0x0100
        mov     cx,4
        repe    cmpsw
        jne     chain_next

        mov     al,[boot_drive]
        mov     [BOOT_DAUA],al
        jmp     IPL_SEG:0x0000

; Inputs: ES:BP=buffer, CX=cylinder, DH=head, DL=sector.
read_sector:
        mov     di,MAX_RETRY
.retry:
        push    es
        push    bp
        push    cx
        push    dx
        mov     bx,SECTOR_BYTES
        mov     al,[boot_drive]
        mov     ah,0x06
        push    di
        push    ds
        int     0x1b
        pop     ds
        pop     di
        pop     dx
        pop     cx
        pop     bp
        pop     es
        jnc     .ok
        dec     di
        jnz     .retry
        ret
.ok:
        ret

boot_error:
        cli
.hang:
        hlt
        jmp     .hang

boot_drive      db 0
boot_count      db 0

; Preserve the low project signature.
times 0x0fe-($-$$) db 0
dw 0xaa55

times 0x0100-($-$$) db 0
db 'CPM8MIPL'
dw MASTER_VERSION

; ---------------------------------------------------------------------------
; Menu / display helpers.
; ---------------------------------------------------------------------------
show_menu:
        ; Clear text screen and enable text display.
        mov     dx,0xe120
        mov     ah,0x16
        int     0x18
        mov     ah,0x0c
        int     0x18

        mov     ax,TEXT_SEG
        mov     es,ax
        xor     bx,bx                  ; row byte offset
        mov     byte [boot_count],0
        mov     si,PT_ADDR
        mov     cx,PART_COUNT
        mov     bp,1                   ; physical partition number

.menu_scan:
        call    is_cpm
        jc      .menu_next

        inc     byte [boot_count]
        push    cx                     ; display helpers use CX
        push    si                     ; preserve partition-table scan pointer
        push    si                     ; second copy for type access
        mov     di,bx
        mov     al,[boot_count]
        call    index_to_key
        call    vram_putc
        mov     si,msg_id
        call    vram_puts

        mov     al,[boot_drive]
        and     al,0x0f
        add     al,'0'
        call    vram_putc
        mov     al,'-'
        call    vram_putc
        mov     al,'P'
        call    vram_putc

        mov     ax,bp
        aam
        add     ax,0x3030
        xchg    al,ah
        call    vram_putc
        mov     al,ah
        call    vram_putc
        mov     si,msg_cpm
        call    vram_puts

        ; Type digit comes from "CP/M-80" / "CP/M-86" sysm.
        pop     si                     ; partition entry
        mov     al,[si+0x16]
        call    vram_putc
        add     bx,ROW_BYTES
        pop     si                     ; restore scan pointer
        pop     cx

.menu_next:
        inc     bp
        add     si,PART_SIZE
        loop    .menu_scan

        ; N: Next CP/M IPL.
        mov     di,bx
        mov     al,'N'
        call    vram_putc
        mov     si,msg_next
        call    vram_puts

.wait_key:
        mov     ah,0
        int     0x18
        cmp     al,'1'
        jb      .letter
        cmp     al,'9'
        ja      .letter
        sub     al,'0'
        jmp     .check
.letter:
        and     al,0xdf
        cmp     al,'N'
        je      chain_next
        cmp     al,'A'
        jb      .wait_key
        cmp     al,'G'
        ja      .wait_key
        sub     al,'A'-10
.check:
        or      al,al
        jz      .wait_key
        cmp     al,[boot_count]
        ja      .wait_key
        call    find_nth_cpm
        jmp     boot_partition

; AL=1..16 -> '1'..'9','A'..'G'.
index_to_key:
        cmp     al,9
        jbe     .digit
        add     al,'A'-10
        ret
.digit:
        add     al,'0'
        ret

vram_putc:
        mov     [es:di],al
        add     di,2
        ret

vram_puts:
.next:
        lodsb
        or      al,al
        jz      .done
        call    vram_putc
        jmp     .next
.done:
        ret

msg_id          db ':S',0
msg_cpm         db ' CP/M-8',0
msg_next        db ': Next CP/M IPL',0

times 0x1fe-($-$$) db 0
dw 0xaa55
