*-----------------------------------------------------------------------------
* equates.s -- JSON/MCP build (PIPPIN) specific memory map.
*
* PUT AFTER equates-common.s, which defines the shared HW/ZP/SSC/MLI/machine
* constants and the MAIN_RES anchors (MAINRES_BASE, KSW_HOOK_ADDR,
* ROM_KSW_HOOK_ADDR, STATE_BASE_ADDR, MLI_PARAMS, RX_BUF_ADDR, MAINRES_PAGES).
* This file adds only what the JSON path needs on top of those: the JSON
* state block, the LC-callable parser scratch, the ssc_tx_string/emit entry
* addresses, and the full LC bank 2 layout. PIP (equates-pip.s)
* defines a different, compacted state block and no LC layout at all.
*-----------------------------------------------------------------------------

J_KEY           equ   ZP_PTR      ; JSON parser: ptr to target key ($06/$07),
*                                 ; aliased onto ZP_PTR. Handlers reload ZP_PTR
*                                 ; via parse_int before use, so reuse is safe.

* State vars block, pinned to a known address (STATE_BASE_ADDR, in
* equates-common.s) so install.s can write into them by absolute address.
* mainres.s code references the same bytes by label and the addresses match.
* If the trampoline grows past STATE_BASE_ADDR, bump it (in equates-common.s)
* and re-test install.s writes. NOTE: this layout differs from the fast
* path's -- equates-pip.s has no SAVED_LC_READ / PARSE_ID_* bytes, so its
* SAVED_ROM_LO/HI land at STATE_BASE_ADDR+3/+4 instead of +8/+9.
HOOKED_BASIC_ADDR   equ STATE_BASE_ADDR     ; 1 if $BE32 hooked, 0 if only $38 hooked
SAVED_BASIC_LO_ADDR equ STATE_BASE_ADDR+1   ; chain target for $BE32 hook (lo)
SAVED_BASIC_HI_ADDR equ STATE_BASE_ADDR+2   ; chain target for $BE32 hook (hi, adjacent)
SAVED_LC_READ_ADDR  equ STATE_BASE_ADDR+3   ; bit 7: pre-trampoline LC read mode
PARSE_OP_ADDR       equ STATE_BASE_ADDR+4   ; parser output: 0..7 op, or $FF on err
PARSE_ID_LO_ADDR    equ STATE_BASE_ADDR+5   ; request id lo (after handler parse_int)
PARSE_ID_HI_ADDR    equ STATE_BASE_ADDR+6   ; request id hi (adjacent)
PARSE_ID_PTR_ADDR   equ STATE_BASE_ADDR+7   ; Y offset in ring of first id digit
SAVED_ROM_LO_ADDR   equ STATE_BASE_ADDR+8   ; chain target for $38 hook (lo)
SAVED_ROM_HI_ADDR   equ STATE_BASE_ADDR+9   ; chain target for $38 hook (hi, adjacent)

* LC-callable scratch in MAIN_RES. Anything LC parse_int / handler code
* needs to write at runtime MUST live here -- LC bank 2 is mapped read-
* only when our trampoline switches to it ($C080), so STAs into the LC
* address range are silently dropped. parse_int's *10 used to live with
* the routine in LC and produced acc*8 instead of acc*10; moving the
* scratch into writable RAM fixed that.
MUL10_LO_ADDR      equ $908E      ; parse_int *10 scratch (1 byte)
MUL10_HI_ADDR      equ $908F
SESSION_ACTIVE_ADDR equ $9090     ; 1 once notifications/initialized received
PARSE_P1_ADDR      equ $9091      ; Y offset of arg-1 first digit/char in ring
PARSE_P2_ADDR      equ $9092      ; Y offset of arg-2 first digit/char in ring
PARSE_P3_ADDR      equ $9093      ; length of write_memory hex-value field
PARSE_ADDR_LO_ADDR equ $9094      ; saved address after first parse_int
PARSE_ADDR_HI_ADDR equ $9095
PARSE_LEN_LO_ADDR  equ $9096      ; saved length (read_memory) -- 1-byte cap
FRAME_NL_ADDR      equ $9097      ; JSON parser: frame '\n' ring offset (bound)
JDEPTH_ADDR        equ $9098      ; JSON parser: skip_value nesting depth
PTMP_ADDR          equ $9099      ; JSON parser: object offset across find_key calls

SSC_TX_STRING_ADDR equ $9100       ; ssc_tx_string entry (forced via DS pad in mainres.s)
EMIT_HEX_BYTE_ADDR equ $9120       ; emit_hex_byte entry (forced via DS pad in mainres.s)
EMIT_DEC_WORD_ADDR equ $9140       ; emit_dec_word entry (forced via DS pad in mainres.s)

*---- LC bank 2 layout -------------------------------------------------------
* Language Card RAM bank 2 holds the parser + tool handlers + RODATA.
* ProDOS reserves bank 1; we use bank 2 exclusively. Image copied at
* install time via $C083-twice (write-enable bank 2).
LC_BASE         equ   $D000       ; first byte of LC bank 2 content
LC_PARSE_DISPATCH equ $D000       ; trampoline target (always at $D000)
LC_PAGES        equ   16          ; copy 16 pages = $1000 bytes for $D000-$DFFF

* LC soft switches (single-read; runtime trampoline uses these).
LC_RD_BANK2     equ   $C080       ; read LC bank 2 RAM, write PROTECT
LC_RD_ROM       equ   $C08A       ; read ROM, write protect (bank 1 select)
LC_RD_BANK1     equ   $C088       ; read LC bank 1 RAM, write protect

* LC soft switch (read TWICE; install-time write-enable for image copy).
LC_RW_BANK2     equ   $C083       ; read LC bank 2 RAM, WRITE-ENABLE bank 2
                                  ; (must be READ twice consecutively to
                                  ; arm the write-enable latch)

* LC status registers (read-only).
LC_STATE        equ   $C012       ; bit 7: 1 = reading LC RAM, 0 = reading ROM
