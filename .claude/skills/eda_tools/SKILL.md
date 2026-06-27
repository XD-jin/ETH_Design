---
name: eda-tools
description: EDA 工具快速调用参考 — VCS 编译/仿真、Verdi 波形、Vivado 综合、dc_shell、Lint/nLint/SpyGlass
triggers:
  - VCS
  - Verdi
  - EDA
  - 仿真命令
  - 综合命令
  - lint
  - nLint
  - SpyGlass
  - Vivado
  - dc_shell
---

# EDA Tools Quick Reference

## VCS

```bash
# Compile only
vcs -full64 -sverilog -debug_access+all -timescale=1ns/10ps \
    -f rtl.f -top <tb_top> -o simv

# Compile + run
vcs ... -o simv && ./simv -l sim.log

# Run with waveform (via UCLI)
./simv -ucli -do run.tcl
```

| Flag | Purpose |
|------|---------|
| `-full64` | 64-bit |
| `-sverilog` | SystemVerilog |
| `-debug_access+all` | Full debug (FSDB dump, Verdi) |
| `-lca` | License for Verdi/KDB |
| `-kdb` | Knowledge Database for Verdi |
| `+vcs+lic+wait` | Wait for license if busy |
| `-f <file>` | File list |
| `-top <mod>` | Top module |
| `-o <name>` | Output executable |
| `+define+<MACRO>` | Define macro |

### run.tcl (UCLI)

```tcl
fsdbDumpfile tb_top.fsdb
fsdbDumpvars 0 tb_top
run
quit
```

## Verdi

```bash
# Open waveform
verdi -f rtl.f -ssf tb_top.fsdb -nologo &

# Open RTL source only (no waveform)
verdi -f rtl.f -top <dut_top> -nologo &

# Reload waveform in running Verdi
verdi -f rtl.f -ssf new.fsdb -nologo &
```

| Flag | Purpose |
|------|---------|
| `-f <file>` | File list |
| `-ssf <fsdb>` | Fast Signal Database (waveform) |
| `-top <mod>` | Top module for hierarchy |
| `-nologo` | Skip splash screen |

## Lint

### nLint

```bash
nlint -f rtl.f -top <top> -out nlint_report
```

### SpyGlass

```bash
spyglass -project sg.prj -goal lint/lint_rtl -batch
```

## Vivado

```bash
# Read RTL
read_verilog -sv [glob rtl/**/*.v]
# Synthesis
synth_design -top <top> -part <xilinx_part>
# Report
report_utilization
report_timing_summary
```

## Design Compiler

```tcl
# Read RTL
analyze -format sverilog [glob rtl/**/*.v]
elaborate <top>
# Constraints
source constraints.sdc
# Compile
compile_ultra
# Report
report_area > area.rpt
report_timing > timing.rpt
```
