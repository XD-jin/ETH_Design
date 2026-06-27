---
name: eda-tools
description: EDA 工具调用 — 通过 Makefile 驱动 VCS 编译仿真、Verdi 波形、Lint/Vivado/DC
triggers:
  - 编译
  - 仿真
  - verdi
  - 跑仿真
  - make
  - vcs
  - lint
  - 综合
---

# EDA Tools — Makefile-Driven

所有 EDA 操作统一通过 `sim/Makefile` 执行。

## Makefile 入口

```bash
cd sim
```

| 命令 | 作用 |
|------|------|
| `make` | 生成 rtl.f + VCS 编译 |
| `make sim` | VCS 编译 + 运行仿真 → 生成 .fsdb 波形 |
| `make verdi` | 打开 Verdi 查看波形 |
| `make verdi_src` | 打开 Verdi 只看 RTL 源码 |
| `make clean` | 清除所有生成文件 |
| `make help` | 帮助 |

## Makefile 变量

```makefile
PROJ_ROOT = /home/chipmentor/project/GMAC  # 项目根目录
RTL_DIR   = $(PROJ_ROOT)/rtl                # RTL 源码
SIM_DIR   = $(PROJ_ROOT)/sim                # 仿真目录
TOP = tb_eth_mac_top                        # 仿真顶层
```

覆盖默认变量：
```bash
make sim TOP=my_new_tb                     # 指定其他 testbench
```

## 编译选项

Makefile 中 VCS 编译行：
```makefile
vcs -full64 -sverilog -debug_access+all \
    -timescale=1ns/10ps -lca -kdb +vcs+lic+wait \
    -f rtl.f -top $(TOP) -o simv
```

如需添加 `+define+MY_FLAG`：
```bash
make VCS_OPTS="+define+MY_FLAG" compile
```

## 波形

仿真生成 `tb_eth_mac_top.fsdb`，用 `make verdi` 打开。

Verdi 中快捷键：
- `f` — 添加信号到波形
- `Shift+w` — 保存波形配置 (.rc)
- `Ctrl+w` — 加载波形配置
- `z` / `Shift+z` — 放大/缩小

## 其他 EDA

### nLint
```bash
nlint -f sim/rtl.f -top eth_mac_top -out nlint_report
```

### Vivado
```tcl
read_verilog -sv [glob rtl/**/*.v]
synth_design -top eth_mac_top -part <xilinx_part>
report_utilization; report_timing_summary
```

### Design Compiler
```tcl
analyze -format sverilog [glob rtl/**/*.v]
elaborate eth_mac_top
source constraints.sdc
compile_ultra
report_area > area.rpt
```

# EDA Tools DEBUG
VCS和Verdi如果遇到没有license的情况，运行lm命令后重试

##
打开Verdi后，检查log文件./verdiLog/compiler.log, 如果有问题，修改后重新打开

##
运行VCS后也需要检查log文件，有问题修改，再重新跑
