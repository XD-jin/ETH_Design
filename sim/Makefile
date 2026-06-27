# ============================================================================
# ETH_MAC Simulation Makefile — VCS + Verdi
# All tool output synced to sim.log via tee
# ============================================================================

PROJ_ROOT = /home/chipmentor/project/GMAC
RTL_DIR   = $(PROJ_ROOT)/rtl
SIM_DIR   = $(PROJ_ROOT)/sim

TOP = tb_eth_mac_top
TB  = tb_eth_mac_top
LOG = $(SIM_DIR)/sim.log

rtl.f:
	find $(RTL_DIR) -name "*.v" | sort > $@
	echo "$(TB).v" >> $@
	@echo "[GEN] $$(wc -l < $@) Verilog files -> rtl.f"

compile: rtl.f
	@echo "[VCS] Compiling $(TOP) ..." | tee $(LOG)
	vcs -full64 -sverilog -debug_access+all \
	    -timescale=1ns/10ps -lca -kdb +vcs+lic+wait \
	    -f rtl.f -top $(TOP) -o simv 2>&1 | tee -a $(LOG)

sim: compile
	@echo "[SIM] Running ..." | tee -a $(LOG)
	./simv +vcs+lic+wait -ucli -do $(SIM_DIR)/run.tcl 2>&1 | tee -a $(LOG)
	@echo "[SIM] Done. Waveform: $(TB).fsdb" | tee -a $(LOG)

verdi:
	@echo "[VERDI] Opening waveform ..." | tee -a $(LOG)
	verdi -f rtl.f -ssf $(TB).fsdb -nologo &

verdi_src: rtl.f
	verdi -f rtl.f -top $(TOP) -nologo &

verdi_log:
	@echo "=== Verdi compiler.log ==="
	@cat verdiLog/compiler.log 2>/dev/null || echo "(no compiler.log)"

clean:
	rm -rf simv* csrc* DVEfiles ucli.key *.fsdb *.log *.dump *.vcd *.h inter* vc_hdrs.h novas* VerdiLog stack.info .vcs_lib_lock *~ verdiLog
	@echo "[CLEAN] Done"

help:
	@echo "make          = compile           (log: sim.log)"
	@echo "make sim      = compile + run     (log: sim.log)"  
	@echo "make verdi    = open waveform"
	@echo "make verdi_log= show Verdi compiler.log"
	@echo "make clean    = remove generated files"

.PHONY: compile sim verdi verdi_src verdi_log clean help
