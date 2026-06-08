# -----------------------------------------------------------------------------
# Makefile -- build PIPPIN for the 65C02 (default) and the NMOS 6502.
#
# PIPPIN assembles from ONE set of bodies via thin per-CPU drivers. Each
# driver sets CPUC02 (1=65C02, 0=6502)
# and the output filename, then PUTs cpu.macs + the shared bodies. cpu.macs is
# the single place the two CPU targets diverge: on the 6502 build it compiles
# every 65C02 opcode out and emits a legal-6502 equivalent. The 65C02 builds are
# byte-for-byte identical to the pre-split monolithic sources.
#
#   PIPPIN / PIPPIN.6502  JSON/MCP path. install embeds the MAIN_RES image
#                         ($9000) and the LC bank 2 image ($D000).
#   PIP    / PIP.6502     fast binary path. MAIN_RES-only (no LC image).
#
# Build order per family: assemble the MAIN_RES (+ LC) image(s), then link the
# installer driver which PUTBINs them. The .6502 installer embeds the .6502
# images and accepts the unenhanced //e in machine_detect.
#
# CORRECTNESS NOTE: `xc` is documentation-only in Merlin32 v1.2 beta 2 (it does
# NOT reject 65C02 opcodes), so `make scan` is the real gate for the 6502 path:
# it fails the build if any 6502 listing emitted a 65C02 opcode.
# -----------------------------------------------------------------------------

MERLIN32    = merlin32
MERLIN_LIB  = $(HOME)/merlin32/Library
PY          = uv run --with py65 python3

# Shared bodies + equates (PUT by the drivers; changing one rebuilds both CPUs).
CPU_MACS    = src/cpu.macs
EQUATES_COMMON = src/equates-common.s
EQUATES     = src/equates.s
EQUATES_PIP = src/equates-pip.s
MACHINE_DET = src/machine_detect.s
SSC_COMMON  = src/ssc_common.s
KSW_HOOK    = src/ksw_hook.s

# PIPPIN bodies
MAINRES_BODY = src/mainres_a.s src/mainres_b.s
LCROM_BODY   = src/lcrom_body.s
INSTALL_BODY = src/install_a.s src/install_b.s
# PIP bodies
MAINRES_PIP_BODY = src/mainrespip_a.s src/mainrespip_b.s
INSTALL_PIP_BODY = src/installpip_a.s src/installpip_b.s

# Common dependency bundles
COMMON_DEPS  = $(CPU_MACS) $(EQUATES_COMMON)
JSON_DEPS    = $(COMMON_DEPS) $(EQUATES)
PIP_DEPS     = $(COMMON_DEPS) $(EQUATES_PIP)
SHARED_RES   = $(SSC_COMMON) $(KSW_HOOK)

# Intermediates (65C02 / 6502)
MAINRES_BIN     = src/MAINRES.BIN
MAINRES6502_BIN = src/MAINRES6502.BIN
LCROM_BIN       = src/LCROM.BIN
LCROM6502_BIN   = src/LCROM6502.BIN
MAINRES_PIP_BIN     = src/MAINRES-PIP.BIN
MAINRES_PIP6502_BIN = src/MAINRES-PIP6502.BIN

# 65C02 final targets
TARGET      = PIPPIN
PIP_TARGET  = PIP
# 6502 final targets
TARGET6502  = PIPPIN.6502
PIP6502     = PIP.6502

# Listings the scan gate inspects (every 6502 unit, always built with -V)
SCAN_LISTINGS = src/LCROM6502.BIN_S01_Segment1_Output.txt \
                src/MAINRES6502.BIN_S01_Segment1_Output.txt \
                src/MAINRES-PIP6502.BIN_S01_Segment1_Output.txt \
                src/PIPPIN.6502_S01_Segment1_Output.txt \
                src/PIP.6502_S01_Segment1_Output.txt \
                src/RECV.6502_S01_Segment1_Output.txt

SHK_TARGET  = PIPPIN.SHK
# Standalone receiver: shared body + thin per-CPU drivers (same split as PIPPIN).
RECV_BODY   = src/recv_body.s
RECV_TARGET = RECV.BIN
RECV6502    = RECV.6502

.PHONY: all all6502 both pip pip6502 scan verbose shk recv recv6502 clean

all: $(TARGET)
pip: $(PIP_TARGET)
all6502: $(TARGET6502)
pip6502: $(PIP6502)
both: $(TARGET) $(PIP_TARGET) $(TARGET6502) $(PIP6502)

# =============================================================================
# 65C02 family (default)
# =============================================================================
$(MAINRES_BIN): src/mainres-65c02.s $(MAINRES_BODY) $(JSON_DEPS) $(SHARED_RES)
	cd src && $(MERLIN32) $(MERLIN_LIB) mainres-65c02.s
	@echo "Built MAINRES.BIN -- size: $$(wc -c < $(MAINRES_BIN)) bytes"

$(LCROM_BIN): src/lcrom-65c02.s $(LCROM_BODY) $(JSON_DEPS)
	cd src && $(MERLIN32) $(MERLIN_LIB) lcrom-65c02.s
	@echo "Built LCROM.BIN   -- size: $$(wc -c < $(LCROM_BIN)) bytes"

$(TARGET): src/install-65c02.s $(INSTALL_BODY) $(JSON_DEPS) $(MACHINE_DET) $(MAINRES_BIN) $(LCROM_BIN)
	cd src && $(MERLIN32) $(MERLIN_LIB) install-65c02.s
	mv src/PIPPIN ./PIPPIN
	mv src/_FileInformation.txt ./_FileInformation.txt
	@echo
	@echo "Built $(TARGET) -- size: $$(wc -c < $(TARGET)) bytes"

$(MAINRES_PIP_BIN): src/mainres-pip-65c02.s $(MAINRES_PIP_BODY) $(PIP_DEPS) $(SHARED_RES)
	cd src && $(MERLIN32) $(MERLIN_LIB) mainres-pip-65c02.s
	@echo "Built MAINRES-PIP.BIN -- size: $$(wc -c < $(MAINRES_PIP_BIN)) bytes"

$(PIP_TARGET): src/install-pip-65c02.s $(INSTALL_PIP_BODY) $(PIP_DEPS) $(MACHINE_DET) $(MAINRES_PIP_BIN)
	cd src && $(MERLIN32) $(MERLIN_LIB) install-pip-65c02.s
	mv src/PIP ./PIP
	mv src/_FileInformation.txt ./_FileInformation.txt
	@echo
	@echo "Built $(PIP_TARGET) -- size: $$(wc -c < $(PIP_TARGET)) bytes"

# =============================================================================
# NMOS 6502 family (always -V so `make scan` can vet the listings)
# =============================================================================
$(MAINRES6502_BIN): src/mainres-6502.s $(MAINRES_BODY) $(JSON_DEPS) $(SHARED_RES)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) mainres-6502.s
	@echo "Built MAINRES6502.BIN -- size: $$(wc -c < $(MAINRES6502_BIN)) bytes"

$(LCROM6502_BIN): src/lcrom-6502.s $(LCROM_BODY) $(JSON_DEPS)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) lcrom-6502.s
	@echo "Built LCROM6502.BIN   -- size: $$(wc -c < $(LCROM6502_BIN)) bytes"

$(TARGET6502): src/install-6502.s $(INSTALL_BODY) $(JSON_DEPS) $(MACHINE_DET) $(MAINRES6502_BIN) $(LCROM6502_BIN)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) install-6502.s
	mv src/PIPPIN.6502 ./PIPPIN.6502
	mv src/_FileInformation.txt ./_FileInformation.txt
	@echo
	@echo "Built $(TARGET6502) -- size: $$(wc -c < $(TARGET6502)) bytes"

$(MAINRES_PIP6502_BIN): src/mainres-pip-6502.s $(MAINRES_PIP_BODY) $(PIP_DEPS) $(SHARED_RES)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) mainres-pip-6502.s
	@echo "Built MAINRES-PIP6502.BIN -- size: $$(wc -c < $(MAINRES_PIP6502_BIN)) bytes"

$(PIP6502): src/install-pip-6502.s $(INSTALL_PIP_BODY) $(PIP_DEPS) $(MACHINE_DET) $(MAINRES_PIP6502_BIN)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) install-pip-6502.s
	mv src/PIP.6502 ./PIP.6502
	mv src/_FileInformation.txt ./_FileInformation.txt
	@echo
	@echo "Built $(PIP6502) -- size: $$(wc -c < $(PIP6502)) bytes"

# =============================================================================
# scan -- correctness gate: NO 6502 listing may contain a 65C02 opcode.
# (xc is a no-op in Merlin32 v1.2 beta 2, so this scan -- not the assembler --
# is what guarantees the 6502 path is really 6502.)
# =============================================================================
scan: $(TARGET6502) $(PIP6502) $(RECV6502)
	$(PY) tools/check_6502.py $(SCAN_LISTINGS)

# -----------------------------------------------------------------------------
# Verbose: emit listings and symbol tables for the 65C02 JSON build.
# -----------------------------------------------------------------------------
verbose: clean
	cd src && $(MERLIN32) -V $(MERLIN_LIB) mainres-65c02.s
	cd src && $(MERLIN32) -V $(MERLIN_LIB) lcrom-65c02.s
	cd src && $(MERLIN32) -V $(MERLIN_LIB) install-65c02.s
	mv src/PIPPIN ./PIPPIN
	mv src/_FileInformation.txt ./_FileInformation.txt
	mv src/PIPPIN_S01_Segment1_Output.txt ./PIPPIN_Output.txt
	mv src/PIPPIN_Symbols.txt ./PIPPIN_Symbols.txt
	mv src/MAINRES.BIN_S01_Segment1_Output.txt ./MAINRES.BIN_Output.txt
	mv src/MAINRES.BIN_Symbols.txt ./MAINRES.BIN_Symbols.txt
	mv src/LCROM.BIN_S01_Segment1_Output.txt ./LCROM.BIN_Output.txt
	mv src/LCROM.BIN_Symbols.txt ./LCROM.BIN_Symbols.txt
	@echo
	@echo "Built $(TARGET) -- size: $$(wc -c < $(TARGET)) bytes"
	@echo "Listings: PIPPIN_Output.txt, MAINRES.BIN_Output.txt, LCROM.BIN_Output.txt"
	@echo "Symbols:  PIPPIN_Symbols.txt, MAINRES.BIN_Symbols.txt, LCROM.BIN_Symbols.txt"

# -----------------------------------------------------------------------------
# shk -- wrap PIPPIN in a ShrinkIt archive (.SHK) that preserves the
# ProDOS file type ($06=BIN) and aux type ($2000=load addr).
# -----------------------------------------------------------------------------
shk: $(SHK_TARGET)

$(SHK_TARGET): $(TARGET)
	@which nulib2 >/dev/null || (echo "nulib2 not installed -- brew install nulib2" >&2; exit 1)
	@rm -f $(SHK_TARGET) 'PIPPIN#062000'
	@cp $(TARGET) 'PIPPIN#062000'
	nulib2 -aee $(SHK_TARGET) 'PIPPIN#062000'
	@rm -f 'PIPPIN#062000'
	@echo
	@echo "Built $(SHK_TARGET) -- size: $$(wc -c < $(SHK_TARGET)) bytes"
	@nulib2 -v $(SHK_TARGET) | tail -4

# -----------------------------------------------------------------------------
# recv / recv6502 -- build the standalone serial file receiver.
# Independent of the PIPPIN build. ORG $0801, BIN, aux $0801; receives into
# $2000. ($0801, not $0800, so it leaves the Applesoft program-start byte at
# $0800 alone.) Launch on the Apple with BRUN RECV.BIN (65C02) or BRUN RECV.6502
# (NMOS 6502, for the unenhanced //e serial-bootstrap workflow). Both assemble
# from src/recv_body.s via the thin per-CPU drivers. The 6502 build is
# always -V so `make scan` can vet its listing for stray 65C02 opcodes.
# -----------------------------------------------------------------------------
recv: $(RECV_TARGET)
recv6502: $(RECV6502)

$(RECV_TARGET): src/recv-65c02.s $(CPU_MACS) $(RECV_BODY)
	cd src && $(MERLIN32) $(MERLIN_LIB) recv-65c02.s
	mv src/RECV.BIN ./RECV.BIN
	@echo
	@echo "Built $(RECV_TARGET) -- size: $$(wc -c < $(RECV_TARGET)) bytes"
	@echo "Transfer it to the Apple as BIN, aux \$$0801; launch with BRUN RECV.BIN"

$(RECV6502): src/recv-6502.s $(CPU_MACS) $(RECV_BODY)
	cd src && $(MERLIN32) -V $(MERLIN_LIB) recv-6502.s
	mv src/RECV.6502 ./RECV.6502
	@echo
	@echo "Built $(RECV6502) -- size: $$(wc -c < $(RECV6502)) bytes"
	@echo "Transfer it to the Apple as BIN, aux \$$0801; launch with BRUN RECV.6502"

# clean clears build litter only. The four shipped binaries at the repo
# root are tracked (rebuild byte-identical with `make both`), so clean leaves
# them; it still removes the transient src/ copies, listings, and RECV*.
clean:
	rm -f $(SHK_TARGET) _FileInformation.txt
	rm -f PIPPIN_Output.txt PIPPIN_Symbols.txt
	rm -f MAINRES.BIN_Output.txt MAINRES.BIN_Symbols.txt
	rm -f LCROM.BIN_Output.txt LCROM.BIN_Symbols.txt
	rm -f src/PIPPIN src/PIP src/PIPPIN.6502 src/PIP.6502 src/_FileInformation.txt
	rm -f $(MAINRES_BIN) $(LCROM_BIN) $(MAINRES_PIP_BIN)
	rm -f $(MAINRES6502_BIN) $(LCROM6502_BIN) $(MAINRES_PIP6502_BIN)
	rm -f src/*_Output.txt src/*_Symbols.txt src/*_Error.txt src/error_output.txt
	rm -f 'PIPPIN#062000'
	rm -f $(RECV_TARGET) src/RECV.BIN $(RECV6502) src/RECV.6502
