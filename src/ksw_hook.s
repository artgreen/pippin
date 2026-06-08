*-----------------------------------------------------------------------------
* ksw_hook.s -- the foreground KSW (KEYIN) hook, shared verbatim by both
* MAIN_RES builds (src/mainres.s = PIPPIN, src/mainres-pip.s = PIP).
*
* PUT FIRST in each build (immediately after `put equates*`) so ksw_hook
* lands at $9000 and rom_ksw_hook at $9020 -- the exact addresses install*.s
* writes into the KSW vectors (KSW_HOOK_ADDR / ROM_KSW_HOOK_ADDR). The
* `ds $9020-*` below depends on this being the first emitted code. Holds no
* ORG/equates of its own; the including file must `put` its equates first
* (for ZP_PENDING_KEY).
*
* KEYIN replacement that polls both $C000 and the soft-inject byte
* (ZP_PENDING_KEY).
*
* Why a poll-loop instead of chaining to ROM KEYIN at $FD1B: once execution
* falls into KEYIN's `LDA $C000 / BPL loop` it doesn't return until a hardware
* keystroke lands. A soft-inject byte set by send_keystroke during that wait
* would be deferred until the host next re-enters KSW (i.e. after a real
* keystroke from the user). That defeats the purpose. So instead of chaining
* we poll both sources here -- ssc_irq still runs during the poll (I-flag is 0
* in foreground context), so a soft-inject from a received tools/call lands in
* ZP_PENDING_KEY mid-poll and the loop picks it up on the next iteration.
*
* Limitation: Applesoft's mid-program Ctrl-C check polls $C000 directly
* between statements, bypassing both $BE32 and $38. Soft-injecting a Ctrl-C
* via send_keystroke during a long FOR/NEXT is therefore not possible from
* PIPPIN alone -- it requires an emulator-side keyboard-buffer hook.
*
*   ksw_hook       ($9000) -- entry installed at $BE32 (if BASIC.SYSTEM resident)
*   rom_ksw_hook   ($9020) -- entry installed at $38/$39
*
* Both fall through to the same poll loop. saved_basic_* / saved_rom_* are
* still stashed at install time for a future teardown but no longer drive
* runtime chaining.
*-----------------------------------------------------------------------------
ksw_hook                                ; $9000 -- BASIC.SYSTEM $BE32 entry
            _BRA  ksw_hook_common

* Pad to $9020 so rom_ksw_hook lands at its fixed address and ksw_hook above
* has room to grow.
            ds    $9020-*,$00

rom_ksw_hook                            ; $9020 -- ROM/bare-ProDOS $38 entry
            ;  fall through

ksw_hook_common
:poll_loop  lda   ZP_PENDING_KEY
            bne   :inject
            lda   $C000                 ; KBD register
            bpl   :poll_loop            ; b7 clear -- no key
            bit   $C010                 ; clear strobe (A preserved)
            clc                         ; KSW convention: C=0 on key
            rts

:inject     ora   #$80                  ; ensure b7 set. The key byte is LIVE in A
            _STZA ZP_PENDING_KEY;ZP_T6502_D   ; zero the flag WITHOUT touching A
*                                       ;  (65C02 stz; 6502 saves/restores X via
*                                       ;  ZP_T6502_D, leaving A and Y intact --
*                                       ;  the KSW contract preserves X/Y too).
            clc
            rts
