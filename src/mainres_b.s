*-----------------------------------------------------------------------------
* mainres_b.s -- second body fragment of the JSON MAIN_RES image: ssc_tx_string
* ($9100), emit_hex_byte ($9120), emit_dec_word ($9140), the MLI param block
* ($93F0), and the RX ring ($9400), padded to $9600. PUT by the mainres-*.s
* drivers immediately after `put ssc_common`. Shared by both CPU builds; uses the
* cpu.macs macros. No PUT of its own (nested PUT is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* ssc_tx_string -- emit null-terminated string at ZP_PTR over the wire.
*
* Pinned to $9100 (matches SSC_TX_STRING_ADDR in equates.s) so install.s
* and other sources outside mainres can JSR by absolute address without
* worrying about layout drift inside mainres.
*
* Caller stores string address in ZP_PTR / ZP_PTR+1, then JSRs here.
* The string is emitted verbatim (no high-bit stripping) terminated by
* a zero byte. Arbitrary length supported -- when Y wraps past $FF we
* bump ZP_PTR+1 to advance the indirect base into the next page. This
* is needed for tools/list (~530 bytes of static JSON).
*
* Input:  ZP_PTR / ZP_PTR+1 = string address
* Output: A, X, Y clobbered. ZP_PTR / ZP_PTR+1 destroyed.
*-----------------------------------------------------------------------------
            ds    $9100-*,$00       ; pad to $9100 (stable cross-source entry)

ssc_tx_string
            ldy   #0
:loop       lda   (ZP_PTR),y
            beq   :done
            tax
            jsr   ssc_tx_byte
            iny
            bne   :loop              ; Y rolled within page
            inc   ZP_PTR+1           ; Y wrapped -- advance to next page
            _BRA   :loop
:done       rts


            ds    $9120-*,$00       ; pad to $9120 (stable cross-source entry)

*-----------------------------------------------------------------------------
* emit_hex_byte -- emit A as 2 high-ASCII hex chars over the wire.
*
* Used by memory-dump responses (read_memory will stream pairs of these
* per byte read). Trick: each nibble path tail-calls ssc_tx_byte via JMP,
* so the inner JSR's return goes straight back to emit_hex_byte's caller
* on the second (low-nibble) pass.
*
* Input:  A = byte to emit as 2 hex chars
* Output: A, X clobbered. Y preserved (ssc_tx_byte preserves Y).
*-----------------------------------------------------------------------------
emit_hex_byte
            pha                      ; save full byte
            lsr
            lsr
            lsr
            lsr                      ; A = high nibble
            jsr   :nib_to_ascii
            pla                      ; restore byte
            and   #$0F               ; A = low nibble
:nib_to_ascii
            cmp   #$0A
            bcc   :digit             ; nibble 0..9: carry from CMP is clear
            adc   #$26               ; nibble a..f: carry was set, so this adds
                                     ; $27, landing on 'a'..'f' after the +$30
                                     ; below. (LOWERCASE so read_memory output
                                     ; decodes cleanly through write_memory's
                                     ; lowercase-only hex_nib.)
:digit      adc   #$30               ; '0' (low-ASCII -- wire is 7-bit clean per
                                     ; spec); carry clear here. Result is 'a'..'f'
                                     ; for high nibbles, '0'..'9' for digits.
            tax
            jmp   ssc_tx_byte        ; tail-call: ssc_tx_byte's RTS returns to caller


*-----------------------------------------------------------------------------
* emit_dec_word -- emit 16-bit ZP_PTR/+1 as ASCII decimal (no leading zeros).
*
* Range: 0..65535. Emits "0" through "65535". Destroys the input value
* (subtracts powers of 10 into ZP_PTR itself); caller must save if
* needed across the call.
*
* Pinned to $9140 (matches EMIT_DEC_WORD_ADDR in equates.s) so LC code
* can JSR by absolute address without worrying about MAIN_RES layout
* drift between ssc_tx_string ($9100), emit_hex_byte ($9120), and here.
*
* Used by response builders to emit the JSON-RPC `id` field (which can
* be any non-negative integer up to 5 decimal digits per the spec).
*
* Input:  ZP_PTR / ZP_PTR+1 = unsigned 16-bit value
* Output: A, X, Y clobbered. ZP_PTR / ZP_PTR+1 destroyed.
*-----------------------------------------------------------------------------
            ds    $9140-*,$00       ; pad to $9140 (stable cross-source entry)

emit_dec_word
            _STZ   emit_leading
            ldx   #0                 ; pow10 table index 0..4 (10K,1K,100,10,1)

:next_power _STZ   emit_digit_cnt
:sub_loop   sec
            lda   ZP_PTR
            sbc   dec_pow10_lo,x
            pha                      ; stash candidate lo on stack
            lda   ZP_PTR+1
            sbc   dec_pow10_hi,x
            bcc   :pow_done          ; underflow: this power doesn't fit anymore
            sta   ZP_PTR+1
            pla
            sta   ZP_PTR
            inc   emit_digit_cnt
            _BRA   :sub_loop

:pow_done   pla                      ; discard the failed candidate lo
            lda   emit_digit_cnt
            bne   :emit              ; non-zero digit: emit and stop suppressing
            lda   emit_leading
            bmi   :emit              ; already emitting: emit even zeros
            cpx   #4                 ; at the 1's place? then emit even if leading 0
            bcc   :advance

:emit       lda   #$80
            sta   emit_leading
            lda   emit_digit_cnt
            clc
            adc   #$30               ; '0' low-ASCII; wire is 7-bit clean (spec §3.1)
            _PHX  ZP_T6502_C         ; save power index across the call. ZP_T6502_C
*                                    ;  (not _A) because ssc_tx_byte below itself
*                                    ;  does _PHX/_PHY on _A/_B -- this outer save
*                                    ;  must not collide with the inner one.
            tax                      ; X = digit char ('0'..'9')
            jsr   ssc_tx_byte        ; emit; clobbers A, preserves X (=char)
            _PLX  ZP_T6502_C         ; restore power index

:advance    inx                      ; next power-of-10 table slot
            cpx   #5                 ; 5 powers: 10000, 1000, 100, 10, 1
            bcc   :next_power
            rts

* dec_pow10_lo/hi are parallel single-byte tables. X indexes both with
* stride 1: x=0 -> 10000, x=1 -> 1000, ..., x=4 -> 1.
dec_pow10_lo dfb  <10000,<1000,<100,<10,<1
dec_pow10_hi dfb  >10000,>1000,>100,>10,>1


*-----------------------------------------------------------------------------
* ALLOC_INTERRUPT parameter block at fixed offset $93F0 so install.s can
* reference it via the MLI_PARAMS equate. Pad to that address.
*-----------------------------------------------------------------------------
            ds    $93F0-*,$00       ; pad to $93F0

* mli_params lives here at exactly $93F0. install.s calls MLI with
* this address; ProDOS writes the returned int_num into int_num below.
mli_params      dfb   2             ; param count
int_num         dfb   0             ; returned interrupt number (out)
                da    ssc_irq       ; handler address (resolves to ssc_irq's $9000-range addr)


*-----------------------------------------------------------------------------
* Ring buffer at $9400 (page-aligned for clean abs,Y access)
*-----------------------------------------------------------------------------
            ds    $9400-*,$00       ; pad to $9400

rx_buf      ds    256                ; 256 bytes of zeros


*-----------------------------------------------------------------------------
* Pad MAIN_RES out to $9600 (one byte past the last resident byte) so the
* assembled binary is exactly MAINRES_PAGES (6) pages = $9000-$95FF = 1536
* bytes. rx_buf above already runs $9400-$94FF; this DS covers $9500-$95FF.
* That last page is currently dead headroom for future state/code growth.
*-----------------------------------------------------------------------------
            ds    $9600-*,$00
