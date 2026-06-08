*-----------------------------------------------------------------------------
* recv-65c02.s -- 65C02 driver for the standalone serial receiver (RECV.BIN,
* $0801). Thin driver: selects the CPU (CPUC02=1 -> native 65C02 opcodes via
* cpu.macs) and the output filename, then PUTs the shared body. All PUTs live
* here because nested PUT is a no-op in Merlin32 v1.2 beta 2 (a PUT'd file's own
* PUT/putbin is silently dropped). The 6502 twin is recv-6502.s.
*-----------------------------------------------------------------------------
CPUC02      equ   1                        ; 65C02 build
            org   $0801                      ; clears $0800 (Applesoft program-start byte)
            typ   $06                       ; ProDOS BIN (loads at its aux addr)
            dsk   RECV.BIN
            put   cpu.macs                   ; CPU macros + xc directive (uses CPUC02)
            put   recv_body
            end
