*-----------------------------------------------------------------------------
* recv-6502.s -- NMOS 6502 driver for the standalone serial receiver
* (RECV.6502, $0801). Same body as RECV.BIN; CPUC02=0 makes cpu.macs compile
* every 65C02 opcode out and emit a legal-6502 equivalent instead (the 21 ops
* recv uses: 9 stz, 6 bra, 2 phy, 2 ply, 1 phx, 1 plx). Always built with -V so
* tools/check_6502.py can vet the listing for stray 65C02 opcodes (the real
* gate -- xc is documentation-only in Merlin32 v1.2 beta 2). This is the build
* for the unenhanced //e serial-bootstrap workflow. The 65C02 twin is
* recv-65c02.s. All PUTs live here (nested PUT is a no-op in v1.2b2).
*-----------------------------------------------------------------------------
CPUC02      equ   0                        ; NMOS 6502 build
            org   $0801                      ; clears $0800 (Applesoft program-start byte)
            typ   $06                       ; ProDOS BIN (loads at its aux addr)
            dsk   RECV.6502
            put   cpu.macs                   ; CPU macros + xc off (uses CPUC02)
            put   recv_body
            end
