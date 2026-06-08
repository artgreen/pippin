*-----------------------------------------------------------------------------
* install-pip-65c02.s -- 65C02 driver for PIP (ProDOS BIN, $2000). Thin
* driver: CPUC02=1 + output name, then PUTs the installer body, machine_detect,
* the install-time SSC body, and putbins the 65C02 fast MAIN_RES image. All PUTs
* and putbins live here (nested PUT/putbin is a no-op in Merlin32 v1.2 beta 2).
* The 6502 twin is install-pip-6502.s.
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $2000
            typ   $06                        ; ProDOS BIN
            dsk   PIP
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   equates-common
            put   equates-pip
            put   installpip_a               ; installer entry .. alloc_interrupt
            put   machine_detect
            put   installpip_b               ; detect_ssc/init_ssc + banners

* fast MAIN_RES image data -- copy_mainres pulls it to $9000-$95FF.
mainres_image
            putbin MAINRES-PIP.BIN
            end
