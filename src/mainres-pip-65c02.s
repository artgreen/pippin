*-----------------------------------------------------------------------------
* mainres-pip-65c02.s -- 65C02 driver for the fast/binary MAIN_RES image
* (MAINRES-PIP.BIN, $9000). Thin driver: CPUC02=1 + output name, then PUTs the
* shared bodies in layout order (ksw_hook at $9000, then ssc_irq + handlers, then
* ssc_tx_byte, then MLI block + ring). All PUTs live here (nested PUT is a no-op
* in Merlin32 v1.2 beta 2). The 6502 twin is mainres-pip-6502.s.
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $9000
            typ   $06                       ; BIN image
            dsk   MAINRES-PIP.BIN
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   equates-common
            put   equates-pip
            put   ksw_hook                   ; $9000 KSW trampoline (shared body)
            put   mainrespip_a               ; ssc_irq + dispatch + handlers
            put   ssc_common                 ; ssc_tx_byte (shared body)
            put   mainrespip_b               ; MLI block + ring
            end
