*-----------------------------------------------------------------------------
* install_b.s -- second body fragment of PIPPIN: install-time SSC
* detect/init and the banner strings. PUT by the install-*.s drivers after
* `put machine_detect` and before the mainres_image/lcrom_image putbins. Shared
* by both CPU builds. No PUT/putbin of its own (nested PUT is a no-op in v1.2b2).
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* detect_ssc / init_ssc -- install-time-only SSC routines
*-----------------------------------------------------------------------------
detect_ssc
            lda   SSC_FW_ID1
            cmp   #$38
            bne   :not_found
            lda   SSC_FW_ID2
            cmp   #$18
            bne   :not_found
            lda   SSC_FW_ID3
            cmp   #$01
            bne   :not_found
            lda   SSC_FW_ID4
            cmp   #$31
            bne   :not_found
            clc
            rts
:not_found  sec
            rts

init_ssc
            sta   SSC_STATUS         ; reset 6551 (write resets it)
            lda   #$1E               ; 9600 8N1, internal clock
            sta   SSC_CONTROL
            lda   #$09               ; DTR on, RX IRQ enabled, TX IRQ off, no parity
            sta   SSC_COMMAND
            _STZ   ZP_RX_WR
            _STZ   ZP_RX_RD
            _STZ   ZP_PENDING_WORK
            _STZ   ZP_PENDING_KEY
            rts


*-----------------------------------------------------------------------------
* Banner messages (high-ASCII, COUT-printable, null-terminated)
*-----------------------------------------------------------------------------
banner_msg  asc   8D
            asc   "*** PIPPIN - MCP SERVER V0.6 ***",8D,00

machine_msg asc   "MACHINE: ",00

ssc_msg     asc   "SSC DETECTED IN SLOT 2",8D,00

ready_msg   asc   "HOOKS INSTALLED. IRQS ENABLED.",8D
            asc   "PIPPIN RESIDENT AT 9000-95FF.",8D,00

unsupp_msg  asc   "UNSUPPORTED MACHINE.",8D,00

nossc_msg   asc   "NO SSC IN SLOT 2.",8D,00

alloc_msg   asc   "ALLOC/IRQ FAILED: ",00

nobasic_msg asc   "BASIC.SYSTEM NOT RESIDENT.",8D,00

