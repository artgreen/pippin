*-----------------------------------------------------------------------------
* install-6502.s -- NMOS 6502 driver for PIPPIN.6502 (ProDOS BIN, $2000). Same
* installer/detect/SSC bodies as PIPPIN; CPUC02=0 compiles the 65C02
* opcodes out via cpu.macs, and machine_detect's $FBC0=$EA branch ACCEPTS the
* unenhanced //e (the 65C02 build rejects it). Embeds the 6502 MAIN_RES + LC
* images (MAINRES6502.BIN / LCROM6502.BIN). Built with -V so tools/check_6502.py
* can vet the installer's own code (xc is documentation-only in v1.2 beta 2). All
* PUTs/putbins live here (nested PUT/putbin is a no-op in v1.2b2). The 65C02 twin
* is install-65c02.s.
*-----------------------------------------------------------------------------
CPUC02      equ   0                        ; NMOS 6502 build
            org   $2000
            typ   $06                        ; ProDOS BIN
            dsk   PIPPIN.6502
            put   cpu.macs                   ; CPU macros + xc off (uses CPUC02)
            put   equates-common
            put   equates
            put   install_a
            put   machine_detect
            put   install_b

* MAIN_RES image data (6502 build) -- copy_mainres pulls it to $9000-$95FF.
mainres_image
            putbin MAINRES6502.BIN

* LC bank 2 image data (6502 build) -- copy_lcrom pulls it to $D000-$DFFF.
lcrom_image
            putbin LCROM6502.BIN
            end
