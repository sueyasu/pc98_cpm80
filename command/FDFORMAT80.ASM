; FDFORMAT80.ASM
; ---------------------------------------------------------------------------
; PC-9801 CP/M-80 FDFORMAT for NEC V30 8080-emulation CP/M 2.2
;
; Ported from FDFORMAT_0914.A86; preserves its embedded-FDIPL /S model
; using external INCLUDE file FDIPL80.INC.
;
; User interface:
;   FDFORMAT A:             CP/M data disk, density auto-detected
;   FDFORMAT /S A:          bootable CP/M-80 system disk
;   FDFORMAT /L A:          low-level format only
;   FDFORMAT A: /2DD        force 2DD if target is unformatted
;   FDFORMAT A: /2HD        force 2HD if target is unformatted
; Options may begin with '/' or '-'.
;
; Target formats:
;   2DD: 80 cyl x 2 heads x 8  x 512 bytes, CP/M SPT=32, OFF=4
;   2HD: 80 cyl x 2 heads x 15 x 512 bytes, CP/M SPT=60, OFF=3
;
; /S source:
;   The CP/M-80 FD IPL is embedded in this COM file, so /S does not depend
;   on the boot source containing an FDD IPL.  The clean payload is obtained
;   from the actual cold-boot source reported by gateway86.asm; both FDD and
;   HDD boot sources are supported.  The payload is read twice and verified:
;       16 sectors gateway + 14 sectors resident = 30 sectors
;   Live CCP/BDOS RAM is never copied.
;
; Hardware:
;   All PC-98 ROM BIOS INT 1Bh calls are executed in native V30 mode through
;   gateway service SVC_RAW_INT1B.  No direct PC-98 BIOS interrupt is issued
;   while the CPU is in 8080 emulation mode.
;
; Required gateway:
;   gateway86.asm
;
; Build:
;   asm8080 FDFORMAT80.ASM
; ---------------------------------------------------------------------------

BDOS            EQU     0005H
CMDLEN          EQU     0080H
CMDTAIL         EQU     0081H
BOOTDRV_ABI     EQU     0F7FCH  ; cbios80.asm private boot-drive byte
CDISK           EQU     0004H   ; CP/M page-zero current logical drive

SVC_SYNC        EQU     04H
SVC_WBOOT       EQU     0CH
SVC_RAW_INT1B   EQU     0DH
SVC_CACHE_RESET EQU     0EH
SVC_GET_FDD_INFO EQU    0FH
SVC_GET_BOOT_SOURCE EQU 11H
CALLN_VEC       EQU     061H

MODE_DATA       EQU     0
MODE_SYS        EQU     1
MODE_LOW        EQU     2

MEDIA_AUTO      EQU     0
MEDIA_2DD       EQU     1
MEDIA_2HD       EQU     2

SIDES_TOTAL     EQU     160
DIR_SECTORS     EQU     8
SECTOR_SIZE     EQU     512
PAYLOAD_SECTORS EQU     30      ; gateway16 + resident14; IPL is embedded
MAX_SYS_SECTORS EQU     45      ; 2HD reserved area
MAX_SYS_BYTES   EQU     23040
MAX_RETRY       EQU     10
FORMAT_FILL     EQU     0E5H
PART_SIZE       EQU     32
PART_COUNT      EQU     16
CPM_SYS         EQU     070H

; RAW request-frame fields are addressed by the real labels
; RAW_AX..RAW_FLAGS declared in the data area below.
RAW_SIZE        EQU     12

                ORG     0100H

START:
                LXI     SP,STACK_TOP
                LXI     D,MSG_TITLE
                CALL    PUTS

                CALL    PARSE_TAIL
                JNC     PARSED
                LXI     D,MSG_USAGE
                CALL    PUTS
                JMP     EXIT_PROGRAM

PARSED:
                CALL    SHOW_SELECTION
                LXI     D,MSG_WARN
                CALL    PUTS
                CALL    GETC
                CALL    UPPER
                CPI     'Y'
                JZ      CONFIRMED
                CALL    CRLF
                LXI     D,MSG_ABORT
                CALL    PUTS
                JMP     EXIT_PROGRAM

CONFIRMED:
                CALL    CRLF

                ; Commit normal BIOS cache and invalidate all FDD cache slots
                ; before any raw media operation.
                CALL    CACHE_RESET_ALL
                JNC     CACHE_READY
                LXI     D,MSG_CACHEERR
                CALL    PUTS
                JMP     EXIT_PROGRAM
CACHE_READY:

                ; /S must save the clean system image before target insertion.
                LDA     MODE
                CPI     MODE_SYS
                JNZ     NO_SAVE_SYSTEM
                LXI     D,MSG_SAVE
                CALL    PUTS
                CALL    SAVE_SYSTEM_AREA
                JNC     NO_SAVE_SYSTEM
                LXI     D,MSG_READERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT_PROGRAM

NO_SAVE_SYSTEM:
                LXI     D,MSG_INSERT1
                CALL    PUTS
                LDA     DRIVE
                ADI     'A'
                MOV     E,A
                MVI     C,2
                CALL    BDOS
                LXI     D,MSG_INSERT2
                CALL    PUTS
                CALL    WAIT_RETURN

                CALL    SELECT_TARGET_MEDIA
                JNC     TARGET_MEDIA_READY
                LDA     TARGET_ERROR
                CPI     2
                JZ      TARGET_MEDIA_MISMATCH
                LXI     D,MSG_MEDIA_UNKNOWN
                CALL    PUTS
                JMP     BEFORE_ERROR_EXIT
TARGET_MEDIA_MISMATCH:
                LXI     D,MSG_MEDIA_MISMATCH
                CALL    PUTS
                JMP     BEFORE_ERROR_EXIT

TARGET_MEDIA_READY:
                CALL    SHOW_TARGET_MEDIA
                LXI     D,MSG_FORMAT
                CALL    PUTS
                CALL    FORMAT_DISK
                JNC     FORMAT_OK

                LXI     D,MSG_FMTERR
                CALL    PUTS
                LDA     FMT_SIDE
                CALL    HEX8
                CALL    SHOW_STATUS
                JMP     BEFORE_ERROR_EXIT

FORMAT_OK:
                CALL    CRLF
                LXI     D,MSG_FMTOK
                CALL    PUTS

                LDA     MODE
                CPI     MODE_LOW
                JZ      DONE_LOW

                CPI     MODE_SYS
                JNZ     INIT_DIRECTORY

                LXI     D,MSG_WRITESYS
                CALL    PUTS
                CALL    RESTORE_SYSTEM_AREA
                JNC     SYSTEM_WRITTEN
                LXI     D,MSG_WRITESYSERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     BEFORE_ERROR_EXIT

SYSTEM_WRITTEN:
                LXI     D,MSG_VERIFYSYS
                CALL    PUTS
                CALL    VERIFY_DEST_SYSTEM
                JNC     INIT_DIRECTORY
                LXI     D,MSG_VERIFYSYSERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     BEFORE_ERROR_EXIT

INIT_DIRECTORY:
                LXI     D,MSG_DIR
                CALL    PUTS
                CALL    INITIALIZE_DIRECTORY
                JNC     FORMATTED_DONE
                LXI     D,MSG_DIRERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     BEFORE_ERROR_EXIT

FORMATTED_DONE:
                LDA     MODE
                CPI     MODE_SYS
                JZ      DONE_SYS
                LXI     D,MSG_DONE_DATA
                CALL    PUTS
                JMP     BEFORE_EXIT

DONE_SYS:
                LXI     D,MSG_DONE_SYS
                CALL    PUTS
                JMP     BEFORE_EXIT

DONE_LOW:
                LXI     D,MSG_DONE_LOW
                CALL    PUTS

BEFORE_EXIT:
                JMP     RESET_AND_EXIT

BEFORE_ERROR_EXIT:
RESET_AND_EXIT:
                ; Invalidate raw-media target cache again.
                CALL    CACHE_RESET_ALL

                ; This CP/M-80 BDOS has a private extension to function 13:
                ; E must contain the saved boot-drive value.  Do not leave E as
                ; scratch state from the formatter, or ACTIVE can become an
                ; invalid drive (for example 09h -> "Bdos Err On 9: Select").
                LDA     BOOTDRV_ABI
                MOV     E,A
                MVI     C,13
                CALL    BDOS

EXIT_PROGRAM:
                MVI     C,0
                CALL    BDOS
                HLT

; ---------------------------------------------------------------------------
; Command tail parser.
; ---------------------------------------------------------------------------
PARSE_TAIL:
                MVI     A,0FFH
                STA     DRIVE
                XRA     A
                STA     MODE
                STA     MODE_SEEN
                STA     MEDIA_REQUEST

                LDA     CMDLEN
                MOV     B,A
                LXI     H,CMDTAIL
PT_LOOP:
                MOV     A,B
                ORA     A
                JZ      PT_DONE
                MOV     A,M
                CPI     ' '
                JZ      PT_SKIP
                CPI     9
                JZ      PT_SKIP
                CPI     '/'
                JZ      PT_OPTION
                CPI     '-'
                JZ      PT_OPTION

                ; Drive token A:..D:, colon optional.
                CALL    UPPER
                CPI     'A'
                JC      PT_BAD
                CPI     'E'
                JNC     PT_BAD
                LDA     DRIVE
                CPI     0FFH
                JNZ     PT_BAD
                MOV     A,M
                CALL    UPPER
                SUI     'A'
                STA     DRIVE
                INX     H
                DCR     B
                MOV     A,B
                ORA     A
                JZ      PT_LOOP
                MOV     A,M
                CPI     ':'
                JNZ     PT_LOOP
                INX     H
                DCR     B
                JMP     PT_LOOP

PT_OPTION:
                INX     H
                DCR     B
                MOV     A,B
                ORA     A
                JZ      PT_BAD
                MOV     A,M
                CALL    UPPER
                CPI     'S'
                JZ      PT_OPT_S
                CPI     'L'
                JZ      PT_OPT_L
                CPI     '2'
                JZ      PT_OPT_2
                JMP     PT_BAD

PT_OPT_S:
                LDA     MODE_SEEN
                ORA     A
                JNZ     PT_BAD
                MVI     A,1
                STA     MODE_SEEN
                MVI     A,MODE_SYS
                STA     MODE
                INX     H
                DCR     B
                JMP     PT_LOOP

PT_OPT_L:
                LDA     MODE_SEEN
                ORA     A
                JNZ     PT_BAD
                MVI     A,1
                STA     MODE_SEEN
                MVI     A,MODE_LOW
                STA     MODE
                INX     H
                DCR     B
                JMP     PT_LOOP

PT_OPT_2:
                ; Need "2DD" or "2HD".
                MOV     A,B
                CPI     3
                JC      PT_BAD
                INX     H
                DCR     B
                MOV     A,M
                CALL    UPPER
                CPI     'D'
                JZ      PT_2DD_MID
                CPI     'H'
                JZ      PT_2HD_MID
                JMP     PT_BAD
PT_2DD_MID:
                INX     H
                DCR     B
                MOV     A,M
                CALL    UPPER
                CPI     'D'
                JNZ     PT_BAD
                LDA     MEDIA_REQUEST
                ORA     A
                JNZ     PT_BAD
                MVI     A,MEDIA_2DD
                STA     MEDIA_REQUEST
                INX     H
                DCR     B
                JMP     PT_LOOP
PT_2HD_MID:
                INX     H
                DCR     B
                MOV     A,M
                CALL    UPPER
                CPI     'D'
                JNZ     PT_BAD
                LDA     MEDIA_REQUEST
                ORA     A
                JNZ     PT_BAD
                MVI     A,MEDIA_2HD
                STA     MEDIA_REQUEST
                INX     H
                DCR     B
                JMP     PT_LOOP

PT_SKIP:
                INX     H
                DCR     B
                JMP     PT_LOOP

PT_DONE:
                LDA     DRIVE
                CPI     0FFH
                JZ      PT_BAD
                ORA     A
                RET
PT_BAD:
                STC
                RET

UPPER:
                CPI     'a'
                RC
                CPI     'z'+1
                RNC
                ANI     05FH
                RET

; ---------------------------------------------------------------------------
; User display.
; ---------------------------------------------------------------------------
SHOW_SELECTION:
                LXI     D,MSG_DRIVE_SEL
                CALL    PUTS
                LDA     DRIVE
                ADI     'A'
                MOV     E,A
                MVI     C,2
                CALL    BDOS
                MVI     E,':'
                MVI     C,2
                CALL    BDOS

                LXI     D,MSG_FORMAT_REQ
                CALL    PUTS
                LDA     MEDIA_REQUEST
                CPI     MEDIA_2DD
                JZ      SS_2DD
                CPI     MEDIA_2HD
                JZ      SS_2HD
                LXI     D,MSG_AUTO
                JMP     SS_DENSITY_OUT
SS_2DD:
                LXI     D,MSG_2DD
                JMP     SS_DENSITY_OUT
SS_2HD:
                LXI     D,MSG_2HD
SS_DENSITY_OUT:
                CALL    PUTS
                LXI     D,MSG_MODE
                CALL    PUTS
                LDA     MODE
                CPI     MODE_SYS
                JZ      SS_SYS
                CPI     MODE_LOW
                JZ      SS_LOW
                LXI     D,MSG_MODE_DATA
                JMP     PUTS
SS_SYS:
                LXI     D,MSG_MODE_SYS
                JMP     PUTS
SS_LOW:
                LXI     D,MSG_MODE_LOW
                JMP     PUTS

SHOW_TARGET_MEDIA:
                LXI     D,MSG_MEDIA
                CALL    PUTS
                LDA     TARGET_MEDIA
                CPI     MEDIA_2HD
                JZ      STM_2HD
                LXI     D,MSG_2DD
                JMP     PUTS
STM_2HD:
                LXI     D,MSG_2HD
                JMP     PUTS

SHOW_STATUS:
                LXI     D,MSG_STATUS
                CALL    PUTS
                LDA     LAST_STATUS
                CALL    HEX8
                JMP     CRLF

; ---------------------------------------------------------------------------
; Gateway helpers.
; ---------------------------------------------------------------------------
CALLN:
                DB      0EDH,0EDH,CALLN_VEC
                RET

GET_FDD_INFO:
                LXI     D,FDD_INFO
                MVI     A,SVC_GET_FDD_INFO
                CALL    CALLN
                RET

CACHE_RESET_ALL:
                ; Flush all dirty data first.
                MVI     A,SVC_SYNC
                CALL    CALLN
                ORA     A
                JNZ     CRA_FAIL

                ; SVC_CACHE_RESET takes drive index in 8080 H -> native BH.
                MVI     H,0
CRA_LOOP:
                MVI     A,SVC_CACHE_RESET
                CALL    CALLN
                ORA     A
                JNZ     CRA_FAIL
                INR     H
                MOV     A,H
                CPI     4
                JC      CRA_LOOP
                XRA     A
                RET
CRA_FAIL:
                MVI     A,1
                STC
                RET

RAW_CALL:
                LXI     D,RAW_FRAME
                MVI     A,SVC_RAW_INT1B
                CALL    CALLN
                ; Carry is returned through RAW_FLAGS.
                LDA     RAW_FLAGS
                ANI     1
                JZ      RC_OK
                STC
                RET
RC_OK:
                ORA     A
                RET

; Set RAW_AX = AH:function, AL:DA/UA.
; Input A=DA/UA, B=function.
SET_RAW_AX:
                STA     RAW_AX
                MOV     A,B
                STA     RAW_AX+1
                RET

RAW_RECAL:
                ; Input A=DA/UA.
                MOV     D,A
                MVI     B,07H
                CALL    SET_RAW_AX
                XRA     A
                STA     RAW_BX
                STA     RAW_BX+1
                STA     RAW_CX
                STA     RAW_CX+1
                STA     RAW_DX
                STA     RAW_DX+1
                STA     RAW_BP
                STA     RAW_BP+1
                CALL    RAW_CALL
                RET

; ---------------------------------------------------------------------------
; Media family and target detection.
; ---------------------------------------------------------------------------
SELECT_TARGET_MEDIA:
                XRA     A
                STA     TARGET_ERROR
                CALL    GET_FDD_INFO

                CALL    DETECT_TARGET
                JNC     STM_DETECTED

                ; Unformatted media: explicit /2DD or /2HD is mandatory.
                LDA     MEDIA_REQUEST
                ORA     A
                JZ      STM_UNKNOWN
                STA     TARGET_MEDIA
                CALL    APPLY_TARGET_GEOMETRY
                ORA     A
                RET

STM_DETECTED:
                STA     TARGET_MEDIA
                MOV     B,A
                LDA     MEDIA_REQUEST
                ORA     A
                JZ      STM_APPLY
                CMP     B
                JNZ     STM_MISMATCH
STM_APPLY:
                CALL    APPLY_TARGET_GEOMETRY
                ORA     A
                RET
STM_UNKNOWN:
                MVI     A,1
                STA     TARGET_ERROR
                STC
                RET
STM_MISMATCH:
                MVI     A,2
                STA     TARGET_ERROR
                STC
                RET

; Probe target using the same active family selected by the gateway.
; Try 2HD first, then 2DD, matching the resident BIOS.
DETECT_TARGET:
                LDA     FDD_INFO+1
                MOV     B,A
                LDA     DRIVE
                ADD     B
                STA     PROBE_DAUA
                CALL    VERIFY_C0H0S1
                JNC     DT_2HD

                LDA     FDD_INFO+0
                MOV     B,A
                LDA     DRIVE
                ADD     B
                STA     PROBE_DAUA
                CALL    VERIFY_C0H0S1
                JNC     DT_2DD
                STC
                RET
DT_2HD:
                MVI     A,MEDIA_2HD
                ORA     A
                RET
DT_2DD:
                MVI     A,MEDIA_2DD
                ORA     A
                RET

VERIFY_C0H0S1:
                LDA     PROBE_DAUA
                CALL    RAW_RECAL
                JC      VCH_FAIL
                LDA     PROBE_DAUA
                MOV     D,A
                MVI     B,051H
                CALL    SET_RAW_AX
                LXI     H,0200H
                SHLD    RAW_BX
                LXI     H,0200H          ; CH=2, CL=0
                SHLD    RAW_CX
                LXI     H,0001H          ; DH=0, DL=1
                SHLD    RAW_DX
                LXI     H,SECTORBUF
                SHLD    RAW_BP
                CALL    RAW_CALL
                JC      VCH_FAIL
                XRA     A
                RET
VCH_FAIL:
                STC
                RET

APPLY_TARGET_GEOMETRY:
                LDA     TARGET_MEDIA
                CPI     MEDIA_2HD
                JZ      ATG_2HD
                MVI     A,8
                STA     TARGET_SPS
                MVI     A,4
                STA     TARGET_SYS_SIDES
                STA     TARGET_DIR_SIDE
                MVI     A,32
                STA     FORMAT_ID_BYTES
                MVI     A,0
                STA     FORMAT_ID_BYTES+1
                LDA     FDD_INFO+0
                JMP     ATG_DAUA
ATG_2HD:
                MVI     A,15
                STA     TARGET_SPS
                MVI     A,3
                STA     TARGET_SYS_SIDES
                STA     TARGET_DIR_SIDE
                MVI     A,60
                STA     FORMAT_ID_BYTES
                MVI     A,0
                STA     FORMAT_ID_BYTES+1
                LDA     FDD_INFO+1
ATG_DAUA:
                MOV     B,A
                LDA     DRIVE
                ADD     B
                STA     TARGET_DAUA
                RET

; ---------------------------------------------------------------------------
; CHS / raw FDD sector I/O.
; raw_side is side-track 0..159, raw_sector is 1-based.
; ---------------------------------------------------------------------------
SIDE_TO_CHS:
                ; Input A=side-track. Output C=cylinder, D=head.
                MOV     B,A
                ANI     1
                MOV     D,A
                MOV     A,B
                ORA     A               ; clear CY before logical shift
                RAR
                ANI     7FH
                MOV     C,A
                RET

BUILD_FDD_REQUEST:
                ; Input A=DA/UA, B=function, HL=buffer.
                PUSH    H
                CALL    SET_RAW_AX
                LXI     H,0200H
                SHLD    RAW_BX
                LDA     RAW_SIDE
                CALL    SIDE_TO_CHS
                MOV     A,C
                STA     RAW_CX
                MVI     A,2
                STA     RAW_CX+1
                LDA     RAW_SECTOR
                STA     RAW_DX
                MOV     A,D
                STA     RAW_DX+1
                POP     H
                SHLD    RAW_BP
                RET

RAW_READ_SECTOR:
                ; Input A=DA/UA, raw_side/raw_sector, HL=destination.
                STA     RAW_DAUA
                SHLD    RAW_PTR
                MVI     A,MAX_RETRY
                STA     RETRY_COUNT
RRS_RETRY:
                LDA     RAW_DAUA
                MVI     B,056H
                LHLD    RAW_PTR
                CALL    BUILD_FDD_REQUEST
                CALL    RAW_CALL
                JNC     RRS_OK
                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     RAW_DAUA
                CALL    RAW_RECAL
                LDA     RETRY_COUNT
                DCR     A
                STA     RETRY_COUNT
                JNZ     RRS_RETRY
                STC
                RET
RRS_OK:
                XRA     A
                STA     LAST_STATUS
                RET

RAW_WRITE_SECTOR:
                ; Input A=DA/UA, raw_side/raw_sector, HL=source.
                STA     RAW_DAUA
                SHLD    RAW_PTR
                MVI     A,MAX_RETRY
                STA     RETRY_COUNT
RWS_RETRY:
                LDA     RAW_DAUA
                MVI     B,055H
                LHLD    RAW_PTR
                CALL    BUILD_FDD_REQUEST
                CALL    RAW_CALL
                JNC     RWS_OK
                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     RAW_DAUA
                CALL    RAW_RECAL
                LDA     RETRY_COUNT
                DCR     A
                STA     RETRY_COUNT
                JNZ     RWS_RETRY
                STC
                RET
RWS_OK:
                XRA     A
                STA     LAST_STATUS
                RET

; ---------------------------------------------------------------------------
; FORMAT TRACK.
; ---------------------------------------------------------------------------
BUILD_FORMAT_IDS:
                LDA     FMT_SIDE
                CALL    SIDE_TO_CHS
                MOV     A,C
                STA     FMT_CYL
                MOV     A,D
                STA     FMT_HEAD

                LXI     H,FORMAT_IDS
                MVI     E,1
BFI_LOOP:
                LDA     FMT_CYL
                MOV     M,A
                INX     H
                LDA     FMT_HEAD
                MOV     M,A
                INX     H
                MOV     A,E
                MOV     M,A
                INX     H
                MVI     M,2
                INX     H
                INR     E
                LDA     TARGET_SPS
                INR     A
                CMP     E
                JNZ     BFI_LOOP
                RET

FORMAT_SIDE:
                STA     FMT_SIDE
                MVI     A,MAX_RETRY
                STA     RETRY_COUNT
FS_RETRY:
                CALL    BUILD_FORMAT_IDS
                LDA     TARGET_DAUA
                MVI     B,05DH
                CALL    SET_RAW_AX
                LHLD    FORMAT_ID_BYTES
                SHLD    RAW_BX
                LDA     FMT_SIDE
                CALL    SIDE_TO_CHS
                MOV     A,C
                STA     RAW_CX
                MVI     A,2
                STA     RAW_CX+1
                MVI     A,FORMAT_FILL
                STA     RAW_DX
                MOV     A,D
                STA     RAW_DX+1
                LXI     H,FORMAT_IDS
                SHLD    RAW_BP
                CALL    RAW_CALL
                JNC     FS_VERIFY

                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     TARGET_DAUA
                CALL    RAW_RECAL
                LDA     RETRY_COUNT
                DCR     A
                STA     RETRY_COUNT
                JNZ     FS_RETRY
                STC
                RET

FS_VERIFY:
                LDA     FMT_SIDE
                STA     RAW_SIDE
                MVI     A,1
                STA     RAW_SECTOR
                LDA     TARGET_DAUA
                LXI     H,SECTORBUF
                CALL    RAW_READ_SECTOR
                RET

FORMAT_DISK:
                XRA     A
                STA     FMT_SIDE
FD_LOOP:
                LDA     FMT_SIDE
                CALL    FORMAT_SIDE
                RC
                LDA     FMT_SIDE
                INR     A
                STA     FMT_SIDE
                CPI     SIDES_TOTAL
                JC      FD_LOOP
                ORA     A
                RET

; ---------------------------------------------------------------------------
; /S source system image.
; The embedded FDIPL is always used for the destination.
;
; FDD boot source:
;   Keep the original, field-tested FDFORMAT path unchanged:
;     GET_FDD_INFO -> DETECT_SOURCE -> RAW_READ_SECTOR
;   using side-track/sector addressing.
;
; HDD boot source:
;   Use the cold-boot source descriptor and FSID supplied by gateway86.asm,
;   then locate that exact CP/M-80 partition and read its 30-sector payload.
; ---------------------------------------------------------------------------
SAVE_SYSTEM_AREA:
                ; Zero the complete maximum destination area first.
                LXI     H,SYSBUF
                LXI     B,MAX_SYS_BYTES
SSA_ZERO:
                MVI     M,0
                INX     H
                DCX     B
                MOV     A,B
                ORA     C
                JNZ     SSA_ZERO

                ; Install the known-good CP/M-80 FDD IPL template.
                LXI     H,FDIPL80
                LXI     D,SYSBUF
                MVI     B,2
SSA_COPY_IPL_OUTER:
                MVI     C,0
SSA_COPY_IPL_256:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                INR     C
                JNZ     SSA_COPY_IPL_256
                DCR     B
                JNZ     SSA_COPY_IPL_OUTER

                ; Query immutable cold-boot source information.
                LXI     D,BOOT_SOURCE
                MVI     A,SVC_GET_BOOT_SOURCE
                CALL    CALLN
                ORA     A
                JNZ     SSA_SOURCE_FAIL
                LDA     BOOT_SOURCE+0
                STA     SRC_TYPE
                ORA     A
                JZ      SSA_SOURCE_FDD
                CPI     1
                JNZ     SSA_SOURCE_FAIL

                ; HDD source: keep this separate from the established FDD path.
                LDA     BOOT_SOURCE+1
                STA     SRC_DAUA
                CALL    FIND_SOURCE_HDD_PARTITION
                RC
                CALL    READ_VERIFY_HDD_PAYLOAD
                RC
                JMP     SSA_SOURCE_DONE

SSA_SOURCE_FDD:
                ; Preserve the original FDFORMAT source-reader behavior.
                ; BOOT_SOURCE+12 is the physical FDD unit 0..3.
                LDA     BOOT_SOURCE+12
                CPI     4
                JNC     SSA_SOURCE_FAIL
                STA     SRC_DRIVE
                CALL    GET_FDD_INFO
                CALL    DETECT_SOURCE
                RC

                XRA     A
                STA     SRC_SIDE
                MVI     A,2
                STA     SRC_SECTOR
                LXI     H,SYSBUF+SECTOR_SIZE
                MVI     B,PAYLOAD_SECTORS
SSA_FDD_READ_LOOP:
                PUSH    B
                PUSH    H
                CALL    FDD_SRC_READ_AT_HL
                POP     H
                POP     B
                RC
                LXI     D,SECTOR_SIZE
                DAD     D
                CALL    FDD_SRC_ADVANCE
                DCR     B
                JNZ     SSA_FDD_READ_LOOP

                ; Re-read and compare all 30 source sectors.
                XRA     A
                STA     SRC_SIDE
                MVI     A,2
                STA     SRC_SECTOR
                LXI     H,SYSBUF+SECTOR_SIZE
                MVI     B,PAYLOAD_SECTORS
SSA_FDD_VERIFY_LOOP:
                PUSH    B
                PUSH    H
                CALL    FDD_SRC_READ_TO_SECTORBUF
                POP     H
                POP     B
                RC
                PUSH    B
                PUSH    H
                LXI     D,SECTORBUF
                MVI     B,2
SSA_FDD_CMP_OUTER:
                MVI     C,0
SSA_FDD_CMP_256:
                LDAX    D
                CMP     M
                JNZ     SSA_COMPARE_FAIL
                INX     D
                INX     H
                INR     C
                JNZ     SSA_FDD_CMP_256
                DCR     B
                JNZ     SSA_FDD_CMP_OUTER
                POP     H
                POP     B
                LXI     D,SECTOR_SIZE
                DAD     D
                CALL    FDD_SRC_ADVANCE
                DCR     B
                JNZ     SSA_FDD_VERIFY_LOOP

SSA_SOURCE_DONE:
                ; Runtime gateway boot hint must not be propagated to a new disk.
                ; SYSBUF+512 is gateway byte 0; hint begins at gateway offset 1FC0h.
                LXI     H,SYSBUF+021C0H
                MVI     B,64
                XRA     A
SSA_CLEAR_HINT:
                MOV     M,A
                INX     H
                DCR     B
                JNZ     SSA_CLEAR_HINT
                XRA     A
                STA     LAST_STATUS
                RET

SSA_COMPARE_FAIL:
                POP     H
                POP     B
                MVI     A,0FCH
                STA     LAST_STATUS
                STC
                RET

SSA_SOURCE_FAIL:
                MVI     A,0FDH
                STA     LAST_STATUS
                STC
                RET

; ---------------------------------------------------------------------------
; Original FDD source reader.
; ---------------------------------------------------------------------------
DETECT_SOURCE:
                ; Try 2HD then 2DD using the gateway's active family.
                LDA     FDD_INFO+1
                MOV     B,A
                LDA     SRC_DRIVE
                ADD     B
                STA     PROBE_DAUA
                CALL    VERIFY_C0H0S1
                JNC     DS_2HD
                LDA     FDD_INFO+0
                MOV     B,A
                LDA     SRC_DRIVE
                ADD     B
                STA     PROBE_DAUA
                CALL    VERIFY_C0H0S1
                JNC     DS_2DD
                MVI     A,0FEH
                STA     LAST_STATUS
                STC
                RET
DS_2HD:
                LDA     PROBE_DAUA
                STA     SRC_DAUA
                MVI     A,15
                STA     SRC_SPS
                XRA     A
                RET
DS_2DD:
                LDA     PROBE_DAUA
                STA     SRC_DAUA
                MVI     A,8
                STA     SRC_SPS
                XRA     A
                RET

FDD_SRC_READ_AT_HL:
                PUSH    H
                LDA     SRC_SIDE
                STA     RAW_SIDE
                LDA     SRC_SECTOR
                STA     RAW_SECTOR
                POP     H
                LDA     SRC_DAUA
                CALL    RAW_READ_SECTOR
                RET

FDD_SRC_READ_TO_SECTORBUF:
                LDA     SRC_SIDE
                STA     RAW_SIDE
                LDA     SRC_SECTOR
                STA     RAW_SECTOR
                LDA     SRC_DAUA
                LXI     H,SECTORBUF
                CALL    RAW_READ_SECTOR
                RET

FDD_SRC_ADVANCE:
                ; Preserve B: callers use it as the remaining-sector count.
                PUSH    B
                LDA     SRC_SECTOR
                INR     A
                MOV     B,A
                LDA     SRC_SPS
                INR     A
                CMP     B
                JNZ     FSA_SECTOR_OK
                MVI     A,1
                STA     SRC_SECTOR
                LDA     SRC_SIDE
                INR     A
                STA     SRC_SIDE
                POP     B
                RET
FSA_SECTOR_OK:
                MOV     A,B
                STA     SRC_SECTOR
                POP     B
                RET

; ---------------------------------------------------------------------------
; HDD source reader.  This mirrors the working HDFORMAT80 boot-source path.
; ---------------------------------------------------------------------------
RESET_HDD_SOURCE_CHS:
                ; HDD partition sector 0 contains HDIPL.  The 30-sector
                ; resident CP/M-80 payload begins at zero-based sector 1.
                ; This matches HDFORMAT80's working boot-source reader.
                LHLD    SRC_START_CYL
                SHLD    SRC_CYL
                XRA     A
                STA     SRC_HEAD
                MVI     A,1
                STA     SRC_SECTOR
                RET

HDD_SRC_READ_TO_SECTORBUF:
                MVI     A,MAX_RETRY
                STA     RETRY_COUNT
HSR_RETRY:
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,006H
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LHLD    SRC_CYL
                SHLD    RAW_CX
                LDA     SRC_SECTOR
                STA     RAW_DX
                LDA     SRC_HEAD
                STA     RAW_DX+1
                LXI     H,SECTORBUF
                SHLD    RAW_BP
                CALL    RAW_CALL
                JNC     HSR_OK
                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     RETRY_COUNT
                DCR     A
                STA     RETRY_COUNT
                JNZ     HSR_RETRY
                STC
                RET
HSR_OK:
                XRA     A
                STA     LAST_STATUS
                RET

HDD_SRC_ADVANCE:
                PUSH    B
                LDA     SRC_SECTOR
                INR     A
                MOV     B,A
                LDA     SRC_SPS
                CMP     B
                JNZ     HSA_SEC
                XRA     A
                STA     SRC_SECTOR
                LDA     SRC_HEAD
                INR     A
                MOV     B,A
                LDA     SRC_HEADS
                CMP     B
                JNZ     HSA_HEAD
                XRA     A
                STA     SRC_HEAD
                LHLD    SRC_CYL
                INX     H
                SHLD    SRC_CYL
                JMP     HSA_DONE
HSA_HEAD:
                MOV     A,B
                STA     SRC_HEAD
                JMP     HSA_DONE
HSA_SEC:
                MOV     A,B
                STA     SRC_SECTOR
HSA_DONE:
                POP     B
                RET

READ_VERIFY_HDD_PAYLOAD:
                CALL    RESET_HDD_SOURCE_CHS
                LXI     H,SYSBUF+SECTOR_SIZE
                SHLD    SRC_PTR
                MVI     B,PAYLOAD_SECTORS
RVHP_READ_LOOP:
                PUSH    B
                CALL    HDD_SRC_READ_TO_SECTORBUF
                POP     B
                RC

                ; Copy SECTORBUF -> current SYSBUF destination.
                PUSH    B
                LXI     H,SECTORBUF
                XCHG
                LHLD    SRC_PTR
                XCHG
                MVI     B,2
RVHP_COPY_OUTER:
                MVI     C,0
RVHP_COPY_256:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                INR     C
                JNZ     RVHP_COPY_256
                DCR     B
                JNZ     RVHP_COPY_OUTER
                POP     B

                LHLD    SRC_PTR
                LXI     D,SECTOR_SIZE
                DAD     D
                SHLD    SRC_PTR
                CALL    HDD_SRC_ADVANCE
                DCR     B
                JNZ     RVHP_READ_LOOP

                ; Verify by a second physical read.
                CALL    RESET_HDD_SOURCE_CHS
                LXI     H,SYSBUF+SECTOR_SIZE
                SHLD    SRC_PTR
                MVI     B,PAYLOAD_SECTORS
RVHP_VERIFY_LOOP:
                PUSH    B
                CALL    HDD_SRC_READ_TO_SECTORBUF
                POP     B
                RC

                PUSH    B
                LHLD    SRC_PTR
                LXI     D,SECTORBUF
                MVI     B,2
RVHP_CMP_OUTER:
                MVI     C,0
RVHP_CMP_256:
                LDAX    D
                CMP     M
                JNZ     RVHP_COMPARE_FAIL
                INX     D
                INX     H
                INR     C
                JNZ     RVHP_CMP_256
                DCR     B
                JNZ     RVHP_CMP_OUTER
                POP     B

                LHLD    SRC_PTR
                LXI     D,SECTOR_SIZE
                DAD     D
                SHLD    SRC_PTR
                CALL    HDD_SRC_ADVANCE
                DCR     B
                JNZ     RVHP_VERIFY_LOOP
                XRA     A
                RET

RVHP_COMPARE_FAIL:
                POP     B
                MVI     A,0FCH
                STA     LAST_STATUS
                STC
                RET

FIND_SOURCE_HDD_PARTITION:
                ; Sense source HDD geometry.
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,084H
                STA     RAW_AX+1
                LXI     H,0A55AH
                SHLD    RAW_BX
                LXI     H,05AA5H
                SHLD    RAW_CX
                LXI     H,0C33CH
                SHLD    RAW_DX
                LXI     H,0
                SHLD    RAW_BP
                CALL    RAW_CALL
                RC
                LHLD    RAW_BX
                MOV     A,H
                CPI     2
                JNZ     FSHP_FAIL
                MOV     A,L
                ORA     A
                JNZ     FSHP_FAIL
                LDA     RAW_DX+1
                STA     SRC_HEADS
                LDA     RAW_DX
                STA     SRC_SPS
                ORA     A
                JZ      FSHP_FAIL
                LDA     SRC_HEADS
                ORA     A
                JZ      FSHP_FAIL
                XRA     A
                STA     SRC_PART_INDEX
FSHP_SCAN:
                LDA     SRC_PART_INDEX
                CPI     PART_COUNT
                JNC     FSHP_FAIL

                ; Read C0/H0/S1 partition table for each candidate.
                XRA     A
                STA     SRC_CYL
                STA     SRC_CYL+1
                STA     SRC_HEAD
                MVI     A,1
                STA     SRC_SECTOR
                CALL    HDD_SRC_READ_TO_SECTORBUF
                RC

                LDA     SRC_PART_INDEX
                MOV     B,A
                LXI     H,SECTORBUF
FSHP_PTR:
                MOV     A,B
                ORA     A
                JZ      FSHP_PTR_OK
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     FSHP_PTR
FSHP_PTR_OK:
                SHLD    SRC_ENTRY_PTR
                INX     H
                MOV     A,M
                ANI     07FH
                CPI     CPM_SYS
                JNZ     FSHP_NEXT

                ; Partition start cylinder from entry +0Ah/+0Bh.
                LHLD    SRC_ENTRY_PTR
                LXI     D,8
                DAD     D
                MOV     A,M
                ORA     A
                JNZ     FSHP_NEXT
                INX     H
                MOV     A,M
                ORA     A
                JNZ     FSHP_NEXT
                INX     H
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    SRC_START_CYL
                SHLD    SRC_CYL
                XRA     A
                STA     SRC_HEAD
                STA     SRC_SECTOR
                CALL    HDD_SRC_READ_TO_SECTORBUF
                JC      FSHP_NEXT

                ; Match CP/M-80 metadata and the immutable boot-source FSID.
                LXI     H,SECTORBUF+01E0H
                LXI     D,CPM80_SIG
                MVI     B,8
FSHP_SIG:
                LDAX    D
                CMP     M
                JNZ     FSHP_NEXT
                INX     D
                INX     H
                DCR     B
                JNZ     FSHP_SIG
                LXI     H,SECTORBUF+01E8H
                LXI     D,BOOT_SOURCE+4
                MVI     B,8
FSHP_ID:
                LDAX    D
                CMP     M
                JNZ     FSHP_NEXT
                INX     D
                INX     H
                DCR     B
                JNZ     FSHP_ID
                XRA     A
                RET
FSHP_NEXT:
                LDA     SRC_PART_INDEX
                INR     A
                STA     SRC_PART_INDEX
                JMP     FSHP_SCAN
FSHP_FAIL:
                MVI     A,0FDH
                STA     LAST_STATUS
                STC
                RET

; ---------------------------------------------------------------------------
; Restore / verify destination system area.
; ---------------------------------------------------------------------------
RESTORE_SYSTEM_AREA:
                LXI     H,SYSBUF
                XRA     A
                STA     RAW_SIDE
RSA_SIDE:
                MVI     A,1
                STA     RAW_SECTOR
RSA_SECTOR:
                PUSH    H
                LDA     TARGET_DAUA
                CALL    RAW_WRITE_SECTOR
                POP     H
                RC
                LXI     D,SECTOR_SIZE
                DAD     D
                LDA     RAW_SECTOR
                INR     A
                STA     RAW_SECTOR
                MOV     B,A
                LDA     TARGET_SPS
                INR     A
                CMP     B
                JNZ     RSA_SECTOR
                LDA     RAW_SIDE
                INR     A
                STA     RAW_SIDE
                MOV     B,A
                LDA     TARGET_SYS_SIDES
                CMP     B
                JNZ     RSA_SIDE
                XRA     A
                RET

VERIFY_DEST_SYSTEM:
                LXI     H,SYSBUF
                XRA     A
                STA     RAW_SIDE
VDS_SIDE:
                MVI     A,1
                STA     RAW_SECTOR
VDS_SECTOR:
                PUSH    H
                LDA     TARGET_DAUA
                LXI     H,SECTORBUF
                CALL    RAW_READ_SECTOR
                POP     H
                RC

                PUSH    H
                LXI     D,SECTORBUF
                MVI     B,2
VDS_CMP_OUTER:
                MVI     C,0
VDS_CMP_256:
                LDAX    D
                CMP     M
                JNZ     VDS_COMPARE_FAIL
                INX     D
                INX     H
                INR     C
                JNZ     VDS_CMP_256
                DCR     B
                JNZ     VDS_CMP_OUTER
                POP     H

                LXI     D,SECTOR_SIZE
                DAD     D
                LDA     RAW_SECTOR
                INR     A
                STA     RAW_SECTOR
                MOV     B,A
                LDA     TARGET_SPS
                INR     A
                CMP     B
                JNZ     VDS_SECTOR
                LDA     RAW_SIDE
                INR     A
                STA     RAW_SIDE
                MOV     B,A
                LDA     TARGET_SYS_SIDES
                CMP     B
                JNZ     VDS_SIDE
                XRA     A
                RET
VDS_COMPARE_FAIL:
                POP     H
                MVI     A,0FBH
                STA     LAST_STATUS
                STC
                RET

; ---------------------------------------------------------------------------
; CP/M directory initialization.
; ---------------------------------------------------------------------------
INITIALIZE_DIRECTORY:
                LXI     H,SECTORBUF
                MVI     B,2
ID_FILL_OUTER:
                MVI     C,0
ID_FILL_256:
                MVI     M,0E5H
                INX     H
                INR     C
                JNZ     ID_FILL_256
                DCR     B
                JNZ     ID_FILL_OUTER

                LDA     TARGET_DIR_SIDE
                STA     RAW_SIDE
                MVI     A,1
                STA     RAW_SECTOR
                MVI     B,DIR_SECTORS
ID_LOOP:
                PUSH    B
                LDA     TARGET_DAUA
                LXI     H,SECTORBUF
                CALL    RAW_WRITE_SECTOR
                POP     B
                RC
                LDA     RAW_SECTOR
                INR     A
                STA     RAW_SECTOR
                DCR     B
                JNZ     ID_LOOP
                XRA     A
                RET

; ---------------------------------------------------------------------------
; Console / utility helpers.
; ---------------------------------------------------------------------------
PUTS:
                MVI     C,9
                CALL    BDOS
                RET

GETC:
                MVI     C,1
                CALL    BDOS
                RET

PUTC:
                MOV     E,A
                MVI     C,2
                CALL    BDOS
                RET

CRLF:
                MVI     A,0DH
                CALL    PUTC
                MVI     A,0AH
                JMP     PUTC

WAIT_RETURN:
                LXI     D,MSG_PRESS
                CALL    PUTS
WR_LOOP:
                CALL    GETC
                CPI     0DH
                JNZ     WR_LOOP
                JMP     CRLF

HEX8:
                PUSH    PSW
                RRC
                RRC
                RRC
                RRC
                ANI     0FH
                CALL    HEX_NIBBLE
                POP     PSW
                ANI     0FH
HEX_NIBBLE:
                CPI     10
                JC      HN_DIGIT
                ADI     'A'-10
                JMP     PUTC
HN_DIGIT:
                ADI     '0'
                JMP     PUTC

; ---------------------------------------------------------------------------
; Data.
; ---------------------------------------------------------------------------
MODE:                   DB      0
MODE_SEEN:              DB      0
MEDIA_REQUEST:          DB      MEDIA_AUTO
DRIVE:                  DB      0FFH

TARGET_MEDIA:           DB      MEDIA_AUTO
TARGET_ERROR:           DB      0
TARGET_DAUA:            DB      070H
TARGET_SPS:             DB      8
TARGET_SYS_SIDES:       DB      4
TARGET_DIR_SIDE:        DB      4
FORMAT_ID_BYTES:        DW      32

PROBE_DAUA:             DB      0
RAW_DAUA:               DB      0
RAW_SIDE:               DB      0
RAW_SECTOR:             DB      1
RAW_PTR:                DW      0
FMT_SIDE:               DB      0
FMT_CYL:                DB      0
FMT_HEAD:               DB      0
RETRY_COUNT:            DB      0
LAST_STATUS:            DB      0

SRC_DRIVE:              DB      0
SRC_DAUA:               DB      0
SRC_SPS:                DB      8
SRC_SIDE:               DB      0
SRC_SECTOR:             DB      1

; Cold-boot source description returned by gateway86.asm service 11h.
BOOT_SOURCE:             DS      16
SRC_TYPE:                DB      0       ; 0=FDD, 1=HDD
SRC_HEADS:               DB      0
SRC_CYL:                 DW      0
SRC_HEAD:                DB      0
SRC_START_CYL:           DW      0
SRC_PART_INDEX:          DB      0
SRC_ENTRY_PTR:           DW      0
SRC_PTR:                 DW      0
CPM80_SIG:               DB      'CPM80FS1'

; GET_FDD_INFO result: 2DD base, 2HD base, boot DA/UA, boot media.
FDD_INFO:               DS      4

; RAW_INT1B request frame.
RAW_FRAME:
RAW_AX:                 DW      0
RAW_BX:                 DW      0
RAW_CX:                 DW      0
RAW_DX:                 DW      0
RAW_BP:                 DW      0
RAW_FLAGS:              DW      0

FORMAT_IDS:             DS      60
SECTORBUF:              DS      512

MSG_TITLE:      DB 0DH,0AH,'PC-9801 CP/M-80 FDFORMAT',0DH,0AH,'$'
MSG_USAGE:      DB 'Usage: FDFORMAT drive: [/S|/L] [/2DD|/2HD]',0DH,0AH
                DB '       /S = bootable system disk, /L = low-level only',0DH,0AH,'$'
MSG_DRIVE_SEL:  DB 'Drive: $'
MSG_FORMAT_REQ: DB '  Format: $'
MSG_AUTO:       DB 'AUTO$'
MSG_2DD:        DB '2DD$'
MSG_2HD:        DB '2HD$'
MSG_MODE:       DB '  Mode: $'
MSG_MODE_DATA:  DB 'DATA',0DH,0AH,'$'
MSG_MODE_SYS:   DB 'SYSTEM',0DH,0AH,'$'
MSG_MODE_LOW:   DB 'LOW-LEVEL ONLY',0DH,0AH,'$'
MSG_WARN:       DB 'WARNING: all data on the target disk will be lost.',0DH,0AH
                DB 'Continue (Y/N)? $'
MSG_ABORT:      DB 'Aborted.',0DH,0AH,'$'
MSG_SAVE:       DB 'Reading and verifying clean CP/M-80 system image...',0DH,0AH,'$'
MSG_READERR:    DB 'Cannot read/verify source system image.',0DH,0AH,'$'
MSG_INSERT1:    DB 'Insert target disk in drive $'
MSG_INSERT2:    DB ' and press RETURN. $'
MSG_PRESS:      DB '$'
MSG_MEDIA_UNKNOWN:
                DB 'Cannot identify target medium. Use /2DD or /2HD.',0DH,0AH,'$'
MSG_MEDIA_MISMATCH:
                DB 'Requested density does not match detected medium.',0DH,0AH,'$'
MSG_MEDIA:      DB 'Detected/selected medium: $'
MSG_FORMAT:     DB 'Low-level formatting...',0DH,0AH,'$'
MSG_FMTERR:     DB 'Format error at side-track $'
MSG_FMTOK:      DB 'Low-level format complete.',0DH,0AH,'$'
MSG_WRITESYS:   DB 'Writing CP/M-80 system area...',0DH,0AH,'$'
MSG_WRITESYSERR:
                DB 'System-area write failed.',0DH,0AH,'$'
MSG_VERIFYSYS:  DB 'Verifying CP/M-80 system area...',0DH,0AH,'$'
MSG_VERIFYSYSERR:
                DB 'System-area verify failed.',0DH,0AH,'$'
MSG_DIR:        DB 'Initializing CP/M directory...',0DH,0AH,'$'
MSG_DIRERR:     DB 'Directory initialization failed.',0DH,0AH,'$'
MSG_DONE_DATA:  DB 'Data disk format complete.',0DH,0AH,'$'
MSG_DONE_SYS:   DB 'Bootable CP/M-80 system disk format complete.',0DH,0AH,'$'
MSG_DONE_LOW:   DB 'Low-level format complete, CP/M directory not initialized.',0DH,0AH,'$'
MSG_CACHEERR:   DB 'Cannot flush/invalidate BIOS cache.',0DH,0AH,'$'
MSG_STATUS:     DB '  status=$'

; ---------------------------------------------------------------------------
; Embedded CP/M-80 FDD IPL template.
; Generate FDIPL80.INC from fdipl80.asm:
;   nasm -f bin fdipl80.asm -o fdipl80.bin
;   python3 bin2inc.py fdipl80.bin FDIPL80.INC --label FDIPL80
; ---------------------------------------------------------------------------
        INCLUDE FDIPL80.INC

; Maximum 2HD reserved system area.  /S installs the embedded 512-byte
; FDIPL followed by 30 verified payload sectors from the source system disk;
; the density-specific remainder stays zero.
SYSBUF:                 DS      MAX_SYS_BYTES

; Private stack (512 bytes).
STACK_AREA:             DS      512
STACK_TOP               EQU     $

                END     START
