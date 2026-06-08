*-----------------------------------------------------------------------------
* ssc_common.s -- SSC routine(s) shared verbatim by both MAIN_RES builds.
*
* PUT by src/mainres.s (JSON path) and src/mainres-pip.s (fast/binary path)
* so the code has ONE source of truth instead of two copies that silently
* drift. Holds no ORG/equates of its own: the including file must `put` its
* equates first (for SSC_STATUS / SSC_DATA / ZP_RX_WR) and must define the
* rx_buf label (resolved here by forward reference). ssc_tx_byte is position-
* independent -- callers JSR by label -- so it may sit at any address in
* either build, which is why it can be PUT wherever each build had its copy.
*-----------------------------------------------------------------------------

*-----------------------------------------------------------------------------
* ssc_tx_byte -- emit byte in X over the SSC TX line (polled, blocking).
*
* TDRE-bug workaround. The genuine 6551 (and the WDC 65C51 in the //c+) reads
* the TDRE status bit "ready" prematurely, so a naive poll-then-write shoves
* bytes out faster than the chip clocks them -- each new byte stomps the one
* still shifting, producing garbage on the wire. (Some emulators model a correct
* TDRE, which is why this only bites on real hardware.) Fix: after writing,
* pace with a fixed delay >= one character time. We still poll TDRE first
* (harmless, and correct on chips where it works); the delay is what
* guarantees spacing when it doesn't.
*
* The pacing loop ALSO drains any RX byte that lands during this window into
* the ring. PIPPIN dispatches + transmits its whole response inside the IRQ
* with interrupts off, so without this a client that streams its next frame
* while we are still mid-response overruns the 6551's 1-byte RX register: the
* next frame loses leading bytes, the ring read pointer misaligns, and every
* subsequent frame parses to error (observed on real hardware). TX and RX are
* both 9600, so polling RDRF once per
* outer tick (~22x per char-time) catches every inbound byte before the
* following one can overwrite it.
*
* Delay sizing: one char at 9600 8N1 = 10 bits = ~1.042 ms. The loop below
* burns ~5600 cycles. We size for the FASTEST target CPU (//c+ accelerator at
* 4 MHz => ~1.4 ms, ~35% margin). At 1 MHz it is ~4x longer -- slower TX but
* still correct (over-delaying never corrupts; under-delaying does).
*
* Both behaviors (TDRE pacing and RX draining) are load-bearing on real
* hardware -- do not remove either.
*
* Input:  X = byte to send
* Output: A clobbered. X and Y preserved.
*-----------------------------------------------------------------------------
ssc_tx_byte
:wait       lda   SSC_STATUS         ; bit 4 = TDRE (TX register empty)
            and   #$10
            beq   :wait
            stx   SSC_DATA           ; STX abs sends X directly. (Was TXA / STA
*                                    ;  SSC_DATA -- STX drops the A clobber and
*                                    ;  saves a byte + 2 cycles; flags unused here.)
* Pace the next write -- do NOT trust TDRE to have cleared (see header) -- and
* drain any RX byte that arrives during the wait.
            _PHX  ZP_T6502_A         ; A is live (caller's byte); scratch saves
            _PHY  ZP_T6502_B         ;  preserve it (txa/pha would clobber it)
            ldy   #22
:dly_out    ldx   #50
:dly_in     dex
            bne   :dly_in
            lda   SSC_STATUS         ; X==0 here -- did an RX byte arrive?
            and   #$08               ; bit 3 = RDRF
            beq   :dly_next
            lda   SSC_DATA           ; drain it into the ring (X is free)
            ldx   ZP_RX_WR
            sta   rx_buf,x
            inx
            stx   ZP_RX_WR
:dly_next   dey
            bne   :dly_out
            _PLY  ZP_T6502_B
            _PLX  ZP_T6502_A
            rts
