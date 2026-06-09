*-----------------------------------------------------------------------------
* install_a.s -- first body fragment of PIPPIN: the one-shot installer
* (entry, banner, detect, copy, hook, alloc) up to alloc_interrupt. PUT by the
* install-*.s drivers between the equates and `put machine_detect`. Shared by
* both CPU builds; uses the cpu.macs macros. No PUT/putbin of its own (nested PUT
* is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*-----------------------------------------------------------------------------
* Entry point
*-----------------------------------------------------------------------------
start       cld
            sei                       ; mask IRQs for the whole install. init_ssc
*                                     ;  (step 3) enables the 6551 RX IRQ, but
*                                     ;  ssc_irq isn't registered until step 6
*                                     ;  (alloc_interrupt). A byte arriving in
*                                     ;  between would dispatch to nothing ->
*                                     ;  unclaimed IRQ -> RESTART SYSTEM-$01.
*                                     ;  Step 8's CLI opens the gate, once.
            ldx   #$FF
            txs

* Banner
            lda   #<banner_msg
            ldx   #>banner_msg
            jsr   print_msg

* Step 1: detect machine
            jsr   detect_machine
            bcs   fail_unsupp

            lda   #<machine_msg
            ldx   #>machine_msg
            jsr   print_msg
            jsr   print_machine_name
            jsr   CROUT

* Step 2: detect SSC
            jsr   detect_ssc
            bcs   fail_no_ssc

            lda   #<ssc_msg
            ldx   #>ssc_msg
            jsr   print_msg

* Step 3: init 6551
            jsr   init_ssc

* Step 4: copy MAIN_RES image to $9000
            jsr   copy_mainres

* Step 4b: copy LC bank 2 image to $D000
            jsr   copy_lcrom

* Step 5: install KSW hook (points at MAIN_RES's ksw_hook at $9000)
            jsr   install_hooks

* Step 6: register IRQ handler with ProDOS
            jsr   alloc_interrupt
            bcs   fail_alloc

* Step 7: mark MAIN_RES pages busy in system bit map
            lda   PRODOS_BITMAP
            ora   #MAINRES_BITMASK
            sta   PRODOS_BITMAP

* Step 8: open the gate
            cli

            lda   #<ready_msg
            ldx   #>ready_msg
            jsr   print_msg

* Step 9: comfort marker -- inverse '@' at top-right of text page 1.
* Signals "PIPPIN resident, IRQ dispatch live". ssc_irq re-asserts this
* on every frame dispatch so the marker self-heals if anything (e.g.,
* HOME, listing scroll) clears it. A future teardown path will clear it on
* exit.
            _STZ   $0427

* Step 10: chain to BASIC.SYSTEM if loaded
            lda   BASIC_ENTRY
            cmp   #$4C
            bne   no_basic
            jmp   BASIC_ENTRY

no_basic    lda   #<nobasic_msg
            ldx   #>nobasic_msg
            jsr   print_msg
spin        _BRA   spin

*---- failure paths ----
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


*-----------------------------------------------------------------------------
* print_msg -- print null-terminated high-ASCII string from A=lo, X=hi
*-----------------------------------------------------------------------------
print_msg
            sta   ZP_PTR
            stx   ZP_PTR+1
            ldy   #0
:loop       lda   (ZP_PTR),y
            beq   :done
            jsr   COUT
            iny
            bne   :loop
:done       rts


*-----------------------------------------------------------------------------
* copy_mainres -- copy MAINRES_PAGES (6) pages from mainres_image to $9000
*
* Uses ZP_PTR ($06-$07) as source pointer. Destination is page-walked via
* self-modified STA abs,Y with the high byte advanced each page.
*-----------------------------------------------------------------------------
copy_mainres
            lda   #<mainres_image
            sta   ZP_PTR
            lda   #>mainres_image
            sta   ZP_PTR+1
            lda   #>MAINRES_BASE     ; $90
            sta   :dst_sta+2         ; patch high byte of dest STA

            ldx   #MAINRES_PAGES
:copy_page  ldy   #0
:copy_byte  lda   (ZP_PTR),y
:dst_sta    sta   $9000,y            ; high byte gets patched per page
            iny
            bne   :copy_byte
            inc   ZP_PTR+1
            inc   :dst_sta+2
            dex
            bne   :copy_page
            rts


*-----------------------------------------------------------------------------
* copy_lcrom -- copy LC_PAGES (16) pages from lcrom_image to $D000
*
* Requires LC bank 2 to be write-enabled. Per the Apple II memory
* reference: $C083 must be READ TWICE consecutively to arm the write-
* enable latch (a single read selects bank 2 for read but leaves it
* write-protected). We then do the copy via self-modified STA, then
* return LC to ROM-read mode so the rest of install.s (which calls
* COUT in ROM) keeps working.
*
* Reads from main memory ($2000+ source) are unaffected by LC banking,
* so the LDA (ZP_PTR),Y works regardless of which bank is selected.
*-----------------------------------------------------------------------------
copy_lcrom
            lda   #<lcrom_image
            sta   ZP_PTR
            lda   #>lcrom_image
            sta   ZP_PTR+1
            lda   #>LC_BASE          ; $D0
            sta   :dst_sta+2         ; patch high byte of dest STA

* Arm write-enable for LC bank 2 (read $C083 twice).
            lda   LC_RW_BANK2
            lda   LC_RW_BANK2

            ldx   #LC_PAGES
:copy_page  ldy   #0
:copy_byte  lda   (ZP_PTR),y
:dst_sta    sta   $D000,y            ; high byte gets patched per page
            iny
            bne   :copy_byte
            inc   ZP_PTR+1
            inc   :dst_sta+2
            dex
            bne   :copy_page

* Restore LC to ROM-read / write-protect so COUT (in ROM at $FDED)
* keeps working for the rest of install. The trampoline at runtime
* will sample $C012 from the foreground and choose RAM or ROM
* restore on its own; we just need a sane default for install-time.
            lda   LC_RD_ROM
            rts


*-----------------------------------------------------------------------------
* install_hooks -- install both KSW hooks.
*
* The ROM-level $38/$39 KSW vector is hooked first (the previous vector --
* typically ROM's $FD1B KEYIN -- is stashed for a future teardown, but the
* hook polls and RTSes rather than chaining; see ksw_hook.s). This is
* sufficient for the bare-ProDOS path where there's no BASIC.SYSTEM
* intercepting input.
*
* If BASIC.SYSTEM is resident (BASIC_ENTRY = $4C), we MUST also hook
* its higher-level $BE32 input vector. Two reasons:
*   1. BASIC.SYSTEM's prompt GETLN calls its own internal keyboard
*      polling and never goes down to $38, so a $38-only hook would
*      never see prompt input. $BE32 is the only vector that catches it.
*   2. BASIC.SYSTEM's $BE00 entry (which we JMP to at end of install)
*      resets $38/$39 back to ROM KEYIN as part of its startup -- so
*      our $38 hook gets clobbered the instant we hand control over.
*      $BE32 survives that reset.
*
* Cost: when $BE32 is hooked, BASIC.SYSTEM detects the redirection and
* renders the prompt cursor as a solid block instead of the usual
* blinking checkerboard. This is a BASIC.SYSTEM convention for "stdin
* is being intercepted by an external routine" -- it's harmless and expected.
*
* State written:
*   saved_rom_lo/hi    ($9088/$9089)  -- chain target for $38 path
*   saved_basic_lo/hi  ($9081/$9082)  -- chain target for $BE32 path
*                                         (only valid if hooked_basic=1)
*   hooked_basic       ($9080)        -- 1 if $BE32 hooked, 0 if not
*-----------------------------------------------------------------------------
install_hooks
*---- Always: hook ROM-level $38/$39 ----
            lda   KSWL
            sta   SAVED_ROM_LO_ADDR
            lda   KSWH
            sta   SAVED_ROM_HI_ADDR

            php                       ; preserve IRQ-masked state (do NOT open
            sei                       ;  the gate here -- step 8 does that once)
            lda   #<ROM_KSW_HOOK_ADDR
            sta   KSWL
            lda   #>ROM_KSW_HOOK_ADDR
            sta   KSWH
            plp

*---- Conditionally: hook BASIC.SYSTEM $BE32/$BE33 ----
            lda   BASIC_ENTRY
            cmp   #$4C
            bne   :no_basic

            lda   BASIC_INPUT_VEC
            sta   SAVED_BASIC_LO_ADDR
            lda   BASIC_INPUT_VEC+1
            sta   SAVED_BASIC_HI_ADDR

            php                       ; preserve IRQ-masked state (step 8 opens)
            sei
            lda   #<KSW_HOOK_ADDR
            sta   BASIC_INPUT_VEC
            lda   #>KSW_HOOK_ADDR
            sta   BASIC_INPUT_VEC+1
            plp

            lda   #$01
            sta   HOOKED_BASIC_ADDR
            rts

:no_basic
            lda   #$00
            sta   HOOKED_BASIC_ADDR
            rts


*-----------------------------------------------------------------------------
* alloc_interrupt -- register MAIN_RES's ssc_irq with ProDOS via MLI $40
*
* MLI param block (mli_params) lives in MAIN_RES at MLI_PARAMS ($93F0).
* That block already has params=2, int_num=0, da ssc_irq baked into the
* image; ProDOS writes int_num into int_num slot on return.
*-----------------------------------------------------------------------------
alloc_interrupt
            jsr   PRODOS_MLI
            dfb   MLI_ALLOC_IRQ
            da    MLI_PARAMS
            bcs   :done              ; carry set => error in A
            clc
:done       rts


