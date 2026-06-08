*-----------------------------------------------------------------------------
* installpip_a.s -- first body fragment of PIP: the one-shot installer
* (no Language Card steps -- copies only the MAIN_RES image). PUT by the
* install-pip-*.s drivers between the equates and `put machine_detect`. Shared by
* both CPU builds; uses the cpu.macs macros. No PUT/putbin of its own (nested PUT
* is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
start       cld
            sei                       ; mask IRQs through install; step 8 CLIs
            ldx   #$FF
            txs

            lda   #<banner_msg
            ldx   #>banner_msg
            jsr   print_msg

            jsr   detect_machine
            bcs   fail_unsupp
            lda   #<machine_msg
            ldx   #>machine_msg
            jsr   print_msg
            jsr   print_machine_name
            jsr   CROUT

            jsr   detect_ssc
            bcs   fail_no_ssc
            lda   #<ssc_msg
            ldx   #>ssc_msg
            jsr   print_msg

            jsr   init_ssc
            jsr   copy_mainres        ; 6 pages -> $9000  (NO copy_lcrom)
            jsr   install_hooks
            jsr   alloc_interrupt
            bcs   fail_alloc

            lda   PRODOS_BITMAP
            ora   #MAINRES_BITMASK
            sta   PRODOS_BITMAP

            cli
            lda   #<ready_msg
            ldx   #>ready_msg
            jsr   print_msg
            _STZ   $0427               ; comfort marker

            lda   BASIC_ENTRY
            cmp   #$4C
            bne   no_basic
            jmp   BASIC_ENTRY
no_basic    lda   #<nobasic_msg
            ldx   #>nobasic_msg
            jsr   print_msg
spin        _BRA   spin

fail_unsupp lda   #<unsupp_msg
            ldx   #>unsupp_msg
            jsr   print_msg
            _BRA   halt
fail_no_ssc lda   #<nossc_msg
            ldx   #>nossc_msg
            jsr   print_msg
            _BRA   halt
fail_alloc  pha
            lda   #<alloc_msg
            ldx   #>alloc_msg
            jsr   print_msg
            pla
            jsr   PRBYTE
            jsr   CROUT
halt        brk

print_msg   sta   ZP_PTR
            stx   ZP_PTR+1
            ldy   #0
:loop       lda   (ZP_PTR),y
            beq   :done
            jsr   COUT
            iny
            bne   :loop
:done       rts

copy_mainres
            lda   #<mainres_image
            sta   ZP_PTR
            lda   #>mainres_image
            sta   ZP_PTR+1
            lda   #>MAINRES_BASE
            sta   :dst_sta+2
            ldx   #MAINRES_PAGES
:copy_page  ldy   #0
:copy_byte  lda   (ZP_PTR),y
:dst_sta    sta   $9000,y
            iny
            bne   :copy_byte
            inc   ZP_PTR+1
            inc   :dst_sta+2
            dex
            bne   :copy_page
            rts

install_hooks
            lda   KSWL
            sta   SAVED_ROM_LO_ADDR
            lda   KSWH
            sta   SAVED_ROM_HI_ADDR
            php
            sei
            lda   #<ROM_KSW_HOOK_ADDR
            sta   KSWL
            lda   #>ROM_KSW_HOOK_ADDR
            sta   KSWH
            plp
            _STZ   HOOKED_BASIC_ADDR   ; default: BASIC.SYSTEM not hooked
            lda   BASIC_ENTRY
            cmp   #$4C
            bne   :done
            lda   BASIC_INPUT_VEC
            sta   SAVED_BASIC_LO_ADDR
            lda   BASIC_INPUT_VEC+1
            sta   SAVED_BASIC_HI_ADDR
            php
            sei
            lda   #<KSW_HOOK_ADDR
            sta   BASIC_INPUT_VEC
            lda   #>KSW_HOOK_ADDR
            sta   BASIC_INPUT_VEC+1
            plp
            lda   #$01
            sta   HOOKED_BASIC_ADDR   ; BASIC present -> flag the hook
:done       rts

alloc_interrupt
            jsr   PRODOS_MLI
            dfb   MLI_ALLOC_IRQ
            da    MLI_PARAMS
            rts                       ; MLI returns carry=error; pass it through
