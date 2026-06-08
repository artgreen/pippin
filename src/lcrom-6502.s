*-----------------------------------------------------------------------------
* lcrom-6502.s -- NMOS 6502 driver for the LC bank 2 image (LCROM6502.BIN).
* Same body as LCROM.BIN; CPUC02=0 makes cpu.macs compile every 65C02 opcode
* out and emit a legal-6502 equivalent instead. Always built with -V so
* tools/check_6502.py can vet the listing for stray 65C02 opcodes (the real
* gate -- xc is documentation-only in Merlin32 v1.2 beta 2). The 65C02 twin is
* lcrom-65c02.s. All PUTs live here (nested PUT is a no-op in v1.2b2).
*-----------------------------------------------------------------------------
CPUC02      equ   0                        ; NMOS 6502 build
            org   $D000
            typ   $06                       ; BIN (raw image)
            dsk   LCROM6502.BIN
            put   cpu.macs                   ; CPU macros + xc off (uses CPUC02)
            put   equates-common
            put   equates
            put   lcrom_body
            end
