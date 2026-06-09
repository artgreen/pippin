*-----------------------------------------------------------------------------
* equates-common.s -- build-agnostic constants shared by BOTH builds:
*   - PIPPIN  (JSON/MCP path):    put equates-common  +  put equates
*   - PIP     (fast binary path): put equates-common  +  put equates-pip
*
* Single source of truth for the hardware addresses, zero-page allocations,
* machine codes, and the MAIN_RES anchor addresses that the SHARED source
* files (ssc_common.s, ksw_hook.s) and both builds depend on. Change a
* hardware address or the RX-ring location HERE, once -- not in two places.
*
* PUT this FIRST, before the build-specific equates: they reference
* STATE_BASE_ADDR (and the other anchors) defined here, and EQU cannot
* forward-reference. Nested PUT does not work in Merlin32 v1.2 beta 2 (a
* PUT'd file's own PUT is silently ignored), so each top-level source PUTs
* this file directly rather than letting equates.s/equates-pip.s pull it in.
*-----------------------------------------------------------------------------

* Per ProDOS TRM Ch 6, the dispatcher preserves $FA-$FF across IRQ entry, so
* those are technically the safest slots for handler state. The TSR plan says
* "$EB-$EF as globals" because we touch this state mainly from the foreground
* KSW hook, not deep inside the IRQ -- and BASIC.SYSTEM/Applesoft don't tread
* on $EB-$EF in the configurations we care about. If you stomp something,
* relocate the variables; nothing in the code below assumes a specific value.
ZP_PENDING_WORK equ   $EB         ; old deferred-dispatch flag; never set non-zero now,
*                                 ; but do_status still reads and emits it as pw=
ZP_PENDING_KEY  equ   $EC         ; non-zero: byte to inject on next foreground read
ZP_RX_WR        equ   $ED         ; ring buffer write index (modified by IRQ)
ZP_RX_RD        equ   $EE         ; ring buffer read index  (modified by foreground)
ZP_MACHINE_TYPE equ   $EF         ; detected machine code (one of MACH_* below)

* IRQ-safe scratch for the NMOS-6502 build's CPU macros (cpu.macs). On the 65C02
* build these are UNUSED -- _PHX/_PHY/_PLX/_PLY/_STZA/_STAIND expand to native
* push/pull/stz/sta. On the 6502 build they substitute zero-page saves, and
* those saves run INSIDE the IRQ (ssc_tx_byte TX pacing, the LC parser/dispatch)
* where they would corrupt the foreground if they borrowed a foreground-live
* byte. ProDOS preserves $FA-$FF across IRQ entry (TRM Ch 6), so the
* dispatcher saves and restores them around our handler -- making $FA-$FF the
* designated interrupt-handler scratch.
* Nothing else in PIPPIN touches $FA-$FF (grep-verified), so they are free.
*   ZP_T6502_A ($FE): _PHX/_PLX (ssc_tx_byte, do_notif). X save.
*   ZP_T6502_B ($FD): _PHY/_PLY (ssc_tx_byte, do_notif, parse_dispatch). Y save.
*   ZP_T6502_C ($FC): emit_dec_word's _PHX/_PLX, which NESTS over a JSR to
*                     ssc_tx_byte (itself a _PHX/_PHY user) -- must differ from
*                     ZP_T6502_A/B so the outer save is not clobbered.
*   ZP_T6502_D ($FF): _STAIND (do_write_memory; Y save) and _STZA (ksw_hook
*                     :inject; X save). Never nested with each other or the above.
*   ZP_T6502_PTR ($FA/$FB): 2-byte indirect pointer for _JMPINDX, which emulates
*                     the 65C02 jmp (table,x) at the dispatch tail (parse_dispatch,
*                     cad_scan). Live only for that one jump; no other macro nests
*                     over it. $FA/$FB are the last free bytes of the preserved set.
ZP_T6502_A      equ   $FE
ZP_T6502_B      equ   $FD
ZP_T6502_C      equ   $FC
ZP_T6502_D      equ   $FF
ZP_T6502_PTR    equ   $FA         ; (uses $FA/$FB)

* 16-bit pointer pair, used by the install-time prints AND by the runtime
* handlers inside the IRQ (string TX, the read/write loops, parse_int output).
* The resident claims $06/$07 for its lifetime and does NOT save/restore them
* around dispatch: foreground ML that uses these bytes will see them clobbered
* whenever a frame dispatches. Accepted trade-off (ProDOS only preserves
* $FA-$FF, which the 6502 macro scratch already owns); a foreground program
* sharing the machine with PIPPIN should avoid $06/$07 -- as demos/asm/life.s
* does.
ZP_PTR          equ   $06         ; 16-bit pointer (install prints + IRQ handlers)
ZP_PTR_H        equ   $07

*---- Machine type codes -----------------------------------------------------
MACH_UNKNOWN    equ   $00
MACH_IIE_ENH    equ   $01
MACH_IIC        equ   $02
MACH_IIC_PLUS   equ   $03
MACH_IIGS       equ   $04
MACH_IIE        equ   $05         ; unenhanced //e (NMOS 6502); 6502 build only

*---- SSC hard-coded to slot 2 (single-slot for now) -------------------------
* Per-slot I/O page is $C0(N+8) -- slot 2 base = $C0A0, range $C0A0..$C0AF.
* Within that page the SSC manual puts the 6551 ACIA at offsets 8..11, so
* slot 2's data/status/command/control registers are $C0A8..$C0AB.
* Firmware ROM is $CN00..$CNFF -- slot 2 = $C200..$C2FF.
SSC_DATA        equ   $C0A8       ; data register (RX/TX)
SSC_STATUS      equ   $C0A9       ; status register; any write resets the 6551
SSC_COMMAND     equ   $C0AA       ; command register (DTR, IRQ enables, parity)
SSC_CONTROL     equ   $C0AB       ; control register (baud rate, word size, stop)

SSC_FW_ID1      equ   $C205       ; Pascal 1.1 ID byte -- expect $38
SSC_FW_ID2      equ   $C207       ; expect $18
SSC_FW_ID3      equ   $C20B       ; expect $01
SSC_FW_ID4      equ   $C20C       ; expect $31

*---- ProDOS MLI -------------------------------------------------------------
PRODOS_MLI      equ   $BF00
MLI_ALLOC_IRQ   equ   $40
MLI_DEALLOC_IRQ equ   $41
MLIACTV         equ   $BF9B       ; non-zero if MLI is on the stack -- don't reenter

*---- BASIC.SYSTEM -----------------------------------------------------------
BASIC_ENTRY     equ   $BE00       ; if BASIC.SYSTEM is resident, this is a JMP ($4C)
BASIC_INPUT_VEC equ   $BE32       ; word: BASIC.SYSTEM's indirect input vector

*---- Bare ProDOS / Applesoft keyboard-input vector --------------------------
KSWL            equ   $38
KSWH            equ   $39

*---- Monitor entry points ---------------------------------------------------
COUT            equ   $FDED       ; print A to current output (preserves A on //e+)
CROUT           equ   $FD8E       ; print CR
PRBYTE          equ   $FDDA       ; print A as 2 high-ASCII hex digits

*---- MAIN_RES anchors (identical in both builds) ----------------------------
* MAIN_RES sits just below BASIC.SYSTEM's HIMEM ($9600), pages $90-$95. Both
* builds copy the resident image to $9000 and hook the KSW vectors at
* KSW_HOOK_ADDR / ROM_KSW_HOOK_ADDR. The per-build memory map -- the state
* block, and (JSON only) the LC bank 2 layout and parser scratch -- lives in
* equates.s / equates-pip.s, which both build on STATE_BASE_ADDR below.
MAINRES_BASE      equ $9000       ; first byte of MAIN_RES
KSW_HOOK_ADDR     equ $9000       ; trampoline entry for $BE32 (BASIC.SYSTEM path)
ROM_KSW_HOOK_ADDR equ $9020       ; trampoline entry for $38/$39 (ROM KSW path)
STATE_BASE_ADDR   equ $9080       ; base of the per-build state-vars block
MLI_PARAMS        equ $93F0       ; ALLOC_INTERRUPT param block (padded to fixed addr)
RX_BUF_ADDR       equ $9400       ; 256-byte ring buffer, page-aligned

* Pages we occupy: $90, $91, $92, $93, $94 = 5 pages.
* Allow 1 extra ($95) as headroom for future growth.
MAINRES_PAGES   equ   6           ; copy 6 pages = $600 bytes from image to $9000

*---- ProDOS system bit map --------------------------------------------------
* Bit 7 = lowest-numbered page in each byte's group of 8.
* Byte $BF6A covers pages $90-$97; mask $FC marks pages $90-$95.
PRODOS_BITMAP   equ   $BF6A
MAINRES_BITMASK equ   $FC         ; pages $90-$95
