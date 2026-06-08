*-----------------------------------------------------------------------------
* mainres-pip-6502.s -- NMOS 6502 driver for the fast/binary MAIN_RES image
* (MAINRES-PIP6502.BIN, $9000). Same bodies as MAINRES-PIP.BIN; CPUC02=0 compiles
* the 65C02 opcodes out via cpu.macs. Built with -V so tools/check_6502.py can vet
* the listing (xc is documentation-only in Merlin32 v1.2 beta 2). All PUTs live
* here (nested PUT is a no-op in v1.2b2). The 65C02 twin is mainres-pip-65c02.s.
*-----------------------------------------------------------------------------
CPUC02      equ   0                        ; NMOS 6502 build
            org   $9000
            typ   $06                       ; BIN image
            dsk   MAINRES-PIP6502.BIN
            put   cpu.macs                   ; CPU macros + xc off (uses CPUC02)
            put   equates-common
            put   equates-pip
            put   ksw_hook
            put   mainrespip_a
            put   ssc_common
            put   mainrespip_b
            end
