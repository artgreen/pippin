*-----------------------------------------------------------------------------
* lcrom-65c02.s -- 65C02 driver for the LC bank 2 image (LCROM.BIN, $D000).
* Thin driver: selects the CPU (CPUC02=1 -> native 65C02 opcodes via cpu.macs)
* and the output filename, then PUTs the shared body. All PUTs live here because
* nested PUT is a no-op in Merlin32 v1.2 beta 2 (a PUT'd file's own PUT/putbin is
* silently dropped). The 6502 twin is lcrom-6502.s.
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $D000
            typ   $06                       ; BIN (raw image)
            dsk   LCROM.BIN
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   equates-common
            put   equates
            put   lcrom_body
            end
