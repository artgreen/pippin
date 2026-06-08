*-----------------------------------------------------------------------------
* mainres-65c02.s -- 65C02 driver for the JSON MAIN_RES image (MAINRES.BIN,
* $9000). Thin driver: CPUC02=1 (native 65C02 opcodes via cpu.macs) + output
* name, then PUTs the shared bodies in layout order. ksw_hook must land at $9000
* (PUT first), then ssc_irq + state (mainres_a), then ssc_tx_byte (ssc_common),
* then the $9100+ entries + ring (mainres_b). All PUTs live here because nested
* PUT is a no-op in Merlin32 v1.2 beta 2. The 6502 twin is mainres-6502.s.
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $9000
            typ   $06                       ; BIN -- embedded image data
            dsk   MAINRES.BIN
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   equates-common
            put   equates
            put   ksw_hook                   ; $9000 KSW trampoline (shared body)
            put   mainres_a                  ; ssc_irq + state block
            put   ssc_common                 ; ssc_tx_byte (shared body)
            put   mainres_b                  ; $9100 entries, MLI block, ring
            end
