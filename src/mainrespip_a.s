*-----------------------------------------------------------------------------
* mainrespip_a.s -- first body fragment of the fast/binary MAIN_RES image:
* ssc_irq, the state block, check_and_dispatch, all five handlers, the range
* guards, and the response-emit helpers. PUT by the mainres-pip-*.s drivers
* between `put ksw_hook` and `put ssc_common`. Shared by both CPU builds; uses the
* cpu.macs macros. No PUT of its own (nested PUT is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*---- ssc_irq (binary): queue RX byte, JSR dispatch, ALWAYS claim ------------
ssc_irq
            cld
            lda   SSC_STATUS            ; read clears the 6551 IRQ flag
            and   #$08                  ; RDRF -- byte waiting?
            beq   :claim                ; no byte: claim (DCD/DSR/spurious)
            lda   SSC_DATA              ; read byte, clears RDRF
            ldx   ZP_RX_WR
            sta   rx_buf,x
            inx
            stx   ZP_RX_WR
            jsr   check_and_dispatch
:claim      clc                         ; ALWAYS claim (avoids RESTART-$01)
            rts

*---- state block (pinned $9080; install-pip writes the saved_* bytes) ------
            ds    STATE_BASE_ADDR-*,$00
hooked_basic    dfb 0                   ; $9080
saved_basic_lo  dfb 0                   ; $9081
saved_basic_hi  dfb 0                   ; $9082 (adjacent to lo)
saved_rom_lo    dfb 0                   ; $9083
saved_rom_hi    dfb 0                   ; $9084 (adjacent to lo)
frame_rd        dfb 0                   ; ring offset of the in-flight A5
total           dfb 0                   ; frame length = ALEN + 4
cur_op          dfb 0
cur_alen        dfb 0
calc_ck         dfb 0                   ; running request-checksum
req_addr_lo     dfb 0
req_addr_hi     dfb 0
arg_count       dfb 0                   ; READ count / WRITE N
end_lo          dfb 0
end_hi          dfb 0
resp_ck         dfb 0                   ; running response-checksum

*-----------------------------------------------------------------------------
* check_and_dispatch -- resync to A5, await a full frame, verify CK, dispatch.
* Every advance is bounded by ZP_RX_WR (avail), so no hostile frame can hang.
* Ring reads advance X (wraps at $94FF); never offset the base.
*-----------------------------------------------------------------------------
check_and_dispatch
cad_scan                                ; handlers JMP here to look for more
            lda   ZP_RX_WR
            sec
            sbc   ZP_RX_RD              ; A = avail (mod 256)
            beq   :wait                 ; ring empty
            ldx   ZP_RX_RD
            lda   rx_buf,x
            cmp   #$A5
            beq   :sync_ok
            inc   ZP_RX_RD              ; not A5: drop one byte, resync
            _BRA   cad_scan
:wait       rts                         ; empty / partial frame -> return, await
*                                       ; more. NEAR trampoline: the early exits
*                                       ; below are <127 bytes from here, but the
*                                       ; routine tail is >127 from cad_scan.
:sync_ok
            lda   ZP_RX_WR
            sec
            sbc   ZP_RX_RD
            cmp   #3
            bcc   :wait                 ; need A5 OP ALEN; wait
            ldx   ZP_RX_RD
            stx   frame_rd              ; capture A5 position
            inx
            lda   rx_buf,x              ; OP  (frame_rd+1)
            sta   cur_op
            inx
            lda   rx_buf,x              ; ALEN (frame_rd+2)
            cmp   #131                  ; ALEN > 130 is invalid for every op. Reject
            bcc   :alen_ok              ;   HERE, before computing total: ALEN=252 makes
            inc   ZP_RX_RD              ;   total=(ALEN+4)&$FF wrap to 0, and the consume
            jmp   cad_scan              ;   step then parks RD on this A5 forever (hang,
*                                       ;   IRQs off). Drop the A5 and resync -> progress.
:alen_ok    sta   cur_alen
            clc
            adc   #4
            sta   total                 ; total = ALEN+4, now bounded 5..134 (cannot wrap)
            lda   ZP_RX_WR
            sec
            sbc   ZP_RX_RD
            cmp   total
            bcc   :wait                 ; frame not fully buffered; wait
* frame complete -> consume it regardless of outcome
            lda   frame_rd
            clc
            adc   total
            sta   ZP_RX_RD              ; commit RD past this frame
* verify checksum: (OP + ALEN + Σargs) & FF  vs  ring[frame_rd+3+ALEN].
* X currently = frame_rd+2.
            lda   cur_op
            clc
            adc   cur_alen
            sta   calc_ck
            ldy   cur_alen
            beq   :ck_test
:ck_loop    inx
            lda   rx_buf,x
            clc
            adc   calc_ck
            sta   calc_ck
            dey
            bne   :ck_loop
:ck_test    inx                         ; X = frame_rd+3+ALEN (CK position)
            lda   rx_buf,x
            cmp   calc_ck
            bne   :err_ck
            lda   cur_op
            cmp   #$05
            bcs   :err_op                ; OP > 4
            jsr   check_alen
            bcs   :err_len
            _STZ   $0427                  ; comfort marker
            lda   cur_op
            asl
            tax
            _JMPINDX op_table_b;ZP_T6502_PTR   ; dispatch: jmp (op_table_b,X)
:err_ck     lda   #$01
            jsr   emit_st_only
            jmp   cad_scan              ; cad_scan is >128 bytes back -> JMP not BRA
:err_op     lda   #$02
            jsr   emit_st_only
            jmp   cad_scan
:err_len    lda   #$04
            jsr   emit_st_only
            jmp   cad_scan

*-----------------------------------------------------------------------------
* check_alen -- validate cur_alen against cur_op. C clear=ok, C set=bad.
*-----------------------------------------------------------------------------
check_alen
            lda   cur_op
            beq   :need0                ; PING
            cmp   #$01
            beq   :need0                ; STATUS
            cmp   #$02
            beq   :need3                ; READ
            cmp   #$04
            beq   :need1                ; SENDKEY
* OP==3 WRITE: ALEN in 3..130 (N = ALEN-2 in 1..128)
            lda   cur_alen
            cmp   #3
            bcc   :bad
            cmp   #131
            bcs   :bad
            clc
            rts
:need0      lda   cur_alen
            beq   :ok
            _BRA   :bad
:need3      lda   cur_alen
            cmp   #3
            beq   :ok
            _BRA   :bad
:need1      lda   cur_alen
            cmp   #1
            beq   :ok
            _BRA   :bad                ; ALEN != 1 for SENDKEY -> reject. (Without
*                                     ; this, control fell through to :ok and
*                                     ; accepted any ALEN -- :need0/:need3 both
*                                     ; have the matching bra :bad.)
:ok         clc
            rts
:bad        sec
            rts

op_table_b  da    do_ping_b            ; $00
            da    do_status_b          ; $01
            da    do_read_b            ; $02
            da    do_write_b           ; $03
            da    do_sendkey_b         ; $04

*---- handlers (raw args from ring via frame_rd; emit response; loop) --------
do_ping_b
            lda   #$00                  ; ST=0, RLEN=0
            jsr   emit_st_only
            jmp   cad_scan

do_status_b
            lda   #$00                  ; ST=0
            ldy   #6                    ; RLEN=6
            jsr   emit_resp_open
            ldx   #0                    ; ver_major
            jsr   emit_byte_ck
            ldx   #6                    ; ver_minor (v0.6)
            jsr   emit_byte_ck
            ldx   ZP_MACHINE_TYPE
            jsr   emit_byte_ck
            ldx   ZP_RX_WR              ; debug snapshot: ssc_tx_byte's RX-drain
            jsr   emit_byte_ck          ;  can bump ZP_RX_WR mid-reply, so wr/rd
            ldx   ZP_RX_RD              ;  are informational only (the host
            jsr   emit_byte_ck          ;  formats them, never branches on them).
            ldx   ZP_PENDING_KEY
            jsr   emit_byte_ck
            jsr   emit_resp_close
            jmp   cad_scan

do_read_b
            ldx   frame_rd
            inx
            inx
            inx                         ; frame_rd+3
            lda   rx_buf,x
            sta   req_addr_lo
            inx                         ; frame_rd+4
            lda   rx_buf,x
            sta   req_addr_hi
            inx                         ; frame_rd+5
            lda   rx_buf,x
            sta   arg_count
            beq   :badlen               ; count == 0
            jsr   check_range_read
            bcs   :forbid
            lda   #$00                  ; ST=0
            ldy   arg_count             ; RLEN=count
            jsr   emit_resp_open
            lda   req_addr_lo
            sta   ZP_PTR
            lda   req_addr_hi
            sta   ZP_PTR+1
            ldy   #0
:rd_loop    lda   (ZP_PTR),y
            tax
            jsr   emit_byte_ck          ; preserves X and Y
            iny
            cpy   arg_count
            bne   :rd_loop
            jsr   emit_resp_close
            jmp   cad_scan
:badlen     lda   #$04
            jsr   emit_st_only
            jmp   cad_scan
:forbid     lda   #$03
            jsr   emit_st_only
            jmp   cad_scan

do_write_b
            ldx   frame_rd
            inx
            inx
            inx                         ; frame_rd+3
            lda   rx_buf,x
            sta   req_addr_lo
            inx                         ; frame_rd+4
            lda   rx_buf,x
            sta   req_addr_hi
            lda   cur_alen
            sec
            sbc   #2
            sta   arg_count             ; N = ALEN-2 (1..128, validated)
            jsr   check_range_write
            bcs   :forbid
            lda   req_addr_lo
            sta   ZP_PTR
            lda   req_addr_hi
            sta   ZP_PTR+1
            ldx   frame_rd
            inx
            inx
            inx
            inx
            inx                         ; frame_rd+5 (first data byte)
            ldy   #0
:wr_loop    lda   rx_buf,x              ; source byte from ring
            sta   (ZP_PTR),y            ; dest = addr + Y
            inx                         ; advance ring source (wraps)
            iny
            cpy   arg_count
            bne   :wr_loop
            lda   #$00                  ; ST=0, RLEN=0
            jsr   emit_st_only
            jmp   cad_scan
:forbid     lda   #$03
            jsr   emit_st_only
            jmp   cad_scan

do_sendkey_b
            ldx   frame_rd
            inx
            inx
            inx                         ; frame_rd+3 (key)
            lda   rx_buf,x
            cmp   #128
            bcs   :bad                  ; key >= 128
            sta   ZP_PENDING_KEY
            lda   #$00                  ; ST=0, RLEN=0
            jsr   emit_st_only
            jmp   cad_scan
:bad        lda   #$04
            jsr   emit_st_only
            jmp   cad_scan

*-----------------------------------------------------------------------------
* compute_end -- end = addr + arg_count (count is one byte). On return C set
* means the add wrapped past $FFFF. `end` is an EXCLUSIVE bound (the checkers
* allow end == $C000 / $BF00 as "last byte below the boundary"), so a sum of
* exactly $10000 (end_lo=0; last byte $FFFF, the IRQ vector) is a legal end,
* not a wrap -- only end > $10000 wraps. In every carry-set case start >= $FF01,
* so the checkers' start >= $D000 short-circuit means end is never consulted.
*-----------------------------------------------------------------------------
compute_end
            clc
            lda   req_addr_lo
            adc   arg_count
            sta   end_lo
            lda   req_addr_hi
            adc   #0
            sta   end_hi
            bcc   :done                 ; end < $10000: not a wrap
            lda   end_lo                ; C set: end >= $10000. Exactly $10000
            bne   :done                 ;   is legal; lda/bne preserve C, so a
            clc                         ;   true wrap returns with C still set.
:done       rts                         ; C = wrap

*-----------------------------------------------------------------------------
* check_range_read -- forbid overlap with $C000-$CFFF or wrap.
*   Out: C clear = OK; C set = forbidden.
*-----------------------------------------------------------------------------
check_range_read
            jsr   compute_end
            bcs   :forbid
            lda   req_addr_hi
            cmp   #$C0
            bcc   :chk_end              ; start_hi < $C0
            cmp   #$D0
            bcs   :chk_end              ; start_hi >= $D0 (above I/O)
            _BRA   :forbid               ; start in $C0..$CF
:chk_end    lda   req_addr_hi
            cmp   #$D0
            bcs   :ok                   ; start >= $D000
            lda   end_hi
            cmp   #$C0
            bcc   :ok                   ; end < $C000
            bne   :forbid               ; end_hi > $C0 -> crosses
            lda   end_lo
            beq   :ok                   ; end == $C000 exactly (last byte $BFFF)
:forbid     sec
            rts
:ok         clc
            rts

*-----------------------------------------------------------------------------
* check_range_write -- forbid overlap with the contiguous $BF00-$CFFF or wrap.
*   Out: C clear = OK; C set = forbidden.
*-----------------------------------------------------------------------------
check_range_write
            jsr   compute_end
            bcs   :forbid
            lda   req_addr_hi
            cmp   #$BF
            beq   :forbid               ; start in $BF00-$BFFF
            cmp   #$C0
            bcc   :chk_end              ; start_hi < $BF (and != $BF)
            cmp   #$D0
            bcs   :chk_end              ; start_hi >= $D0
            _BRA   :forbid               ; start in $C0..$CF
:chk_end    lda   req_addr_hi
            cmp   #$D0
            bcs   :ok                   ; start >= $D000
            lda   end_hi
            cmp   #$BF
            bcc   :ok                   ; end < $BF00
            bne   :forbid               ; end_hi > $BF -> crosses
            lda   end_lo
            beq   :ok                   ; end == $BF00 exactly (last byte $BEFF)
:forbid     sec
            rts
:ok         clc
            rts

*-----------------------------------------------------------------------------
* Response emit. resp_ck accumulates (ST + RLEN + Σres) & FF.
*   emit_resp_open: A=ST, Y=RLEN -> sends A5,ST,RLEN; resp_ck = ST+RLEN.
*   emit_byte_ck:   X=byte -> sends byte, adds to resp_ck (X,Y preserved).
*   emit_resp_close: sends resp_ck.
*   emit_st_only:   A=ST -> full RLEN=0 frame (open + close).
* ssc_tx_byte preserves X and Y, so emit_byte_ck can run inside (ZP_PTR),Y loops.
*-----------------------------------------------------------------------------
emit_resp_open                          ; A=ST, Y=RLEN
            pha                         ; save ST
            _STZ   resp_ck
            ldx   #$A5
            jsr   ssc_tx_byte           ; A5 (not part of CK)
            pla
            tax                         ; X = ST
            jsr   emit_byte_ck          ; ST (resp_ck += ST)
            tya
            tax                         ; X = RLEN
            jmp   emit_byte_ck          ; RLEN (tail-call; returns to caller)

emit_byte_ck                            ; X = byte; resp_ck += byte; send byte
            txa
            clc
            adc   resp_ck
            sta   resp_ck
            jmp   ssc_tx_byte           ; sends X, preserves X/Y, returns to caller

emit_resp_close
            ldx   resp_ck
            jmp   ssc_tx_byte

emit_st_only                            ; A = ST, RLEN = 0
            ldy   #0
            jsr   emit_resp_open
            jmp   emit_resp_close

