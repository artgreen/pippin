*-----------------------------------------------------------------------------
* equates-pip.s -- PIP build specific memory map.
*
* PUT AFTER equates-common.s (shared HW/ZP/SSC/MLI/machine constants + the
* MAIN_RES anchors). The PIP handler is MAIN_RES-only -- no Language Card
* image, no parser scratch -- so all this build adds on top of the anchors is
* its own (compacted) state block. It omits the JSON path's SAVED_LC_READ +
* PARSE_ID_* bytes, so SAVED_ROM_LO/HI sit at STATE_BASE_ADDR+3/+4 here, vs
* +8/+9 in equates.s. (mainres-pip.s pins these via its own DS pads; install-
* pip.s writes them by absolute address -- keep all three in agreement.)
*-----------------------------------------------------------------------------
HOOKED_BASIC_ADDR   equ STATE_BASE_ADDR     ; 1 if $BE32 hooked, 0 if only $38 hooked
SAVED_BASIC_LO_ADDR equ STATE_BASE_ADDR+1   ; chain target for $BE32 hook (lo)
SAVED_BASIC_HI_ADDR equ STATE_BASE_ADDR+2   ; chain target for $BE32 hook (hi, adjacent)
SAVED_ROM_LO_ADDR   equ STATE_BASE_ADDR+3   ; chain target for $38 hook (lo)
SAVED_ROM_HI_ADDR   equ STATE_BASE_ADDR+4   ; chain target for $38 hook (hi, adjacent)
