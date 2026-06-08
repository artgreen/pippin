*-----------------------------------------------------------------------------
* recv_body.s -- shared body of the standalone serial file receiver. PUT by the
* thin per-CPU drivers recv-65c02.s (RECV.BIN) and recv-6502.s (RECV.6502),
* which set CPUC02 + the org/typ/dsk and PUT cpu.macs first. This is the single
* source for both receivers; cpu.macs is the only place the two CPUs diverge.
*
* The receiver loads at $0801 (BIN, aux $0801; launch with BRUN RECV.BIN or
* BRUN RECV.6502). $0801 not $0800: a binary at $0800 puts a nonzero byte at the
* Applesoft program-start cell, which BASIC reads as a stray program. It receives
* a file over the slot-2 6551 SSC at 9600 8N1 (polled, NO interrupts) into $2000+,
* 16-bit-checksums it, sends the sender a 1-byte status ack, and reports on
* screen. The receiver sits low (at $0801) so it stays clear of the $2000 landing
* zone -- this lets it stage a real $2000
* binary (e.g. PIPPIN) at $2000. Companion to tools/serial_send.py.
*
* recv is a simple POLLED receiver: SEI is asserted at entry, so there is no IRQ
* and the 6502 scratch bytes used by _PHX/_PHY/_PLX/_PLY (t6502_x/t6502_y below)
* are never preempted -- they only need to be ZP bytes the body itself does not
* keep live across the save/restore. There is no `sta (zp)` zero-index store and
* no indexed-indirect jump here, so _STAIND / _JMPINDX are not used.
*
* Wire protocol:
*   Mac -> Apple:  A5 5A  LL LH  CL CH  <payload>
*   Apple -> Mac:  ST           (one status byte: 0=OK,1=cksum,2=timeout,3=len)
*-----------------------------------------------------------------------------

* ---- SSC slot 2 (offsets 8-11 per the SSC manual; see docs/DESIGN.md) ----
SSC_DATA    equ   $C0A8
SSC_STATUS  equ   $C0A9
SSC_COMMAND equ   $C0AA
SSC_CONTROL equ   $C0AB

* ---- 6551 status bits / frame sync constants ----
RDRF        equ   $08                     ; status bit 3: RX data register full
TDRE        equ   $10                     ; status bit 4: TX data register empty
SYNC1       equ   $A5                     ; request sync byte 1 (Mac->Apple)
SYNC2       equ   $5A                     ; request sync byte 2

* ---- ROM entry points ----
COUT        equ   $FDED
RDKEY       equ   $FD0C
HOME        equ   $FC58
PRBYTE      equ   $FDDA
BASIC_WARM  equ   $BE00                   ; BASIC.SYSTEM warm command-loop re-entry

* zero page -- standalone tool; reuses PIPPIN's ZP region. Must NOT be loaded alongside PIPPIN (aliases its TSR state).
dest        equ   $06                     ; 16-bit dest pointer (lo @ $06, hi @ $07)
strp        equ   $06                     ; print_str ptr -- OVERLAYS dest; safe
*                                         ;  because the two are never live at once
*                                         ;  (banner prints before receive; the
*                                         ;  report prints after it completes)
cksum       equ   $08                     ; 16-bit running checksum (lo @ $08, hi @ $09)
count       equ   $EB                     ; 16-bit received count
length      equ   $ED                     ; 16-bit expected length

* 6502 CPU-macro scratch (used only on the 6502 build; ignored on the 65C02).
* recv asserts SEI on entry -- no IRQ preempts these, so they only need to be ZP
* bytes the body does not keep live across a _PHx/_PLx pair. $FE/$FD are free
* here (recv touches $06-$09 and $EB-$EE only). _PHX uses t6502_x, _PHY/_PLY use
* t6502_y; in putc both are live at once so they MUST differ.
t6502_x     equ   $FE                     ; X save  (putc)
t6502_y     equ   $FD                     ; Y save  (print_str, putc)

SCRN_PROG   equ   $0427                   ; a text-screen cell for progress poke
DATA_BASE   equ   $2000                   ; landing zone
MAX_LEN_HI  equ   $7A                     ; ceiling = $7A00 from $2000 base
*                                         ;  (top = $9A00, below BASIC.SYSTEM)
TIMEOUT_HI  equ   $08                     ; ~2-8s depending on CPU speed

* ---- status enum (the 1-byte ack) ----
STAT_OK     equ   $00                     ; success
STAT_CK     equ   $01                     ; checksum mismatch
STAT_TO     equ   $02                     ; timeout (header/sync or mid-transfer)
STAT_LEN    equ   $03                     ; bad length (> $7A00)

* NOTE: all screen output goes through print_str, which holds its index in Y
* and brackets COUT with PHY/PLY (and never touches X), so it is safe even
* under the //c/IIc+ 80-column firmware that clobbers X/Y across COUT. The
* remaining COUT/PRBYTE calls hold no index across the call, so the tool no
* longer requires a 40-column launch for correct output.
start
            sei                           ; RX timing must not be disrupted by IRQs
            cld                           ; checksum is binary clc/adc -- make D=0 explicit
            _STZ  count                   ; zero now: a header/sync timeout or bad
            _STZ  count+1                 ;  length reports/sends before the receive
            _STZ  cksum                   ;  loop ever runs, so count/cksum must be
            _STZ  cksum+1                 ;  valid on every exit path
            jsr   HOME
            lda   #<banner
            ldy   #>banner
            jsr   print_str
* ---- init 6551 ----
            _STZ  SSC_STATUS              ; any write resets the 6551
            lda   #$1E                    ; 9600 8N1, internal clock
            sta   SSC_CONTROL
            lda   #$0B                    ; DTR on, RTS low, RX IRQ off, TX IRQ off, no parity
            sta   SSC_COMMAND
* ---- drain one stale RX byte if present ----
            lda   SSC_STATUS
            and   #RDRF
            beq   :nostale
            lda   SSC_DATA
:nostale
            _BRA  sync_hunt               ; skip trampolines; begin sync hunt

* ---- near trampolines (within +-127 of sync/header branches) ----
near_timeout
            jmp   err_timeout
near_badlen
            jmp   err_badlen
near_rxtout
            jmp   err_rx_timeout

* ---- hunt for sync A5 5A (sliding two-state matcher) ----
sync_hunt
            jsr   get_byte
            bcs   near_timeout
            cmp   #SYNC1
            bne   sync_hunt
:wait5a     jsr   get_byte
            bcs   near_timeout
            cmp   #SYNC2
            beq   sync_ok
            cmp   #SYNC1                   ; A5 A5 ... -> stay armed for 5A
            beq   :wait5a
            _BRA  sync_hunt
sync_ok

* ---- read header LL LH CL CH ----
            jsr   get_byte
            bcs   near_timeout
            sta   length
            jsr   get_byte
            bcs   near_timeout
            sta   length+1
            jsr   get_byte
            bcs   near_timeout
            sta   exp_ck
            jsr   get_byte
            bcs   near_timeout
            sta   exp_ck+1

* ---- length sanity: reject > $7A00 ----
            lda   length+1
            cmp   #MAX_LEN_HI
            bcc   len_ok                   ; hi < $7A -> ok
            bne   near_badlen              ; hi > $7A -> reject
            lda   length                   ; hi == $7A: lo must be 0
            bne   near_badlen
len_ok

* ---- init receive state (count/cksum already zeroed at entry) ----
            _STZ  dest
            lda   #>DATA_BASE
            sta   dest+1                   ; dest = $2000
            ldy   #0                       ; (dest),y with y fixed at 0

            lda   length                   ; length == 0 -> nothing to receive
            ora   length+1
            beq   recv_done

* ---- tight receive loop (budget ~80 cyc/byte << 1040 cyc char-time) ----
recv_loop
            jsr   get_byte
            bcs   near_rxtout              ; partial: report what we have
            sta   (dest),y                 ; store (A still holds the byte)
            clc
            adc   cksum
            sta   cksum
            bcc   :nock
            inc   cksum+1
:nock
            inc   dest
            bne   :nopage
            inc   dest+1
            lda   dest+1                   ; progress: poke page (byte already stored)
            sta   SCRN_PROG
:nopage
            inc   count
            bne   :cmp
            inc   count+1
:cmp
            lda   count+1
            cmp   length+1
            bne   recv_loop
            lda   count
            cmp   length
            bne   recv_loop

* ---- completion: status code (0..3) in A, then report ----
recv_done
            lda   cksum
            cmp   exp_ck
            bne   fail_ck
            lda   cksum+1
            cmp   exp_ck+1
            bne   fail_ck
            lda   #STAT_OK
            _BRA  report
fail_ck     lda   #STAT_CK                 ; checksum mismatch
            _BRA  report
err_rx_timeout
            lda   #STAT_TO                 ; mid-transfer timeout (partial count)
            _BRA  report
err_timeout
            lda   #STAT_TO                 ; header/sync timeout (count=0)
            _BRA  report
err_badlen
            lda   #STAT_LEN                 ; length over the ceiling

* ---- report: 1-byte status ack to the sender, then screen ----
report
            sta   status                   ; save status (putc/PRBYTE clobber A)
            jsr   putc                      ; wire ack: the one status byte (A=status)
* ---- screen: BYTES=hhhh  CK=hhhh  PASS|FAIL|TIMEOUT|TOOBIG ----
            lda   #<lbl_bytes
            ldy   #>lbl_bytes
            jsr   print_str
            lda   count+1
            jsr   PRBYTE
            lda   count
            jsr   PRBYTE
            lda   #<lbl_ck
            ldy   #>lbl_ck
            jsr   print_str
            lda   cksum+1
            jsr   PRBYTE
            lda   cksum
            jsr   PRBYTE
            lda   #$A0                      ; space
            jsr   COUT
* verdict via status-indexed pointer table (codes are a contiguous 0..3 enum)
            lda   status
            asl
            tax
            ldy   msgtab+1,x
            lda   msgtab,x
            jsr   print_str
            lda   #$8D
            jsr   COUT
            cli
            rts                             ; or jmp BASIC_WARM if you like
msgtab      da    lbl_pass                  ; STAT_OK
            da    lbl_fail                  ; STAT_CK
            da    lbl_to                    ; STAT_TO
            da    msg_badlen                ; STAT_LEN

*-----------------------------------------------------------------------------
* print_str -- print null-terminated string at A=lo / Y=hi via COUT.
*   80-col safe: the //c/IIc+ 80-col firmware clobbers X/Y across COUT, so
*   the loop index is held in Y and bracketed with PHY/PLY; X is untouched.
*   In:  A = string addr lo, Y = string addr hi.
*   Out: A = 0 (terminator). X preserved; Y clobbered.
*-----------------------------------------------------------------------------
print_str
            sta   strp
            sty   strp+1
            ldy   #0
:loop       lda   (strp),y
            beq   :done
            _PHY  t6502_y
            jsr   COUT
            _PLY  t6502_y
            iny
            bne   :loop
:done       rts

*-----------------------------------------------------------------------------
* get_byte -- wait for one RX byte with timeout.
*   Out: A = byte, C clear on success; C set on timeout. X,Y preserved.
*   Timer reset/increment happens during the idle spin, so it does not cost
*   throughput on the steady-state path.
*-----------------------------------------------------------------------------
get_byte
            _STZ  timer
            _STZ  timer+1
            _STZ  timer+2
:poll       lda   SSC_STATUS
            and   #RDRF                    ; byte waiting?
            bne   :got
            inc   timer
            bne   :poll
            inc   timer+1
            bne   :poll
            inc   timer+2
            lda   timer+2
            cmp   #TIMEOUT_HI
            bne   :poll
            sec                            ; timed out
            rts
:got        lda   SSC_DATA                 ; read clears RDRF
            clc
            rts

*-----------------------------------------------------------------------------
* putc -- send A over SSC, paced (TDRE-bug workaround; see spec / mainres.s).
*   The genuine/WDC 6551 reads TDRE ready prematurely, so we poll then PACE
*   with a fixed delay >= 1 char-time. This is the only Apple->Mac TX path.
*   Delay ~5600 cyc: ~1.4ms @4MHz, ~22ms @1MHz -- one byte, negligible.
*   In: A = byte. Clobbers A. X,Y preserved.
*-----------------------------------------------------------------------------
putc
            pha                            ; hold byte across TDRE poll
:wait       lda   SSC_STATUS
            and   #TDRE                    ; TX register empty?
            beq   :wait
            pla
            sta   SSC_DATA
            _PHX  t6502_x
            _PHY  t6502_y
            ldy   #22
:dout       ldx   #50
:din        dex
            bne   :din
            dey
            bne   :dout
            _PLY  t6502_y
            _PLX  t6502_x
            rts

*-----------------------------------------------------------------------------
* data
*-----------------------------------------------------------------------------
timer       ds    3
exp_ck      ds    2
status      ds    1

banner      asc   "RDY...",8D,8D,00
lbl_bytes   asc   "BYTES=",00
lbl_ck      asc   "  CK=",00
lbl_pass    asc   "PASS",00
lbl_fail    asc   "FAIL",00
lbl_to      asc   "TIMEOUT",00
msg_badlen  asc   "TOOBIG",00

            end
