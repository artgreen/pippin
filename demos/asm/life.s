* life.s -- Conway's Game of Life in 65C02 assembly for the Apple II.
*
* Same result as demos/life_flip.bas (full-screen text Conway, page-flipped,
* dead edges, random soup) but in native code -- fast (~66 gen/s on a //c+).
* Logic verified in the 6502-codegen skill's simulator before any deploy.
*
* Build / transfer (see build_life.py):
*   - merlin32 life.s            -> raw binary at the ORG below, OR
*   - build_life.py assembles + simulator-verifies and emits:
*       life.bin  raw blob, sent over MCP with write_memory
*       life.mon  monitor listing "ADDR:BB BB ..." for EXEC-style install
*                 from the Apple monitor (CALL -151, paste, then 6000G / CALL 24576)
*
* Layout: code at $6000; two linear bordered board buffers (42x26, cells 0/1)
* at BUFA=$7000 and BUFB=$7800; display uses text pages 1 ($0400) and 2 ($0800)
* with hardware page flipping. The board interior is 40x24 = the whole screen
* (the buffer's 1-cell dead border lives off-screen). On screen a cell is a byte:
* $A0 (space) = dead, $A1 ('!') = alive -- one apart, so a column sum counts.
*
* ZP (avoids Applesoft and PIP's IRQ scratch $06/$07,$EB-$EF,$FA-$FF):
*   working pointers in $08/$09 and $19-$1F; persistent flags in $7B/$7C
*   (Applesoft's DATA pointers, dormant while we run in the foreground).
*
* Entry: JSR/CALL START ($6000 = CALL 24576). Runs until the host sets the STOP
* flag ($7C) or a key is pressed, then RTS to BASIC.

        ORG   $6000

GU      =   $19         ; GEN: src row r-1 ptr (also RENDER SCRP, SEED/CLR ptr)
GM      =   $1B         ; GEN: src row r   ptr (also RENDER BUFP)
GDN     =   $1D         ; GEN: src row r+1 ptr (also RENDER RPG byte at $1D)
GDST    =   $08         ; GEN: dst row r   ptr (also RENDER RBUF)
GROW    =   $1F         ; GEN row counter (also RENDER/DELAY counter)
RSCRP   =   $19
RBUFP   =   $1B
RBUF    =   $08
RPG     =   $1D
RROW    =   $1F
SP      =   $19
CP      =   $19
DTMP    =   $1F

BUFA    =   $7000
BUFB    =   $7800

* $7B-$80 are Applesoft's READ/DATA/INPUT pointers (DATLIN/DATPTR/INPTR). We run
* in the foreground via CALL, so the BASIC interpreter is suspended and nothing
* touches them; PIP's IRQ stays in its own ZP. So they're free zero page for our
* persistent flags (RUN/RESTORE resets BASIC's DATA state afterward).
FRAME   =   $7B          ; generation counter, bumped each gen (host polls it)
STOP    =   $7C          ; host sets this nonzero (write_memory) to stop the run
KBD     =   $C000
STROBE  =   $C010
SW_TXT  =   $C051
SW_MIX  =   $C052
SW_PG1  =   $C054
SW_PG2  =   $C055

START   STZ FRAME
        STZ STOP
        JSR CLRBUF
        JSR SEED
        STA SW_TXT
        STA SW_MIX
        STA SW_PG1
        LDA #<BUFA
        STA RBUF
        LDA #>BUFA
        STA RBUF+1
        LDA #0
        STA RPG
        JSR RENDER
        STA SW_PG1
MAIN    LDA #<BUFA
        STA GU
        LDA #>BUFA
        STA GU+1
        LDA #<(BUFA+42)
        STA GM
        LDA #>(BUFA+42)
        STA GM+1
        LDA #<(BUFA+84)
        STA GDN
        LDA #>(BUFA+84)
        STA GDN+1
        LDA #<(BUFB+42)
        STA GDST
        LDA #>(BUFB+42)
        STA GDST+1
        JSR GEN
        LDA #<BUFB
        STA RBUF
        LDA #>BUFB
        STA RBUF+1
        LDA #4
        STA RPG
        JSR RENDER
        STA SW_PG2
        INC FRAME
        JSR DELAY
        JSR CHKKEY
        BCS EXIT
        LDA #<BUFB
        STA GU
        LDA #>BUFB
        STA GU+1
        LDA #<(BUFB+42)
        STA GM
        LDA #>(BUFB+42)
        STA GM+1
        LDA #<(BUFB+84)
        STA GDN
        LDA #>(BUFB+84)
        STA GDN+1
        LDA #<(BUFA+42)
        STA GDST
        LDA #>(BUFA+42)
        STA GDST+1
        JSR GEN
        LDA #<BUFA
        STA RBUF
        LDA #>BUFA
        STA RBUF+1
        LDA #0
        STA RPG
        JSR RENDER
        STA SW_PG1
        INC FRAME
        JSR DELAY
        JSR CHKKEY
        BCS EXIT
        JMP MAIN
EXIT    STA SW_PG1
        RTS

* --- one generation: src rows via GU/GM/GDN, dst row via GDST (all preset) ---
GEN     LDA #24
        STA GROW
GENROW  LDY #1
GENCOL  DEY
        LDA (GU),Y
        CLC
        ADC (GM),Y
        ADC (GDN),Y
        INY
        ADC (GU),Y
        ADC (GDN),Y
        INY
        ADC (GU),Y
        ADC (GM),Y
        ADC (GDN),Y
        DEY
        CMP #3
        BEQ :al
        CMP #2
        BNE :de
        LDA (GM),Y
        BNE :al
:de     LDA #0
        BRA :st
:al     LDA #1
:st     STA (GDST),Y
        INY
        CPY #41
        BNE GENCOL
        LDA GU
        CLC
        ADC #42
        STA GU
        BCC :a1
        INC GU+1
:a1     LDA GM
        CLC
        ADC #42
        STA GM
        BCC :a2
        INC GM+1
:a2     LDA GDN
        CLC
        ADC #42
        STA GDN
        BCC :a3
        INC GDN+1
:a3     LDA GDST
        CLC
        ADC #42
        STA GDST
        BCC :a4
        INC GDST+1
:a4     DEC GROW
        BNE GENROW
        RTS

* --- render buffer (RBUF) interior to a screen page (RPG = hi offset 0 or 4) ---
RENDER  LDA RBUF
        CLC
        ADC #43
        STA RBUFP
        LDA RBUF+1
        ADC #0
        STA RBUFP+1
        LDX #0
        LDA #24
        STA RROW
RENROW  LDA SCRTAB,X
        STA RSCRP
        LDA SCRTAB+1,X
        CLC
        ADC RPG
        STA RSCRP+1
        LDY #0
RENCOL  LDA (RBUFP),Y
        CLC
        ADC #$A0
        STA (RSCRP),Y
        INY
        CPY #40
        BNE RENCOL
        LDA RBUFP
        CLC
        ADC #42
        STA RBUFP
        BCC :r1
        INC RBUFP+1
:r1     INX
        INX
        DEC RROW
        BNE RENROW
        RTS

* --- seed BUFA interior (~30% alive) using the LFSR ---
SEED    LDA #<(BUFA+43)
        STA SP
        LDA #>(BUFA+43)
        STA SP+1
        LDX #24
SEEDROW LDY #0
SEEDCOL JSR RAND
        CMP #77
        LDA #1
        BCC :sd
        LDA #0
:sd     STA (SP),Y
        INY
        CPY #40
        BNE SEEDCOL
        LDA SP
        CLC
        ADC #42
        STA SP
        BCC :s1
        INC SP+1
:s1     DEX
        BNE SEEDROW
        RTS

* --- 16-bit Galois LFSR (taps $B400); returns A = pseudo-random byte ---
RAND    LSR LFSR+1
        ROR LFSR
        BCC :nx
        LDA LFSR+1
        EOR #$B4
        STA LFSR+1
:nx     LDA LFSR
        RTS

* --- clear both board buffers ($7000-$7FFF) to 0 ---
CLRBUF  LDA #$00
        STA CP
        LDX #$70
        STX CP+1
        LDX #16
        LDY #0
:cb     STA (CP),Y
        INY
        BNE :cb
        INC CP+1
        DEX
        BNE :cb
        RTS

* --- crude tunable delay: DLYCT * 65536 inner steps ---
DELAY   LDA DLYCT
        STA DTMP
:d1     LDX #0
:d2     LDY #0
:d3     DEY
        BNE :d3
        DEX
        BNE :d2
        DEC DTMP
        BNE :d1
        RTS

* --- carry set if a key is waiting (and clears the strobe) ---
CHKKEY  LDA STOP
        BNE :yes
        LDA KBD
        BPL :nk
        STA STROBE
:yes    SEC
        RTS
:nk     CLC
        RTS

LFSR    DFB $2C,$1D
DLYCT   DFB $04
SCRTAB  DA  $0400,$0480,$0500,$0580,$0600,$0680,$0700,$0780
        DA  $0428,$04A8,$0528,$05A8,$0628,$06A8,$0728,$07A8
        DA  $0450,$04D0,$0550,$05D0,$0650,$06D0,$0750,$07D0
