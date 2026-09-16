; cbios80.asm
;
; CP/M 2.2 CBIOS for NEC PC-9801, V30 hardware 8080 emulation mode.
; Intel 8080 syntax only.
;
; HDD-enabled 62K version:
;   - A:..D: map to physical FDD units 0..3
;   - E:..F: map to the first two formatted CP/M-80 SCSI partitions
;   - HDD partitions are limited to 8192 allocation blocks (128 MiB)
;   - SELDSK always asks the native gateway to re-detect 2DD/2HD
;   - absent/unreadable drive returns HL=0000h
;   - DPH DPB pointer is changed per drive to 2DD or 2HD
;   - GVRAM write-back cache in native gateway
;   - IOBYTE logical routing in this 8080 CBIOS
;   - local PC-98 CRT/keyboard and serial TTY via native gateway
;   - ANSI/VT100 local-screen rendering implemented in native gateway
;
; CALLN 61h encoding: ED ED 61
;

VERS            EQU     22
MSIZE           EQU     62
BIAS            EQU     (MSIZE-20)*1024
CCP             EQU     3400H+BIAS
BDOS            EQU     CCP+0806H
BIOS            EQU     CCP+1600H

; Fixed private ABI used by the resident CCP/BDOS.
RESBOOT_ABI     EQU     0F7E0H
BOOTSEL_ABI     EQU     0F7E9H
BOOTDRV_ABI     EQU     0F7FCH

IOBYTE          EQU     0003H
CDISK           EQU     0004H
DMA_DEFAULT     EQU     0080H

SIO_DATA        EQU     030H
SIO_STAT        EQU     032H
ST_TXRDY        EQU     001H
ST_RXRDY        EQU     002H

SVC_INIT        EQU     0
SVC_READ128     EQU     1
SVC_WRITE128    EQU     2
SVC_SELECT      EQU     3
SVC_SYNC        EQU     4
SVC_SER_CONST   EQU     5
SVC_SER_GETC    EQU     6
SVC_SER_PUTC    EQU     7
SVC_LOCAL_CONST EQU     8
SVC_LOCAL_GETC  EQU     9
SVC_SCREEN_PUTC EQU     10
SVC_SER_OUTST   EQU     11
SVC_WBOOT_RELOAD EQU    12
SVC_HDD_CONFIG  EQU     16
SVC_GET_BOOT_SOURCE EQU  17
SVC_HDD_REMOUNT_REQUEST EQU 18

NDISKS          EQU     6
HDD_FIRST       EQU     4
HDD_ALV0        EQU     0F800H
HDD_ALV1        EQU     0FC00H

                ORG     BIOS

; ---------------------------------------------------------------------------
; CP/M 2.2 BIOS jump table, 17 entries.
; ---------------------------------------------------------------------------
BIOSBASE:       JMP     BOOT
                JMP     WBOOT
                JMP     CONST
                JMP     CONIN
                JMP     CONOUT
                JMP     LIST
                JMP     PUNCH
                JMP     READER
                JMP     HOME
                JMP     SELDSK
                JMP     SETTRK
                JMP     SETSEC
                JMP     SETDMA
                JMP     READ
                JMP     WRITE
                JMP     LISTST
                JMP     SECTRAN

; ---------------------------------------------------------------------------
; Cold/warm boot.
; Native INIT discovers FDD/HDD state and returns the logical boot drive
; number: 0..5 for A:..F:, or FFh on failure.
; ---------------------------------------------------------------------------
BOOT:
                LXI     SP,BIOS_STACK_TOP
                ; Default console is the local CRT/keyboard: CON:=CRT.
                MVI     A,01H
                STA     IOBYTE

                ; Native INIT discovers FDD media plus formatted SCSI
                ; partitions and returns the logical boot drive A:..F:.
                MVI     A,SVC_INIT
                DB      0EDH,0EDH,061H
                CPI     0FFH
                JZ      BOOT_FAIL
                STA     WBOOT_CONTEXT
                STA     CDISK
                STA     BOOT_DRIVE

                ; Let the gateway publish the dynamic HDD DPBs and clear the
                ; fixed 1-KiB allocation vectors at F800h and FC00h.
                LXI     D,HDD_CONFIG_TABLE
                MVI     A,SVC_HDD_CONFIG
                DB      0EDH,0EDH,061H
                ORA     A
                JNZ     BOOT_FAIL

                LDA     BOOT_DRIVE
                MOV     C,A

                ; Run the same SELDSK path used later at runtime.
                CALL    SELDSK
                MOV     A,H
                ORA     L
                JZ      BOOT_FAIL

                LXI     H,SIGNON
                CALL    PMSG
                JMP     GOCPM_COLD

BOOT_FAIL:
                LXI     H,MSG_INIT_FAIL
                CALL    PMSG
BOOT_HANG:      HLT
                JMP     BOOT_HANG

GOCPM_COMMON:
                MVI     A,0C3H
                STA     0000H
                LXI     H,WBOOT
                SHLD    0001H

                MVI     A,0C3H
                STA     0005H
                LXI     H,BDOS
                SHLD    0006H

                LXI     H,DMA_DEFAULT
                SHLD    DMA_ADDR
                RET

GOCPM_COLD:
                ; No current drive exists yet.  The logical boot drive returned
                ; by SVC_INIT becomes both page-zero TDRIVE/CDISK and CCP's C.
                CALL    GOCPM_COMMON
                CALL    FLUSH_BOOT_KEYS
                LDA     BOOT_DRIVE
                STA     CDISK
                MOV     C,A
                JMP     CCP

; Discard local-keyboard input left by the master-IPL menu.
; Require several consecutive quiet intervals before entering CCP so that
; a still-held selection key cannot reappear later through typematic repeat.
; Cold boot only: warm boot must not discard user input.
FLUSH_BOOT_KEYS:
                MVI     B,4
FBK_CHECK:
                MVI     A,SVC_LOCAL_CONST
                DB      0EDH,0EDH,061H
                ORA     A
                JZ      FBK_QUIET
                MVI     A,SVC_LOCAL_GETC
                DB      0EDH,0EDH,061H
                MVI     B,4
FBK_QUIET:
                LXI     D,0FFFFH
FBK_DELAY:
                DCX     D
                MOV     A,D
                ORA     E
                JNZ     FBK_DELAY
                DCR     B
                JNZ     FBK_CHECK
                RET

GOCPM_WARM:
                ; Restore the full user/current-drive byte captured at WBOOT entry.
                ; Do not force BOOT_DRIVE here: CCP expects C=(uuuudddd).
                CALL    GOCPM_COMMON
                LDA     BOOT_INFO
                STA     CDISK
                MOV     C,A
                JMP     CCP

WBOOT:
                LXI     SP,BIOS_STACK_TOP

                ; Page zero 0004h is CCP's user/current-drive byte.
                ; Preserve the full byte for CCP, and separately keep only the
                ; low-nibble drive for the fixed-size RESBOOT ABI.
                LDA     CDISK
                STA     BOOT_INFO
                ANI     0FH
                STA     WBOOT_CONTEXT

                ; SID/DDT may overlay CCP, so warm boot must restore CCP+BDOS.
                ; Native service also flushes the write-back cache first.
                MVI     A,SVC_WBOOT_RELOAD
                DB      0EDH,0EDH,061H
                CPI     2
                JZ      WBOOT_REMOUNTED
                ORA     A
                JNZ     CACHE_SYNC_FAIL
                JMP     GOCPM_WARM

WBOOT_REMOUNTED:
                LXI     D,HDD_CONFIG_TABLE
                MVI     A,SVC_HDD_CONFIG
                DB      0EDH,0EDH,061H
                ORA     A
                JNZ     CACHE_SYNC_FAIL
                JMP     GOCPM_WARM

CACHE_SYNC_FAIL:
                LXI     H,MSG_CACHE_FAIL
                CALL    PMSG
                JMP     BOOT_HANG

; ---------------------------------------------------------------------------
; CP/M IOBYTE logical-device routing.
;
; bits 1..0  CON: 00 TTY, 01 CRT, 10 BAT, 11 UC1
; bits 3..2  RDR: 00 TTY, 01 PTR, 10 UR1, 11 UR2
; bits 5..4  PUN: 00 TTY, 01 PTP, 10 UP1, 11 UP2
; bits 7..6  LST: 00 TTY, 01 CRT, 10 LPT, 11 UL1
;
; Physical IOBYTE mappings used by this BIOS:
;   TTY = PC-98 standard RS-232C
;   CRT = local PC-98 keyboard + CRT
;   RDR PTR/UR1/UR2 and PUN PTP/UP1/UP2 alias TTY
;   LST LPT/UL1 alias TTY; only LST:=CRT selects the local screen
;   BAT input follows RDR and output follows LST
;   UC1 input accepts local keyboard or TTY (local priority), output mirrors
;   to local screen and TTY.
; ---------------------------------------------------------------------------
CONST:
                LDA     IOBYTE
                ANI     03H
                JZ      CONST_TTY
                CPI     01H
                JZ      CONST_CRT
                CPI     02H
                JZ      READER_CONST
                ; UC1
                MVI     A,SVC_LOCAL_CONST
                DB      0EDH,0EDH,061H
                ORA     A
                RNZ
CONST_TTY:
                MVI     A,SVC_SER_CONST
                DB      0EDH,0EDH,061H
                RET
CONST_CRT:
                MVI     A,SVC_LOCAL_CONST
                DB      0EDH,0EDH,061H
                RET

CONIN:
                LDA     IOBYTE
                ANI     03H
                JZ      CONIN_TTY
                CPI     01H
                JZ      CONIN_CRT
                CPI     02H
                JZ      READER
                ; UC1: local keyboard has priority.
CONIN_UC1_WAIT:
                MVI     A,SVC_LOCAL_CONST
                DB      0EDH,0EDH,061H
                ORA     A
                JNZ     CONIN_CRT
                MVI     A,SVC_SER_CONST
                DB      0EDH,0EDH,061H
                ORA     A
                JZ      CONIN_UC1_WAIT
CONIN_TTY:
                MVI     A,SVC_SER_GETC
                DB      0EDH,0EDH,061H
                RET
CONIN_CRT:
                MVI     A,SVC_LOCAL_GETC
                DB      0EDH,0EDH,061H
                RET

; C = output character.
CONOUT:
                LDA     IOBYTE
                ANI     03H
                JZ      CONOUT_TTY
                CPI     01H
                JZ      CONOUT_CRT
                CPI     02H
                JZ      LIST
                ; UC1: mirror to local CRT and TTY.
                MVI     A,SVC_SCREEN_PUTC
                DB      0EDH,0EDH,061H
CONOUT_TTY:
                MVI     A,SVC_SER_PUTC
                DB      0EDH,0EDH,061H
                RET
CONOUT_CRT:
                MVI     A,SVC_SCREEN_PUTC
                DB      0EDH,0EDH,061H
                RET

; RDR: all four assignments currently alias TTY.
READER_CONST:
                MVI     A,SVC_SER_CONST
                DB      0EDH,0EDH,061H
                RET
READER:
                MVI     A,SVC_SER_GETC
                DB      0EDH,0EDH,061H
                RET

; PUN: all four assignments currently alias TTY.
PUNCH:
                MVI     A,SVC_SER_PUTC
                DB      0EDH,0EDH,061H
                RET

; LST: CRT selects local screen; TTY/LPT/UL1 alias TTY.
LIST:
                LDA     IOBYTE
                ANI     0C0H
                CPI     040H
                JZ      LIST_CRT
                MVI     A,SVC_SER_PUTC
                DB      0EDH,0EDH,061H
                RET
LIST_CRT:
                MVI     A,SVC_SCREEN_PUTC
                DB      0EDH,0EDH,061H
                RET

LISTST:
                LDA     IOBYTE
                ANI     0C0H
                CPI     040H
                JZ      LISTST_READY
                MVI     A,SVC_SER_OUTST
                DB      0EDH,0EDH,061H
                RET
LISTST_READY:
                MVI     A,0FFH
                RET

; ---------------------------------------------------------------------------
; Disk setup calls.
; ---------------------------------------------------------------------------
HOME:
                LXI     H,0
                SHLD    CUR_TRACK
                RET

; C = drive 0..7. Return HL=DPH or 0000h.
; Native SELECT returns 1=2DD, 2=2HD, 3=HDD.
SELDSK:
                MOV     A,C
                CPI     NDISKS
                JNC     SELDSK_BAD

                ; H maps to native BH and carries the logical drive number.
                MOV     H,C
                MVI     A,SVC_SELECT
                DB      0EDH,0EDH,061H

                CPI     1
                JZ      SELDSK_2DD
                CPI     2
                JZ      SELDSK_2HD
                CPI     3
                JZ      SELDSK_HDD
                JMP     SELDSK_BAD

SELDSK_2DD:
                LXI     D,DPB_2DD
                JMP     SELDSK_APPLY_FDD
SELDSK_2HD:
                LXI     D,DPB_2HD

SELDSK_APPLY_FDD:
                CALL    SELDSK_DPH
                ; Update DPH+0Ah (DPB pointer), preserving DPH for return.
                PUSH    H
                LXI     B,10
                DAD     B
                MOV     M,E
                INX     H
                MOV     M,D
                POP     H
                RET

SELDSK_HDD:
                ; HDD DPHs already point at gateway-filled per-drive DPBs.
                CALL    SELDSK_DPH
                RET

SELDSK_DPH:
                MOV     A,C
                STA     CUR_DRIVE
                MOV     L,C
                MVI     H,0
                DAD     H
                LXI     B,DPH_TABLE
                DAD     B
                MOV     A,M
                INX     H
                MOV     H,M
                MOV     L,A
                RET

SELDSK_BAD:
                LXI     H,0
                RET

; BC = logical side-track 0..159.
SETTRK:
                MOV     H,B
                MOV     L,C
                SHLD    CUR_TRACK
                RET

; BC = 16-bit logical 128-byte sector within the current BIOS track.
SETSEC:
                MOV     H,B
                MOV     L,C
                SHLD    CUR_SECTOR
                RET

; BC = DMA offset in flat 8080 window.
SETDMA:
                MOV     H,B
                MOV     L,C
                SHLD    DMA_ADDR
                RET

SECTRAN:
                MOV     A,D
                ORA     E
                JNZ     SECTRAN_TABLE
                MOV     H,B
                MOV     L,C
                RET
SECTRAN_TABLE:
                XCHG
                DAD     B
                MOV     L,M
                MVI     H,0
                RET

; ---------------------------------------------------------------------------
; READ/WRITE one CP/M 128-byte record through CALLN 61h.
;
; Native register mapping:
;   HL -> BX = 16-bit BIOS track
;   BC -> CX = 16-bit logical sector within track
;   DE       = DMA offset in the flat CP/M window
; ---------------------------------------------------------------------------
READ:
                LHLD    DMA_ADDR
                XCHG
                LHLD    CUR_SECTOR
                MOV     B,H
                MOV     C,L
                LHLD    CUR_TRACK
                MVI     A,SVC_READ128
                DB      0EDH,0EDH,061H
                RET

WRITE:
                LHLD    DMA_ADDR
                XCHG
                LHLD    CUR_SECTOR
                MOV     B,H
                MOV     C,L
                LHLD    CUR_TRACK
                MVI     A,SVC_WRITE128
                DB      0EDH,0EDH,061H
                RET

; ---------------------------------------------------------------------------
; Messages / DPH / DPB / work area.
; ---------------------------------------------------------------------------
PMSG:
                MOV     A,M
                ORA     A
                RZ
                MOV     C,A
                CALL    CONOUT
                INX     H
                JMP     PMSG

SIGNON:         DB      13,10,"62k CP/M-80 v2.2 for PC-9801 series",13,10,0
MSG_INIT_FAIL:  DB      13,10,"PC-98 disk init failed",13,10,0
MSG_CACHE_FAIL: DB      13,10,"PC-98 disk sync failed",13,10,0

BOOT_INFO:      DB      0
WBOOT_CONTEXT:  DB      0
CUR_DRIVE:      DB      0
CUR_TRACK:      DW      0
CUR_SECTOR:     DW      0
DMA_ADDR:       DW      DMA_DEFAULT

DPH_TABLE:      DW      DPH0,DPH1,DPH2,DPH3,DPH4,DPH5

; DPH: XLT, 3 scratch words, DIRBUF, DPB, CSV, ALV.
DPH0:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_2DD
                DW      CSV0
                DW      ALV0

DPH1:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_2DD
                DW      CSV1
                DW      ALV1

DPH2:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_2DD
                DW      CSV2
                DW      ALV2

DPH3:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_2DD
                DW      CSV3
                DW      ALV3

; HDD DPHs use fixed 1-KiB ALVs above the 62K CP/M memory limit.
; Fixed disks use CKS=0, so the CSV pointer is zero.
DPH4:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_HDD0
                DW      0
                DW      HDD_ALV0
DPH5:           DW      0
                DW      0,0,0
                DW      DIRBUF
                DW      DPB_HDD1
                DW      0
                DW      HDD_ALV1
; Gateway-filled HDD DPBs: SPT,BSH,BLM,EXM,DSM,DRM,AL0,AL1,CKS,OFF.
DPB_HDD0:       DS      15
DPB_HDD1:       DS      15

; Two entries: DPB pointer, ALV pointer. Passed to SVC_HDD_CONFIG.
HDD_CONFIG_TABLE:
                DW      DPB_HDD0,HDD_ALV0
                DW      DPB_HDD1,HDD_ALV1

DPB_2DD:
                DW      32              ; SPT: 8 x 512-byte sectors / side
                DB      4               ; BSH: 2 KiB block
                DB      15              ; BLM
                DB      0               ; EXM
                DW      311             ; DSM
                DW      127             ; DRM
                DB      0C0H            ; AL0
                DB      000H            ; AL1
                DW      32              ; CKS
                DW      4               ; OFF

DPB_2HD:
                DW      60              ; SPT: 15 x 512-byte sectors / side
                DB      5               ; BSH: 4 KiB block
                DB      31              ; BLM
                DB      1               ; EXM
                DW      293             ; DSM
                DW      127             ; DRM
                DB      080H            ; AL0
                DB      000H            ; AL1
                DW      32              ; CKS
                DW      3               ; OFF

DIRBUF:         DS      128
CSV0:           DS      32
CSV1:           DS      32
CSV2:           DS      32
CSV3:           DS      32
ALV0:           DS      39
ALV1:           DS      39
ALV2:           DS      39
ALV3:           DS      39

BIOS_STACK:     DS      96
BIOS_STACK_TOP:

BIOS_END:
                ; Keep normal BIOS code/data below F7E0h.
                DS      05E0H-(BIOS_END-BIOS)

; ---------------------------------------------------------------------------
; Private resident-OS ABI.
;
; RESBOOT (F7E0h):
;   Called by CCP instead of its normal RESDSK wrapper.
;   Supply the physical boot drive as the otherwise-unused E parameter of
;   BDOS function 13.  BDOS FBASE1 copies E to C before dispatch, so the
;   size-preserving RSTDSK patch MOV A,C receives the boot drive.
;
; BOOTSEL (F7E9h):
;   Select the physical boot drive with ordinary BDOS function 14.
;   Used only by CCP DELBATCH in place of its hard-coded A: selection.
; ---------------------------------------------------------------------------
RESBOOT_PRIVATE:
                ; Fixed ABI at F7E0h.  This routine must be exactly 9 bytes so
                ; BOOTSEL_PRIVATE remains at F7E9h.
                ; WBOOT_CONTEXT always contains only the low-nibble drive.
                MVI     C,13
                LDA     WBOOT_CONTEXT
                MOV     E,A
                JMP     BDOS

                DS      05E9H-($-BIOS)
BOOTSEL_PRIVATE:
                LDA     BOOT_DRIVE
                MOV     E,A
                MVI     C,14
                JMP     BDOS

                DS      05FCH-($-BIOS)
BOOT_DRIVE:     DB      0
                DS      0600H-($-BIOS)
