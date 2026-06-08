*-----------------------------------------------------------------------------
* install-65c02.s -- 65C02 driver for PIPPIN (ProDOS BIN, $2000). Thin
* driver: CPUC02=1 + output name, then PUTs the installer body, machine_detect,
* the install-time SSC body, and putbins the 65C02 MAIN_RES + LC images. All PUTs
* and putbins live here because nested PUT/putbin is a no-op in Merlin32 v1.2 beta
* 2. The 6502 twin is install-6502.s. See the Makefile for the build order
* (MAINRES.BIN and LCROM.BIN must exist before this links).
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $2000                      ; BRUN load address
            typ   $06                        ; ProDOS BIN
            dsk   PIPPIN
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   equates-common
            put   equates
            put   install_a                  ; installer entry .. alloc_interrupt
            put   machine_detect             ; detect_machine + print_machine_name
            put   install_b                  ; detect_ssc/init_ssc + banners

* MAIN_RES image data -- embedded inline; copy_mainres pulls it to $9000-$95FF.
mainres_image
            putbin MAINRES.BIN

* LC bank 2 image data -- embedded inline; copy_lcrom pulls it to $D000-$DFFF.
lcrom_image
            putbin LCROM.BIN
            end
