*-----------------------------------------------------------------------------
* lcrom_body.s -- LC bank 2 contents ($D000-$DFFF), shared by both CPU builds.
* PUT by lcrom-65c02.s (CPUC02=1 -> LCROM.BIN) and lcrom-6502.s (CPUC02=0 ->
* LCROM6502.BIN). The driver PUTs cpu.macs + the equates first, so the CPU
* macros (_STZ/_BRA/_PHY/_PLY/_PHX/_PLX/_STAIND) are defined before use here.
* Contains no PUT/putbin of its own (nested PUT is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* parse_dispatch -- LC entry point at $D000 (called by trampoline)
*
* Drain loop: for each '\n'-terminated frame in [ZP_RX_RD, ZP_RX_WR),
*   1. parse_frame -> sets parse_op
*   2. advance ZP_RX_RD past the '\n'
*   3. dispatch through op_handlers (or do_error on $FF)
*   4. handler JMPs back here to look for another frame
*
* Exit: RTS only when ring is empty or only contains a partial frame.
* The trampoline restores bank state on our return.
*-----------------------------------------------------------------------------
parse_dispatch
parse_dispatch_loop
            ldx   ZP_RX_RD
            cpx   ZP_RX_WR
            beq   :empty                ; ring empty -- done
            jsr   find_newline          ; Y = \n pos (C clear), or no-find (C set)
            bcs   :empty                ; partial frame -- wait for more bytes
            sty   FRAME_NL_ADDR         ; record parse bound (frame end) for scanner
            _PHY  ZP_T6502_B            ; save \n position across parse_frame
            jsr   parse_frame           ; reads from RX_RD, sets parse_op
            _PLY  ZP_T6502_B            ; Y = \n position again
            iny                         ; advance past the '\n'
            sty   ZP_RX_RD              ; commit frame as consumed
            lda   PARSE_OP_ADDR
            bmi   :do_err               ; $FF: parse error
            asl                         ; *2 for word table
            tax
            _JMPINDX op_handlers;ZP_T6502_PTR   ; dispatch: jmp (op_handlers,X)
:do_err     jmp   do_error
:empty      rts


*-----------------------------------------------------------------------------
* find_newline -- scan ring from ZP_RX_RD forward for '\n' (= $0A)
*
* The ring at $9400 is page-aligned, so Y wraps from $FF to $00 cleanly
* across the 256-byte ring. We stop at ZP_RX_WR (the IRQ's write index);
* if Y reaches WR without finding '\n', the frame is incomplete.
*
* Note: bytes on the wire are 7-bit ASCII per spec §3.1, so '\n' arrives
* as $0A (not $8A). Don't OR-ed with the high-ASCII convention used for
* Apple screen output.
*
* Output: C clear, Y = position of '\n' (if found)
*         C set                          (if no '\n' yet -- partial frame)
*-----------------------------------------------------------------------------
find_newline
            ldy   ZP_RX_RD
:loop       cpy   ZP_RX_WR
            beq   :no_nl                ; caught up to write index, no '\n'
            lda   RX_BUF_ADDR,y
            cmp   #$0A
            beq   :found
            iny
            _BRA   :loop
:found      clc
            rts
:no_nl      sec
            rts


*-----------------------------------------------------------------------------
* skip_ws -- advance X past JSON whitespace, bounded by FRAME_NL.
*   In:  X = ring offset.  Out: X at first non-ws (or == FRAME_NL). A clobbered.
*-----------------------------------------------------------------------------
skip_ws
:loop       cpx   FRAME_NL_ADDR
            beq   :done
            lda   RX_BUF_ADDR,x
            cmp   #$20                   ; space
            beq   :adv
            cmp   #$09                   ; tab
            beq   :adv
            cmp   #$0D                   ; CR
            beq   :adv
            cmp   #$0A                   ; LF
            beq   :adv
            rts
:adv        inx
            _BRA   :loop
:done       rts

*-----------------------------------------------------------------------------
* skip_value -- advance X past one JSON value. In: X at value start.
*   Out: C clear + X just past the value; C set if FRAME_NL hit (malformed).
*   Handles string (\ escapes), object/array (balanced, string-aware),
*   number/literal (until , } ] or ws). Uses JDEPTH for structures.
*-----------------------------------------------------------------------------
skip_value
            cpx   FRAME_NL_ADDR
            beq   :bad
            lda   RX_BUF_ADDR,x
            cmp   #$22                   ; '"'
            beq   :string
            cmp   #$7B                   ; '{'
            beq   :struct
            cmp   #$5B                   ; '['
            beq   :struct
:lit        cpx   FRAME_NL_ADDR          ; number / true / false / null
            beq   :bad
            lda   RX_BUF_ADDR,x
            cmp   #$2C                   ; ','
            beq   :ok
            cmp   #$7D                   ; '}'
            beq   :ok
            cmp   #$5D                   ; ']'
            beq   :ok
            cmp   #$20
            beq   :ok
            inx
            _BRA   :lit
:ok         clc
            rts
:bad        sec
            rts
:string     inx                          ; past opening '"'
:str_lp     cpx   FRAME_NL_ADDR
            beq   :bad
            lda   RX_BUF_ADDR,x
            inx
            cmp   #$5C                    ; '\' escape
            beq   :str_esc
            cmp   #$22                    ; closing '"'
            bne   :str_lp
            clc
            rts
:str_esc    cpx   FRAME_NL_ADDR
            beq   :bad
            inx                           ; skip escaped char
            _BRA   :str_lp
:struct     _STZ  JDEPTH_ADDR
:st_lp      cpx   FRAME_NL_ADDR
            beq   :bad
            lda   RX_BUF_ADDR,x
            inx
            cmp   #$22                    ; inner string -> skip it
            beq   :st_str
            cmp   #$7B                   ; '{'
            beq   :st_open
            cmp   #$5B                   ; '['
            beq   :st_open
            cmp   #$7D                   ; '}'
            beq   :st_close
            cmp   #$5D                   ; ']'
            beq   :st_close
            _BRA   :st_lp
:st_open    inc   JDEPTH_ADDR
            _BRA   :st_lp
:st_close   dec   JDEPTH_ADDR
            bne   :st_lp
            clc                           ; depth back to 0 -> done
            rts
:st_str                                   ; X past the inner opening '"'
:sts_lp     cpx   FRAME_NL_ADDR
            beq   :bad
            lda   RX_BUF_ADDR,x
            inx
            cmp   #$5C
            beq   :sts_esc
            cmp   #$22
            bne   :sts_lp
            _BRA   :st_lp                  ; resume structure scan
:sts_esc    cpx   FRAME_NL_ADDR
            beq   :bad
            inx
            _BRA   :sts_lp

*-----------------------------------------------------------------------------
* find_key -- find J_KEY in the object whose '{' is at ring offset X.
*   In:  X = ring offset of '{'; J_KEY ($06/$07) -> NUL-term key.
*   Out: C clear + X = ring offset of value start (after ':' and ws), if found.
*        C set, if not found / object end / malformed.
*   Inspects only this object's own members (skips nested values). Bounded.
*   Key compare does NOT honor '\' escapes (MCP keys are bare identifiers).
*-----------------------------------------------------------------------------
find_key
            inx                           ; past '{'
:member     jsr   skip_ws
            cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            cmp   #$7D                   ; '}'
            beq   :nf                      ; object end -> not found
            cmp   #$22                     ; expect key-opening '"'
            bne   :nf                      ; malformed
            inx                            ; past opening '"'
            ldy   #0
:cmp        cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            cmp   #$22                     ; ring key ended?
            beq   :ring_end
            cmp   (J_KEY),y                ; compare with target char
            bne   :mismatch
            inx
            iny
            _BRA   :cmp
:ring_end                                  ; X at closing '"' of ring key
            lda   (J_KEY),y                ; target exhausted too?
            beq   :match                   ; both ended -> match
            inx                            ; target longer -> mismatch; past '"'
            _BRA   :to_value_skip
:mismatch                                  ; walk to ring key's closing '"'
:mm_end     cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            inx
            cmp   #$22
            bne   :mm_end                  ; X now past closing '"'
:to_value_skip                            ; skip ws, ':', ws, then value
            jsr   skip_ws
            cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            cmp   #$3A                   ; ':'
            bne   :nf
            inx
            jsr   skip_ws
            jsr   skip_value
            bcs   :nf                       ; bound hit
            jsr   skip_ws
            cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            cmp   #$2C                   ; ','
            bne   :nf                       ; not ',' (and not matched) -> done
            inx                             ; past ',' -> next member
            _BRA   :member
:match                                     ; X at closing '"' of matched key
            inx                             ; past closing '"'
            jsr   skip_ws
            cpx   FRAME_NL_ADDR
            beq   :nf
            lda   RX_BUF_ADDR,x
            cmp   #$3A                   ; ':'
            bne   :nf
            inx
            jsr   skip_ws
            cpx   FRAME_NL_ADDR           ; empty value up to '\n' (truncated
            beq   :nf                     ;  frame): skip_ws ate the '\n' -> nf
            clc                             ; FOUND; X = value start
            rts
:nf         sec
            rts


*-----------------------------------------------------------------------------
* parse_frame -- structural parse of one '\n'-terminated frame in ring
*
* Order-independent structural scan. find_key
* locates the top-level "method" and "id" keys in any order, each search
* bounded by FRAME_NL; for tools/call we then descend into params/arguments
* to reach the tool name. The op enum is keyed off discriminating
* characters of the located values:
*   method[0]: 'p'=ping(0) 'i'=initialize(1) 'n'=notif(2) 't'=tools/*
*   method[6]: 'l'=tools/list(3) 'c'=tools/call -> read tool name
*   toolname[0]: 's','r','w','k' = status/read/write/sendkey ($04..$07)
* Every read is FRAME_NL-bounded, so a truncated/hostile frame yields
* $FF (error), never an out-of-bounds read or a hang. (Discrimination is
* by single char, not full-string -- see the parser design spec.)
*
* Input:  ZP_RX_RD = frame start (offset of '{' in ring)
* Output: PARSE_OP_ADDR ($9084) = 0..7 op enum, or $FF on parse error
*         Y clobbered.
*-----------------------------------------------------------------------------
parse_frame
* Order-independent scan. find_key locates top-level "method" and "id"
* regardless of key order; tools/call descends into params/arguments.
* X = ring cursor throughout (find_key/skip_value advance it). Bounded by
* FRAME_NL (set by parse_dispatch before calling us).
* --- method ---
            lda   #<k_method
            sta   J_KEY
            lda   #>k_method
            sta   J_KEY+1
            ldx   ZP_RX_RD              ; object '{' at frame start
            jsr   find_key
            bcs   :err
            inx                         ; skip method value's opening '"'
            cpx   FRAME_NL_ADDR
            beq   :err
            lda   RX_BUF_ADDR,x         ; method[0]
            cmp   #'p'
            beq   :m_ping
            cmp   #'i'
            beq   :m_init
            cmp   #'n'
            beq   :m_notif
            cmp   #'t'
            beq   :m_tools
            _BRA   :err

:m_ping     lda   #$00
            _BRA   :set_id_then_op
:m_init     lda   #$01
            _BRA   :set_id_then_op
:m_notif    lda   #$02                  ; notification: no id needed
            sta   PARSE_OP_ADDR
            rts
:m_tools
* X at method[0]='t'. method[6] = char after "tools/" -> 'l' or 'c'.
            txa
            clc
            adc   #6
            tax
            cpx   FRAME_NL_ADDR
            beq   :err
            lda   RX_BUF_ADDR,x
            cmp   #'l'
            beq   :m_list
            cmp   #'c'
            beq   :m_call
            _BRA   :err
:m_list     lda   #$03
            _BRA   :set_id_then_op
:m_call                                 ; tools/call: capture id, then descend
            jsr   :capture_id
            bcs   :err
            jmp   parse_tools_call       ; sets op $04-$07 + P1/P2/P3

:set_id_then_op                          ; A = op for ping/init/list
            sta   PARSE_OP_ADDR
            jsr   :capture_id
            bcs   :err
            rts
:err        lda   #$FF
            sta   PARSE_OP_ADDR
            rts

* capture_id: find top-level "id", store first-digit offset in PARSE_ID_PTR.
*   C clear if found; C set if not found (caller errors for request ops).
:capture_id
            lda   #<k_id
            sta   J_KEY
            lda   #>k_id
            sta   J_KEY+1
            ldx   ZP_RX_RD
            jsr   find_key
            bcs   :cid_nf
            stx   PARSE_ID_PTR_ADDR      ; X = first id digit
            clc
            rts
:cid_nf     sec
            rts

*-----------------------------------------------------------------------------
* parse_tools_call -- PARSE_ID_PTR already set. Finds params -> name (op
* $04-$07) -> arguments -> arg value pointers (P1/P2/P3). PTMP holds the
* current object offset across find_key calls.
*-----------------------------------------------------------------------------
parse_tools_call
            lda   #<k_params            ; find top-level "params"
            sta   J_KEY
            lda   #>k_params
            sta   J_KEY+1
            ldx   ZP_RX_RD
            jsr   find_key
            bcs   :pc_err
            stx   PTMP_ADDR              ; params '{' offset
            lda   #<k_name               ; find "name" in params
            sta   J_KEY
            lda   #>k_name
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :pc_err
            inx                          ; skip name value's opening '"'
            cpx   FRAME_NL_ADDR
            beq   :pc_err
            lda   RX_BUF_ADDR,x          ; tool name[0]
            cmp   #'s'
            beq   :t_status
            cmp   #'r'
            beq   :t_read
            cmp   #'w'
            beq   :t_write
            cmp   #'k'
            beq   :t_key
:pc_err     lda   #$FF
            sta   PARSE_OP_ADDR
            rts
:t_status   lda   #$04                  ; status: no args
            sta   PARSE_OP_ADDR
            rts
:t_read     lda   #$05
            _BRA   :args
:t_write    lda   #$06
            _BRA   :args
:t_key      lda   #$07
:args       sta   PARSE_OP_ADDR
            lda   #<k_args               ; find "arguments" object in params
            sta   J_KEY
            lda   #>k_args
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :pc_err
            stx   PTMP_ADDR              ; arguments '{' offset
            lda   PARSE_OP_ADDR
            cmp   #$07
            beq   :a_key
            cmp   #$06
            beq   :a_write
* read ($05): a -> P1, l -> P2
            jsr   find_a_into_p1
            bcs   :pc_err
            lda   #<k_l
            sta   J_KEY
            lda   #>k_l
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :pc_err
            stx   PARSE_P2_ADDR
            rts
:tc_err     jmp   :pc_err                ; trampoline: lower-half branches are
*                                        ;  >128 bytes from :pc_err at the top
:a_write                                 ; a -> P1, v(string) -> P2 + P3 len
            jsr   find_a_into_p1
            bcs   :tc_err
            lda   #<k_v
            sta   J_KEY
            lda   #>k_v
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :tc_err
            inx                          ; skip v value's opening '"'
            stx   PARSE_P2_ADDR          ; first hex char
:wv         cpx   FRAME_NL_ADDR
            beq   :tc_err
            lda   RX_BUF_ADDR,x
            cmp   #$22                    ; closing '"'
            beq   :wv_done
            inx
            _BRA   :wv
:wv_done    txa                          ; P3 = closing_quote - first_hex
            sec
            sbc   PARSE_P2_ADDR
            sta   PARSE_P3_ADDR
            rts
:a_key                                    ; k -> P1
            lda   #<k_k
            sta   J_KEY
            lda   #>k_k
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :tc_err
            stx   PARSE_P1_ADDR
            rts

*-----------------------------------------------------------------------------
* find_a_into_p1 -- find "a" in the arguments object (PTMP) and store its
* value offset in PARSE_P1. C clear on success, C set if not found.
*-----------------------------------------------------------------------------
find_a_into_p1
            lda   #<k_a
            sta   J_KEY
            lda   #>k_a
            sta   J_KEY+1
            ldx   PTMP_ADDR
            jsr   find_key
            bcs   :fa_nf
            stx   PARSE_P1_ADDR
            clc
            rts
:fa_nf      sec
            rts

* JSON key literals -- LOW-ASCII (wire keys are 7-bit ASCII), NUL-terminated.
k_method    asc   'method',$00
k_id        asc   'id',$00
k_params    asc   'params',$00
k_name      asc   'name',$00
k_args      asc   'arguments',$00
k_a         asc   'a',$00
k_l         asc   'l',$00
k_v         asc   'v',$00
k_k         asc   'k',$00

* (Old fixed-offset helpers record_arg1_at_plus20 / skip_digits_then_5 /
*  skip_digits_then_6 / skip_digits_at_y removed -- replaced by the
*  order-independent find_key scanner above.)


*-----------------------------------------------------------------------------
* op_handlers -- jump table indexed by parse_op
*
* 65C02 JMP (op_handlers,X) reads a 16-bit address from op_handlers+X.
* X = parse_op * 2 (computed by dispatch via ASL). The error op $FF is
* branched away from before dispatch reaches this table (see BMI in
* parse_dispatch_loop).
*-----------------------------------------------------------------------------
op_handlers
            da    do_ping              ; $00
            da    do_initialize        ; $01
            da    do_notif             ; $02
            da    do_tools_list        ; $03
            da    do_status            ; $04
            da    do_read_memory       ; $05
            da    do_write_memory      ; $06
            da    do_send_keystroke    ; $07


*-----------------------------------------------------------------------------
* do_ping (op $00) -- real JSON-RPC ping response.
*
* Wire output: {"jsonrpc":"2.0","id":<n>,"result":{}}<LF>
*
* Steps:
*   1. LDY parse_id_ptr / JSR parse_int -> id in ZP_PTR ($06-$07).
*      Overflow (out-of-spec id > 65535) -> JMP do_error.
*   2. Stash id in parse_id_lo/hi (ssc_tx_string will clobber ZP_PTR).
*   3. JSR ssc_tx_string for resp_id_prefix.
*   4. Reload id from parse_id_lo/hi into ZP_PTR.
*      JSR emit_dec_word to stream the decimal digits.
*   5. JSR ssc_tx_string for resp_ping_suffix.
*   6. JMP parse_dispatch_loop to drain the next frame.
*-----------------------------------------------------------------------------
do_ping
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcs   :ovr_to_err

            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_ping_suffix
            sta   ZP_PTR
            lda   #>resp_ping_suffix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop

:ovr_to_err jmp   do_error             ; bridge: BCS range can't reach do_error


*-----------------------------------------------------------------------------
* parse_int -- decimal shift-add unsigned 16-bit integer parse.
*
* Input:  Y = ring offset of first decimal digit
* Output: ZP_PTR / ZP_PTR+1 = parsed value (0..65535)
*         Y advanced past last digit (points at first non-digit -- a
*         delimiter like ',' or '}')
*         C = 0 on success, C = 1 on overflow / malformed input
*
* Overflow rule: before each ×10 multiply+add, error if the result would
* exceed 65535 -- i.e. acc > 6553, or acc == 6553 ($1999) with the next
* digit > 5 (6553×10 + 5 = 65535). This admits the full 0..65535 range, so
* the $FFFA/$FFFC/$FFFE NMI/RESET/IRQ vectors are reachable. Also error on:
*   - 6th consecutive digit (max 5 digits for 65535)
*   - zero digits at entry (caller pointed Y at a non-digit)
*
* ×10 algorithm: acc = (acc<<2 + acc) << 1
*   = acc*5 << 1 = acc*10. Uses two scratch bytes (mul10_lo/hi) in LC.
*
* Cycle budget: ~110-120 cycles per digit, ~550 for 5-digit max. At
* 1 MHz that's ~0.6 ms -- well inside per-frame budget.
*-----------------------------------------------------------------------------
parse_int
            _STZ   ZP_PTR
            _STZ   ZP_PTR+1
            ldx   #0                 ; digit count
:digit_loop
            lda   RX_BUF_ADDR,y
            cmp   #'0'
            bcc   :end_digits
            cmp   #'9'+1
            bcs   :end_digits

            cpx   #5
            bcs   :overflow          ; 6th digit -- can't fit in 16 bits

* Overflow guard: would acc × 10 + digit exceed 65535? acc is the value
* BEFORE this digit. Safe iff acc <= 6552, OR acc == 6553 ($1999) with
* digit <= 5 (6553*10+5 = 65535). That top of range matters: $FFFA/$FFFC/
* $FFFE are the NMI/RESET/IRQ vectors -- worth being able to read & write.
            pha                      ; save raw digit byte
            lda   ZP_PTR+1
            cmp   #$1A
            bcs   :overflow_pop      ; hi >= $1A -> acc >= 6656
            cmp   #$19
            bcc   :guard_ok          ; hi < $19 -> acc <= 6399, safe
            lda   ZP_PTR             ; hi == $19 (acc 6400..6655)
            cmp   #$9A
            bcs   :overflow_pop      ; lo >= $9A -> acc >= 6554
            cmp   #$99
            bcc   :guard_ok          ; lo <= $98 -> acc <= 6552, safe
            pla                      ; acc == 6553 exactly: gate on the digit
            cmp   #'6'
            bcs   :overflow          ; digit >= 6 -> would exceed 65535
            pha                      ; digit <= 5: re-save for :guard_ok's PLA
:guard_ok
            pla                      ; restore raw digit byte
            sec
            sbc   #'0'               ; A = digit value 0..9
            pha                      ; save digit value across ×10

* acc *= 10  via  acc = ((acc<<2) + acc) << 1.
* Scratch lives in MAIN_RES (MUL10_LO_ADDR / MUL10_HI_ADDR) because LC
* bank 2 is read-only at runtime -- a STA targeting an LC address is
* silently dropped, which would leave the saved "original acc" at 0 and
* turn the whole multiply into a plain <<3 (acc*8). Don't move it back.
            lda   ZP_PTR
            sta   MUL10_LO_ADDR
            lda   ZP_PTR+1
            sta   MUL10_HI_ADDR
            asl   ZP_PTR
            rol   ZP_PTR+1
            asl   ZP_PTR
            rol   ZP_PTR+1            ; acc *= 4
            clc
            lda   ZP_PTR
            adc   MUL10_LO_ADDR
            sta   ZP_PTR
            lda   ZP_PTR+1
            adc   MUL10_HI_ADDR
            sta   ZP_PTR+1            ; acc = acc*4 + acc = acc*5
            asl   ZP_PTR
            rol   ZP_PTR+1            ; acc *= 2 -> acc*10

* acc += digit
            pla                       ; A = digit value 0..9
            clc
            adc   ZP_PTR
            sta   ZP_PTR
            bcc   :no_carry
            inc   ZP_PTR+1
:no_carry
            inx
            iny
            _BRA   :digit_loop

:end_digits
            cpx   #0
            beq   :overflow           ; zero digits = malformed
            clc                       ; success
            rts

:overflow_pop pla                     ; balance the digit-byte PHA
:overflow   sec                       ; overflow / malformed
            rts


*-----------------------------------------------------------------------------
* do_status (op $04) -- tools/call name=s. Reports machine type and ring
* state in the MCP result.content[0].text wrapper envelope.
*
* Wire output:
*   {"jsonrpc":"2.0","id":<n>,"result":{"content":[{"type":"text","text":
*    "PIPPIN 0.5 m=<mach> wr=<wr-hex> rd=<rd-hex> pw=<pw>"}],"isError":false}}<LF>
*
* Fields:
*   <mach>  ZP_MACHINE_TYPE   decimal 0..5 (machine enum; 5 = unenhanced //e,
*                              reported by the 6502 build only)
*   <wr>    ZP_RX_WR           2-char hex (ring write index)
*   <rd>    ZP_RX_RD           2-char hex (ring read index)
*   <pw>    ZP_PENDING_WORK    decimal 0/1 (always 0 since step 4b moved
*                              dispatch into ssc_irq -- kept for visibility
*                              into the flag in case it ever gets re-purposed)
*-----------------------------------------------------------------------------
do_status
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcs   :status_err

            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

* {"jsonrpc":"2.0","id":
            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

* <id> as decimal
            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

* ,"result":{"content":[{"type":"text","text":"PIPPIN 0.5 m=
            lda   #<resp_status_mid
            sta   ZP_PTR
            lda   #>resp_status_mid
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

* machine type (0..5) as decimal
            lda   ZP_MACHINE_TYPE
            sta   ZP_PTR
            _STZ   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

*  wr=<hex>
            lda   #<resp_status_wr
            sta   ZP_PTR
            lda   #>resp_status_wr
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            lda   ZP_RX_WR
            jsr   EMIT_HEX_BYTE_ADDR

*  rd=<hex>
            lda   #<resp_status_rd
            sta   ZP_PTR
            lda   #>resp_status_rd
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            lda   ZP_RX_RD
            jsr   EMIT_HEX_BYTE_ADDR

*  pw=<dec>
            lda   #<resp_status_pw
            sta   ZP_PTR
            lda   #>resp_status_pw
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            lda   ZP_PENDING_WORK
            sta   ZP_PTR
            _STZ   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

* "}],"isError":false}}<LF>
            lda   #<resp_status_suffix
            sta   ZP_PTR
            lda   #>resp_status_suffix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop

:status_err jmp   do_error


*-----------------------------------------------------------------------------
* do_initialize (op $01) -- MCP handshake response. Ignores incoming
* params (harness handles capability negotiation per spec §9.6); the
* parser already scanned past id and stopped at D2 so we don't need to
* walk the params interior. Just emit the pre-baked envelope with the
* request id substituted in.
*-----------------------------------------------------------------------------
do_initialize
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcs   :init_err

            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_initialize_body
            sta   ZP_PTR
            lda   #>resp_initialize_body
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop

:init_err   jmp   do_error


*-----------------------------------------------------------------------------
* do_notif (op $02) -- notifications/initialized. No id, no response.
* Mark session_active so future handlers could refuse pre-handshake
* traffic. For now nobody checks it; the byte is informational.
*-----------------------------------------------------------------------------
do_notif
            lda   #$01
            sta   SESSION_ACTIVE_ADDR
* A notification sends NO response, so -- unlike every reply-bearing op --
* there is no paced ssc_tx_byte to drain RX during the deaf IRQ window. A
* client that streams its next frame immediately after the notification
* would lose that frame's leading byte (ring misaligns -> ERR). So drain
* inbound bytes here into the ring until we capture the next frame's '\n'
* (then parse_dispatch_loop processes it, and its TX resumes RX-draining),
* or until the line goes idle for ~a few char-times (lone notification).
:nd_reset   ldx   #$0A                 ; idle-timeout outer (reset on each byte)
:nd_out     ldy   #$B4                 ; inner
:nd_in      lda   SSC_STATUS
            and   #$08                 ; RDRF -- byte waiting?
            bne   :nd_got
            dey
            bne   :nd_in
            dex
            bne   :nd_out
            _BRA   :nd_done             ; idle: no follow-on frame
:nd_got     lda   SSC_DATA            ; A holds the byte across the save (live)
            _PHX  ZP_T6502_A
            _PHY  ZP_T6502_B
            ldx   ZP_RX_WR
            sta   RX_BUF_ADDR,x
            inx
            stx   ZP_RX_WR
            _PLY  ZP_T6502_B
            _PLX  ZP_T6502_A
            cmp   #$0A                  ; captured a frame terminator?
            beq   :nd_done              ; yes -- let dispatch process it
            _BRA   :nd_reset             ; more to come; reset idle timeout
:nd_done    jmp   parse_dispatch_loop


*-----------------------------------------------------------------------------
* do_tools_list (op $03) -- emit the pre-baked tools/list response.
*
* Lists all four tools (s/r/w/k) with their inputSchema. The whole
* response (after id) is one static RODATA blob -- no runtime
* substitutions besides the id, so this handler is essentially
* "emit prefix, emit id, emit body". The body lives at the bottom of
* lcrom.s in resp_tools_list_body.
*-----------------------------------------------------------------------------
do_tools_list
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcs   :tl_err

            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_tools_list_body
            sta   ZP_PTR
            lda   #>resp_tools_list_body
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop

:tl_err     jmp   do_error


*-----------------------------------------------------------------------------
* Stub op handlers (steps 7+ are replacing these one by one).
* Each remaining stub emits "got op N\r\n" then JMPs back to the
* parse_dispatch loop to drain the next frame.
*
* Pattern: load A=lo, X=hi of message, branch to emit_op_msg. Saves
* ~5 bytes per handler vs each having its own JSR ssc_tx_string.
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* do_read_memory (op $05) -- tools/call name=r. Args: a (address, 16-bit),
* l (length, 1..255). Streams the bytes back as lowercase hex inside the
* MCP content.text envelope.
*
* Length is capped at 255 (single-byte counter) rather than spec's 256.
*
* I/O safety: rejects any read that overlaps $C000-$CFFF or wraps past
* $FFFF, per spec §6 / §9.2. The trampoline's LC bank-switch latches
* live in that range and reading them has side effects.
*-----------------------------------------------------------------------------
do_read_memory
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcc   :rm_id_ok
            jmp   :rm_err
:rm_id_ok
            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            ldy   PARSE_P1_ADDR
            jsr   parse_int
            bcc   :rm_addr_parsed
            jmp   :rm_err
:rm_addr_parsed
            lda   ZP_PTR
            sta   PARSE_ADDR_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ADDR_HI_ADDR

            ldy   PARSE_P2_ADDR
            jsr   parse_int
            bcc   :rm_len_parsed
            jmp   :rm_err
:rm_len_parsed
            lda   ZP_PTR+1
            beq   :rm_len_hi_ok
            jmp   :rm_err              ; length >= 256: reject
:rm_len_hi_ok
            lda   ZP_PTR
            bne   :rm_len_nz
            jmp   :rm_err              ; length == 0: reject
:rm_len_nz
            sta   PARSE_LEN_LO_ADDR

* Range check: compute end = addr + len (16-bit).
* Reject on wrap past $FFFF, or any overlap with $C000-$CFFF.
            clc
            lda   PARSE_ADDR_LO_ADDR
            adc   PARSE_LEN_LO_ADDR
            sta   MUL10_LO_ADDR        ; reuse scratch -- end_lo
            lda   PARSE_ADDR_HI_ADDR
            adc   #$00
            sta   MUL10_HI_ADDR        ; end_hi
            bcc   :rm_no_wrap
            jmp   :rm_err              ; wrap past $FFFF
:rm_no_wrap

* Mid-function error trampoline so all BCS/BCC-JMPs from the upper half
* can reach :rm_err, AND the lower-half code that follows can too. (The
* function is too big for a single end-of-function branch target.)
            _BRA   :rm_skip_err1
:rm_err     jmp   do_error
:rm_skip_err1

* Start in I/O range? Reject if addr_hi in $C0..$CF.
            lda   PARSE_ADDR_HI_ADDR
            cmp   #$C0
            bcc   :rm_start_safe
            cmp   #$D0
            bcs   :rm_start_safe       ; start_hi >= $D0, safe (above I/O)
            jmp   :rm_err
:rm_start_safe
* End crosses into I/O? Range overlaps $C000-$CFFF iff:
*   start < $D000 AND end > $C000
* We already know start is not in $C0..$CF (else rejected above).
            lda   PARSE_ADDR_HI_ADDR
            cmp   #$D0
            bcs   :rm_addr_ok          ; start >= $D000, end can't cross down
            lda   MUL10_HI_ADDR
            cmp   #$C0
            bcc   :rm_addr_ok          ; end < $C000, safe
            bne   :rm_err_xs           ; end > $CFFF and start < $D0 -> crosses
            lda   MUL10_LO_ADDR
            beq   :rm_addr_ok          ; end == $C000 exactly (last byte $BFFF)
:rm_err_xs  jmp   :rm_err

:rm_addr_ok
* Emit response: {"jsonrpc":"2.0","id":<n>,"result":{"content":[{"type":
*                 "text","text":"<hex-bytes>"}],"isError":false}}<LF>
            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_text_open
            sta   ZP_PTR
            lda   #>resp_text_open
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

* Memory walk: ZP_PTR = addr, Y = 0..len-1.
            lda   PARSE_ADDR_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ADDR_HI_ADDR
            sta   ZP_PTR+1
            ldy   #0
:rm_loop    lda   (ZP_PTR),y
            jsr   EMIT_HEX_BYTE_ADDR    ; preserves Y
            iny
            cpy   PARSE_LEN_LO_ADDR
            bne   :rm_loop

            lda   #<resp_text_close
            sta   ZP_PTR
            lda   #>resp_text_close
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop

*-----------------------------------------------------------------------------
* do_write_memory (op $06) -- tools/call name=w. Args: a (address,
* 16-bit), v (lowercase hex string, 2 chars/byte, max 64 bytes per write).
*
* Same I/O / wrap guards as read_memory, plus rejects writes to
* $BF00-$BFFF (ProDOS globals).
*
* Hex decode: per spec §9.3 we trust the harness (lowercase 0-9/a-f only).
* No range validation per nibble. Each pair becomes a byte and gets
* written via a self-modified STA whose operand is patched on entry.
*-----------------------------------------------------------------------------
do_write_memory
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcc   :wm_id_ok
            jmp   :wm_err
:wm_id_ok
            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            ldy   PARSE_P1_ADDR
            jsr   parse_int
            bcc   :wm_addr_parsed
            jmp   :wm_err
:wm_addr_parsed
            lda   ZP_PTR
            sta   PARSE_ADDR_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ADDR_HI_ADDR

* Validate hex length: must be even, 2..128 chars (1..64 bytes).
            lda   PARSE_P3_ADDR
            bne   :wm_len_nz
            jmp   :wm_err              ; zero-length hex
:wm_len_nz
            lsr                         ; halve (now byte count)
            bcc   :wm_even
            jmp   :wm_err              ; original was odd -- malformed
:wm_even
            cmp   #65
            bcc   :wm_under65
            jmp   :wm_err              ; > 64 bytes -- reject
:wm_under65
            sta   PARSE_LEN_LO_ADDR    ; PARSE_LEN_LO = byte count

* Range validation: same shape as read_memory.
            clc
            lda   PARSE_ADDR_LO_ADDR
            adc   PARSE_LEN_LO_ADDR
            sta   MUL10_LO_ADDR
            lda   PARSE_ADDR_HI_ADDR
            adc   #$00
            sta   MUL10_HI_ADDR
            bcc   :wm_no_wrap
            jmp   :wm_err              ; wrap
:wm_no_wrap

* Mid-function trampoline (function exceeds branch range otherwise).
            _BRA   :wm_skip_err
:wm_err     jmp   do_error
:wm_skip_err

* Reject start in $C000-$CFFF or $BF00-$BFFF.
            lda   PARSE_ADDR_HI_ADDR
            cmp   #$BF
            bne   :wm_not_bf
            jmp   :wm_err
:wm_not_bf
            cmp   #$C0
            bcc   :wm_start_safe
            cmp   #$D0
            bcs   :wm_start_safe
            jmp   :wm_err
:wm_start_safe
* End cross check. The forbidden write zone is contiguous $BF00-$CFFF
* (ProDOS globals + I/O), so guarding the LOWER boundary ($BF00) also
* covers $C000-$CFFF for a write that starts below $BF00 and runs up into
* it. (read_memory only guards $C000 -- reading globals is side-effect-free
* -- but a WRITE crossing into $BF00 would corrupt MLIACTV/bitmap/etc.)
            lda   PARSE_ADDR_HI_ADDR
            cmp   #$D0
            bcs   :wm_addr_ok          ; start >= $D000 (LC RAM), safe
            lda   MUL10_HI_ADDR         ; end_hi
            cmp   #$BF
            bcc   :wm_addr_ok          ; end < $BF00, safe
            bne   :wm_err_xs           ; end_hi > $BF -> crosses $BF00/$C000
            lda   MUL10_LO_ADDR
            beq   :wm_addr_ok          ; end == $BF00 exactly (last byte $BEFF)
:wm_err_xs  jmp   :wm_err

:wm_addr_ok
* ZP_PTR = destination address. Writes use STA (ZP_PTR) -- 65C02
* zero-page indirect (no Y) so we can keep Y as the ring source offset.
            lda   PARSE_ADDR_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ADDR_HI_ADDR
            sta   ZP_PTR+1

* Decode hex pairs from RX_BUF[PARSE_P2..PARSE_P2+P3) and write to (ZP_PTR).
* Y = ring offset (source), X = byte-progress counter.
            ldy   PARSE_P2_ADDR
            ldx   #0
:wm_decode
            lda   RX_BUF_ADDR,y          ; high nibble char
            jsr   hex_nib                ; -> A = 0..15
            asl
            asl
            asl
            asl
            sta   MUL10_HI_ADDR          ; reuse scratch for hi nibble
            iny
            lda   RX_BUF_ADDR,y          ; low nibble char
            jsr   hex_nib
            ora   MUL10_HI_ADDR          ; A = full byte
            _STAIND ZP_PTR;ZP_T6502_D    ; write *(ZP_PTR); preserves A and the
*                                        ;  live ring offset in Y. (65C02 emits
*                                        ;  STA (zp); 6502 STA (zp),Y with Y=0.)
            inc   ZP_PTR
            bne   :wm_no_carry
            inc   ZP_PTR+1
:wm_no_carry
            iny
            inx
            cpx   PARSE_LEN_LO_ADDR
            bne   :wm_decode

* Success: emit minimal envelope with "OK" payload.
            jsr   emit_ok_envelope
            jmp   parse_dispatch_loop


*-----------------------------------------------------------------------------
* hex_nib -- convert ASCII hex char ('0'-'9', 'a'-'f') in A to 0..15.
* Lowercase only per spec §3.6. No validation.
*-----------------------------------------------------------------------------
hex_nib
            sec
            sbc   #'0'                   ; '0'..'9' -> 0..9
            cmp   #10
            bcc   :hn_done
            sbc   #$27                   ; 'a'-'0'-10 = $61-$30-$0A = $27
:hn_done    rts                          ; 'a'-'f' -> 10..15


*-----------------------------------------------------------------------------
* do_send_keystroke (op $07) -- tools/call name=k. Single arg k=keycode
* (0..127). Sets ZP_PENDING_KEY so the next host keyboard read returns
* the keycode with bit 7 set (KSW inject path in ksw_hook_common).
*-----------------------------------------------------------------------------
do_send_keystroke
            ldy   PARSE_ID_PTR_ADDR
            jsr   parse_int
            bcs   :sk_err
            lda   ZP_PTR
            sta   PARSE_ID_LO_ADDR
            lda   ZP_PTR+1
            sta   PARSE_ID_HI_ADDR

            ldy   PARSE_P1_ADDR
            jsr   parse_int
            bcs   :sk_err
            lda   ZP_PTR+1
            bne   :sk_err              ; key > 255
            lda   ZP_PTR
            cmp   #128
            bcs   :sk_err              ; key >= 128 (must be 7-bit clean)
            sta   ZP_PENDING_KEY        ; inject on next keyboard read

            jsr   emit_ok_envelope
            jmp   parse_dispatch_loop

:sk_err     jmp   do_error


*-----------------------------------------------------------------------------
* emit_ok_envelope -- helper shared by do_write_memory and do_send_keystroke.
* Emits the full envelope with id substituted and "OK" as the text body.
* Caller has already stashed id into PARSE_ID_LO/HI_ADDR.
*-----------------------------------------------------------------------------
emit_ok_envelope
            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_text_open
            sta   ZP_PTR
            lda   #>resp_text_open
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   #<resp_ok_body
            sta   ZP_PTR
            lda   #>resp_ok_body
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   #<resp_text_close
            sta   ZP_PTR
            lda   #>resp_text_close
            sta   ZP_PTR+1
            jmp   SSC_TX_STRING_ADDR     ; tail-call -- string RTS returns to handler


* do_error -- JSON-RPC error reply for any rejected or malformed request.
* Emits a CallToolResult with "isError":true, echoing the request id the
* dispatching handler already stashed in PARSE_ID_LO/HI before it validated
* (read_memory stashes the id at :rm_id_ok, well before any range-check
* jump here; write_memory and send_keystroke do the same). A bare parse
* error that reaches here before any handler ran echoes the prior request's
* id -- imperfect for that rare case, but a valid JSON-RPC frame, never the
* old raw "ERR" sentinel that crashed conformant MCP clients.
do_error
            lda   #<resp_id_prefix
            sta   ZP_PTR
            lda   #>resp_id_prefix
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR

            lda   PARSE_ID_LO_ADDR
            sta   ZP_PTR
            lda   PARSE_ID_HI_ADDR
            sta   ZP_PTR+1
            jsr   EMIT_DEC_WORD_ADDR

            lda   #<resp_err_body
            sta   ZP_PTR
            lda   #>resp_err_body
            sta   ZP_PTR+1
            jsr   SSC_TX_STRING_ADDR
            jmp   parse_dispatch_loop


*-----------------------------------------------------------------------------
* RODATA -- 7-bit ASCII strings emitted over the wire.
*
* Stub messages still use \r\n for visual readability on `nc` during
* step-by-step bring-up. The real JSON-RPC responses (do_ping, etc.)
* use bare \n per spec §3.1 newline-delimited framing.
*
* msg_op0 dropped in step 4 -- do_ping now emits a real JSON-RPC
* response. Step 5+ will drop the rest as their handlers go live.
*-----------------------------------------------------------------------------
resp_id_prefix    asc   '{"jsonrpc":"2.0","id":',$00
resp_ping_suffix  asc   ',"result":{}}',$0A,$00

resp_status_mid    asc   ',"result":{"content":[{"type":"text","text":"PIPPIN 0.5 m=',$00
resp_status_wr     asc   ' wr=',$00
resp_status_rd     asc   ' rd=',$00
resp_status_pw     asc   ' pw=',$00
resp_status_suffix asc   '"}],"isError":false}}',$0A,$00

resp_text_open     asc   ',"result":{"content":[{"type":"text","text":"',$00
resp_text_close    asc   '"}],"isError":false}}',$0A,$00
resp_ok_body       asc   'OK',$00

resp_initialize_body
            asc   ',"result":{"protocolVersion":"2024-11-05","capabilities":'
            asc   '{"tools":{}},"serverInfo":{"name":"pippin","version":"0.5"}}}'
            dfb   $0A,$00

* tools/list payload. ~500 bytes of static JSON. The four tools use the
* spec's one-character names (s/r/w/k) -- the host harness expands them
* to read_memory etc. before forwarding to its LLM client.
resp_tools_list_body
            asc   ',"result":{"tools":['
            asc   '{"name":"s","description":"PIPPIN status",'
            asc   '"inputSchema":{"type":"object"}},'
            asc   '{"name":"r","description":"Read Apple II memory",'
            asc   '"inputSchema":{"type":"object","properties":'
            asc   '{"a":{"type":"integer"},"l":{"type":"integer"}},'
            asc   '"required":["a","l"]}},'
            asc   '{"name":"w","description":"Write Apple II memory (hex bytes)",'
            asc   '"inputSchema":{"type":"object","properties":'
            asc   '{"a":{"type":"integer"},"v":{"type":"string"}},'
            asc   '"required":["a","v"]}},'
            asc   '{"name":"k","description":"Inject keystroke",'
            asc   '"inputSchema":{"type":"object","properties":'
            asc   '{"k":{"type":"integer"}},"required":["k"]}}'
            asc   ']}}'
            dfb   $0A,$00

* do_error's body: a valid isError:true CallToolResult (replaces the old "ERR"
* bring-up stub). resp_id_prefix + <id> + this = a complete JSON-RPC frame.
resp_err_body asc   ',"result":{"content":[{"type":"text","text":"request rejected"}],"isError":true}}',$0A,$00


*-----------------------------------------------------------------------------
* Pad to $E000 (full 4 KB LC bank 2 image).
*-----------------------------------------------------------------------------
            ds    $E000-*,$00

