*-----------------------------------------------------------------------------
* mainres-6502.s -- NMOS 6502 driver for the JSON MAIN_RES image
* (MAINRES6502.BIN, $9000). Same bodies as MAINRES.BIN; CPUC02=0 makes cpu.macs
* compile every 65C02 opcode out and emit a legal-6502 equivalent. Built with -V
* so tools/check_6502.py can vet the listing (the real gate -- xc is
* documentation-only in Merlin32 v1.2 beta 2). The 65C02 twin is mainres-65c02.s.
* All PUTs live here (nested PUT is a no-op in v1.2b2).
*-----------------------------------------------------------------------------
CPUC02      equ   0                        ; NMOS 6502 build
            org   $9000
            typ   $06                       ; BIN -- embedded image data
            dsk   MAINRES6502.BIN
            put   cpu.macs                   ; CPU macros + xc off (uses CPUC02)
            put   equates-common
            put   equates
            put   ksw_hook
            put   mainres_a
            put   ssc_common
            put   mainres_b
            end
