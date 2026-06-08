*-----------------------------------------------------------------------------
* machine_detect.s -- Apple II family identification per Misc Technote #7
*
* The decision tree (Cameron Birse / Matt Deatherage, revised by Jim Luther,
* Apple II Misc Technote #7, May 1991):
*
*   $FBB3 = $06 -> II series with extended ROM ( //e, //c, IIgs )
*     $FBC0 = $EA       -> //e unenhanced  (unsupported -- 6502, not 65C02)
*     $FBC0 = $00       -> //c   (check $FBBF for sub-rev)
*     $FBC0 = $E0       -> //e enhanced or IIgs   (need further test)
*        SEC : JSR $FE1F
*          BCC          -> IIgs (the routine clears carry on IIgs)
*          BCS          -> //e enhanced
*
*   $FBB3 = anything    -> II / II+ / etc.  (unsupported)
*
* NOTE: An earlier revision of this file had the $FBC0 values mixed up
* ($EA tagged as enhanced, $E0 tagged as //c-or-IIgs). That was wrong:
* per Tech Note #7, $EA is the *un*enhanced //e marker, and $E0 is the
* "enhanced family" marker shared by //e enhanced and IIgs. The //c
* family carries $FBC0=$00, not $E0. Some enhanced-IIe
* ROMs ($FBC0=$E0, $FBBF=$00) used to mis-classify as //c under the old
* table; that's resolved here.
*
* Supports //e enhanced, //c (any rev), //c+, IIgs; the 6502 build also
* accepts the unenhanced //e (the $EA branch below).
* Original-ROM //c ($FBBF=$FF) is detected and accepted but flagged elsewhere
* for the known 9600-baud serial-timing bug; a future build could drop to 300
* baud on those machines, per the ADTPro convention.
*-----------------------------------------------------------------------------

*-----------------------------------------------------------------------------
* detect_machine
*   On exit:  ZP_MACHINE_TYPE = MACH_* code
*             C = 0 if supported, C = 1 if unsupported
*-----------------------------------------------------------------------------
detect_machine
            lda   $FBB3
            cmp   #$06
            bne   :unsupported     ; II/II+ -- no extended ROM

            lda   $FBC0
            cmp   #$EA
* Unenhanced //e ($FBC0=$EA) carries an NMOS 6502, so it can only run the 6502
* build. The 65C02 build REJECTS it (its opcodes would crash there); the 6502
* build ACCEPTS it. This is the one machine-detect divergence between the two
* builds. (Some emulators present as an ENHANCED //e
* ($FBC0=$E0), so they take the shared $E0 path below regardless of build.)
            do    CPUC02
            beq   :unsupported     ; 65C02 build: unenhanced //e is a 6502 -> reject
            else
            beq   :is_iie_unenh    ; 6502 build: accept (this build runs on a 6502)
            fin
            cmp   #$00
            beq   :is_iic
            cmp   #$E0
            beq   :is_iie_enh_or_gs

* $FBB3=$06 but $FBC0 is something we don't recognize. Treat as unsupported.
            _BRA  :unsupported

:is_iie_enh_or_gs
* //e enhanced and IIgs both carry $FBC0=$E0. Disambiguate via the IIgs-
* only routine at $FE1F: per Technote #7, SEC : JSR $FE1F clears carry on
* IIgs and leaves it set on //e enhanced (the call is undefined there).
            sec
            jsr   $FE1F
            bcc   :is_iigs
            lda   #MACH_IIE_ENH
            sta   ZP_MACHINE_TYPE
            clc
            rts

:is_iic
* $FBBF tells us which //c revision:
*   $FF -> original ROM       (broken 9600 serial timing)
*   $00 -> ROM 0              (improved)
*   $03 -> ROM 3              (memory expansion)
*   $04 -> ROM 4 (//c+)       (per some refs; others say $05)
*   $05 -> ROM 5 (//c+)
* We collapse all of these into MACH_IIC except $04/$05 -> IIC_PLUS.
* (Original-ROM detection is left to the SSC code where the baud
* rate is actually chosen.)
            lda   $FBBF
            cmp   #$05
            beq   :is_iic_plus
            cmp   #$04
            beq   :is_iic_plus
            lda   #MACH_IIC
            sta   ZP_MACHINE_TYPE
            clc
            rts

:is_iic_plus
            lda   #MACH_IIC_PLUS
            sta   ZP_MACHINE_TYPE
            clc
            rts

:is_iigs
            lda   #MACH_IIGS
            sta   ZP_MACHINE_TYPE
            clc
            rts

* 6502 build only: accept the unenhanced //e. Emits ZERO bytes on the 65C02
* build (the do/else/fin keeps the 65C02 image byte-for-byte unchanged). We
* report it as its own code MACH_IIE ($05, "unenhanced //e") so status (m=5)
* tells the truth instead of borrowing MACH_IIE_ENH's m=1. We deliberately do
* NOT route it through the $FE1F IIgs probe (undefined on a real unenhanced
* //e); it is unambiguously a //e here.
            do    CPUC02
            else
:is_iie_unenh
            lda   #MACH_IIE
            sta   ZP_MACHINE_TYPE
            clc
            rts
            fin

:unsupported
            lda   #MACH_UNKNOWN
            sta   ZP_MACHINE_TYPE
            sec
            rts


*-----------------------------------------------------------------------------
* print_machine_name -- print the detected machine type, no trailing CR
*-----------------------------------------------------------------------------
print_machine_name
            lda   ZP_MACHINE_TYPE
            asl                     ; *2 for word table
            tax
            lda   name_table,x
            sta   ZP_PTR
            lda   name_table+1,x
            sta   ZP_PTR+1
            ldy   #0
:loop       lda   (ZP_PTR),y
            beq   :done
            jsr   COUT
            iny
            bne   :loop
:done       rts

name_table  da    name_unknown      ; MACH_UNKNOWN
            da    name_iie_enh      ; MACH_IIE_ENH
            da    name_iic          ; MACH_IIC
            da    name_iic_plus     ; MACH_IIC_PLUS
            da    name_iigs         ; MACH_IIGS
* MACH_IIE ($05) slot. 6502 build only: the 65C02 build never classifies a
* machine as MACH_IIE and never indexes this slot, so gating the entry AND its
* string keeps the 65C02 image byte-for-byte identical (zero added bytes).
            do    CPUC02
            else
            da    name_iie          ; MACH_IIE  (unenhanced //e)
            fin

* High-ASCII strings (bit 7 set so COUT prints normally, not inverse)
name_unknown   asc   "UNKNOWN",00
name_iie_enh   asc   "//E ENHANCED",00
name_iic       asc   "//C",00
name_iic_plus  asc   "//C+",00
name_iigs      asc   "IIGS",00
            do    CPUC02
            else
name_iie       asc   "//E (6502)",00
            fin
