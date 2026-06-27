# ============================================================================
# ETH_MAC Simulation Makefile — VCS + Verdi
# ============================================================================

PROJ_ROOT = /home/chipmentor/project/GMAC
RTL_DIR   = $(PROJ_ROOT)/rtl
SIM_DIR   = $(PROJ_ROOT)/sim

TOP = tb_eth_mac_top
TB  = tb_eth_mac_top

rtl.f:
	find $(RTL_DIR) -name "*.v" | sort > $@
	echo "$(TB).v" >> $@
	@echo "[GEN] $$(wc -l < $@) Verilog files -> rtl.f"

compile: rtl.f
	vcs -full64 -sverilog -debug_access+all \
	    -timescale=1ns/10ps -lca -kdb +vcs+lic+wait \
	    -f rtl.f -top $(TOP) -o simv

sim: compile
	./simv -l sim.log +vcs+lic+wait -ucli -do $(SIM_DIR)/run.tcl
	@echo "[SIM] Done. Waveform: $(TB).fsdb"

verdi:
	verdi -f rtl.f -ssf $(TB).fsdb -nologo &

verdi_src: rtl.f
	verdi -f rtl.f -top $(TOP) -nologo &

clean:
	rm -rf simv* csrc* DVEfiles ucli.key *.fsdb *.log *.dump *.vcd *.h inter* vc_hdrs.h novas* VerdiLog stack.info .vcs_lib_lock *~

help:
	@echo "make          = compile"
	@echo "make sim      = compile + run"
	@echo "make verdi    = open waveform"
	@echo "make clean    = remove generated files"

.PHONY: compile sim verdi verdi_src clean help
