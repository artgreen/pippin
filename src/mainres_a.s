*-----------------------------------------------------------------------------
* mainres_a.s -- first body fragment of the JSON MAIN_RES image: ssc_irq + the
* state block. PUT by the mainres-*.s drivers between `put ksw_hook` and
* `put ssc_common` (the layout is positional). Shared by both CPU builds; uses
* the cpu.macs macros the driver defined first. No PUT of its own (nested PUT is
* a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* ssc_irq -- chained ProDOS IRQ handler. THE periodic timing source.
*
* On a stock //e enhanced there is no VBL CPU IRQ, no timer IRQ, and no
* other ambient periodic source. The host's keyboard read is a closed
* poll on $C000 so a KSW-hook drain only fires once per real keystroke.
* The SSC's per-byte RX IRQ is the only thing that ticks reliably.
*
* Strategy: queue bytes into the ring as they arrive, and when a $0A
* ('\n', frame terminator) lands, dispatch INLINE in IRQ context. That
* violates the "no heavy work in IRQ" guideline but it's the only way
* to drive preemptive TSR-like behavior here. The host appears frozen
* for the dispatch window (~50ms per response); the contract is that
* the MCP client is synchronously waiting for the response anyway.
*
* The KSW hook (see above) handles only synthetic-key inject (set by a
* future send_keystroke handler). No drain happens through the KSW
* path anymore.
*
* ProDOS contract (TRM Ch 6):
*   - CLD first
*   - Return CLC + RTS if claimed, SEC + RTS to chain
*   - Never call MLI inside (we don't, even from the dispatched code)
*   - A/X/Y preserved by ProDOS across handler entry, so we can clobber
*
* We ALWAYS claim (CLC). The original code returned SEC ("not mine") when
* status bit 7 (srIRQ) read clear, on the theory that meant a foreign IRQ.
* That is wrong on a real //c / //c+: the built-in firmware can read the
* 6551 status register during its own IRQ entry, clearing bit 7 BEFORE
* ProDOS dispatches to us. Our own interrupt then looks foreign, we SEC,
* nothing else claims it, and ProDOS halts -- RESTART SYSTEM-$01
* ("unclaimed interrupt"). Observed on a real //c+ when serial bytes
* arrived during disk I/O and on socat connect/disconnect (DCD/DSR
* transitions). Claiming unconditionally is safe here: PIPPIN's slot-2
* 6551 is the only device raising IRQs on the target machines at a BASIC
* prompt, and reading STATUS (plus DATA when RDRF) clears our chip, so
* there is no re-assert/livelock.
*-----------------------------------------------------------------------------
ssc_irq
            cld
            lda   SSC_STATUS         ; read clears the 6551 IRQ flag (bit 7)
            and   #$08               ; bit 3 = RDRF -- a received byte waiting?
            beq   :claim_spurious    ; no byte (DCD/DSR change, spurious, or our
*                                    ;  bit 7 already cleared by firmware): claim

            lda   SSC_DATA           ; read byte, clears RDRF on chip
            ldx   ZP_RX_WR
            sta   rx_buf,x           ; reference to label, resolves to $9400+X
            inx                      ; 256-byte ring wraps via 8-bit register
            stx   ZP_RX_WR

            cmp   #$0A               ; frame terminator?
            bne   :claim_spurious    ; no -- queue, wait for more bytes

* Frame complete. Refresh comfort marker (inverse '@' at top-right of
* text page 1) and run dispatch inline. The marker self-heals if any
* prior screen clear wiped it.
            _STZ   $0427              ; inverse '@' at row 0 col 39

* Bank-switch protocol (see spec §7.4). Sample $C012 bit 7 to discover
* the prior LC read state, swap to bank 2 for the dispatch, restore
* whatever was mapped before. $C012 bit 7 = 1 means LC RAM was read-
* enabled, so the BMI-was-RAM path restores bank 1 RAM (ProDOS lives
* there); the BPL-was-ROM path is for callers that were reading ROM.
            lda   LC_STATE           ; $C012: bit 7 = was reading RAM
            sta   saved_lc_read
            lda   LC_RD_BANK2        ; $C080: read LC bank 2, write protect
            jsr   LC_PARSE_DISPATCH  ; $D000: run LC code (clobbers A/X/Y)
            bit   saved_lc_read
            bmi   :restore_ram
            lda   LC_RD_ROM          ; was ROM-read: back to ROM
            _BRA   :claim_spurious
:restore_ram
            lda   LC_RD_BANK1        ; was RAM-read: back to bank 1 RAM
            ;  fall through

:claim_spurious
            clc                      ; always claim (see header: avoids $01)
            rts


*-----------------------------------------------------------------------------
* State variables (mutable RAM, written/read at runtime).
* Pinned to STATE_BASE_ADDR ($9080) via DS pad so install.s can write
* into them via the shared HOOKED_BASIC_ADDR / SAVED_*_ADDR equates
* regardless of how big the trampoline above grows.
*-----------------------------------------------------------------------------
            ds    STATE_BASE_ADDR-*,$00

hooked_basic    dfb   0             ; 1 if $BE32 hooked, 0 if only $38 hooked
saved_basic_lo  dfb   0             ; chain target for $BE32 path lo
saved_basic_hi  dfb   0             ; chain target for $BE32 path hi (adjacent)
saved_lc_read   dfb   0             ; bit 7: 1 = caller was reading LC RAM,
                                    ;        0 = caller was reading ROM
                                    ; captured by trampoline pre-bank-switch
parse_op        dfb   0             ; output of parse_frame in LC: 0..7 op enum,
                                    ; or $FF on parse error. Read by the LC
                                    ; dispatcher to JMP through op_handlers.
parse_id_lo     dfb   0             ; request id, low byte (set by handler)
parse_id_hi     dfb   0             ; request id, high byte (adjacent)
parse_id_ptr    dfb   0             ; Y offset of first id digit in rx_buf
                                    ; (set by parse_frame; handler later does
                                    ;  ldy parse_id_ptr / jsr parse_int)
saved_rom_lo    dfb   0             ; chain target for $38/$39 path lo
saved_rom_hi    dfb   0             ; chain target for $38/$39 path hi (adjacent)

* Reserved 2-byte pad ($908A-$908B). Formerly ksw_chain_lo/hi, intended for a
* KSW chain target -- but the hook never chained (it polls + RTSs; see
* ksw_hook.s), so these were always dead. Kept as a pad, NOT reclaimed,
* because mul10_* ($908E/$908F) and the JSON scratch ($9097-$9099) below are
* pinned by absolute equates; deleting these 2 bytes would shift them.
                dfb   0,0

* emit_dec_word scratch (in absolute memory so callers don't have to find
* free ZP bytes -- ZP_PTR is used for INPUT only; we keep our own scratch).
emit_digit_cnt  dfb   0             ; per-power digit accumulator
emit_leading    dfb   0             ; $80 once we've emitted a non-suppressed digit

* parse_int (in LC bank 2) needs writable scratch for its *10 multiply.
* LC bank 2 is mapped read-only at runtime, so scratch MUST live here in
* MAIN_RES even though the only caller is LC code. Address pinned via
* MUL10_LO_ADDR / MUL10_HI_ADDR equates ($908E / $908F).
mul10_lo        dfb   0
mul10_hi        dfb   0

* Set to 1 by do_notif when notifications/initialized arrives. Indicates
* the MCP handshake is complete. Currently informational; future handlers
* could refuse to run until this is set.
session_active  dfb   0

* Per-tool arg-position recordings, written by parse_frame's per-tool
* branch and consumed by the handler's parse_int calls. parse_p1 is the
* ring offset of arg-1's first digit/char, parse_p2 is arg-2, parse_p3
* is the length of write_memory's hex-value field.
parse_p1        dfb   0
parse_p2        dfb   0
parse_p3        dfb   0

* Handlers that parse multiple integers stash the first into parse_addr_*
* because the next parse_int call clobbers ZP_PTR. parse_len_lo holds
* the 1-byte length used by read_memory.
parse_addr_lo   dfb   0
parse_addr_hi   dfb   0
parse_len_lo    dfb   0
* JSON parser scratch (FRAME_NL_ADDR/JDEPTH_ADDR/PTMP_ADDR = $9097/98/99).
* Pinned here, just after parse_len_lo ($9096); the $9100 pad below absorbs
* the 3-byte shift so ssc_tx_string stays at $9100.
frame_nl        dfb   0             ; $9097 parse bound (frame '\n' offset)
jdepth          dfb   0             ; $9098 skip_value nesting depth
ptmp            dfb   0             ; $9099 tools/call object cursor


