# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Gigabit Ethernet MAC + PCS design, targeting ASIC/FPGA implementation. RGMII interface, AHB system bus attachment, IEEE 802.3-2008 compliant.

## Directory Layout

```
rtl/
  eth_mac/       # MAC core: TX/RX datapath, flow control, frame FIFO, CRC-32
  eth_pcs/       # PCS layer: 8b10b, auto-negotiation (optional)
  bus_if/        # AHB/AXI slave register interface + DMA descriptor engine
  std_cell/      # Foundry-portable wrappers (mul, div, clk_gate)
  top/           # Top-level integration
doc/             # Micro-architecture specs, register maps, clock/reset plans
sim/             # Testbenches, BFMs, test cases
```

## Clock Domains

| Domain | Frequency | Source | Feeds |
|--------|-----------|--------|-------|
| `gmii_tx_clk` | 125 MHz | PHY output | TX datapath, CRC generator |
| `gmii_rx_clk` | 125 MHz | PHY output | RX datapath, CRC checker |
| `core_clk` | System dependent | PLL | DMA, descriptor engine, bus interface |
| `mdio_clk` | ≤ 2.5 MHz | core_clk divided | MDIO controller |

**Rule**: All GMII↔core crossings go through async FIFOs. Never assume phase relationship between `gmii_tx_clk` and `gmii_rx_clk` — they are asynchronous even at same nominal frequency.

## Coding Conventions (Mandatory)

### Naming
- Module/instance: **UPPERCASE** — `ETH_MAC_TX U_ETH_MAC_TX (...)`
- Signals: **lowercase_snake_case** — `frame_length`, `tx_data_valid`
- Clocks must contain `clk`; resets must contain `rst`
- Active-low: suffix `_n` — `rst_n`, `arvalid_n`
- FSM state flops: `<name>_curr_st`, `<name>_next_st`
- Async signals: suffix `_a`; delayed flops: `_ff1`, `_ff2`

### Instantiation: Named-port, aligned columns
```verilog
eth_mac_tx #(
    .P_DATA_WIDTH   (8                  )
)
u_eth_mac_tx
(
    .gmii_tx_clk    (gmii_tx_clk        ),
    .rst_n          (rst_n              ),
    .tx_data        (tx_data            ),
    .tx_valid       (tx_valid           ),
    .tx_ready       (tx_ready           ),
    .gmii_txd       (gmii_txd           ),
    .gmii_tx_en     (gmii_tx_en         ),
    .gmii_tx_er     (gmii_tx_er         )
);
```
Empty `.port()` for unused outputs — never declare `_nc` signals.

### Standard Cell Wrappers (`rtl/std_cell/`)

**Never use raw `*` or `/` operators.** Always instantiate:

| Module | Use | Foundry macro guard |
|--------|-----|---------------------|
| `ETH_mul_pipe` | Unsigned multiply | `ETH_USE_FOUNDRY_DSP` |
| `ETH_mul_pipe_s` | Signed multiply | `ETH_USE_FOUNDRY_DSP` |
| `ETH_div_pipe` | Pipelined divider | `ETH_USE_FOUNDRY_DIV` |
| `ETH_clk_gate` | Clock gating | `ETH_USE_FOUNDRY_ICG` |

`P_LATENCY` defaults to 0 (combinational). For timing-critical paths, pipeline with `P_LATENCY ≥ 1`.

### SHELL_MODE

Every module MUST have `parameter P_SHELL_MODE = 0`. When `1`, outputs tie to safe values: `*ready=1'b1`, `*valid=1'b0`, data buses = `'0`, interrupts = `1'b0`. Use `+define+ETH_SHELL_MODE` for fast system-level simulation with incomplete submodules.

### FSM: Three-process, parameter-encoded states
```verilog
// Process 1: state register — sequential, <=
// Process 2: next-state logic — combinational, =
// Process 3: output logic — sequential, <=
```
Every `case` has `default`; every FSM has a safe reset state.

### Synthesizability
- No `initial`, `#delay`, `$display`/`$finish` in functional RTL
- Single clock per `always` block; no double-edge flops
- No internal clock/reset generation; no latches, no tristates
- Combinational `always @(*)` → blocking `=`; sequential → non-blocking `<=`
- Register all module output ports at IP boundaries

### Comments: English only
File headers, port descriptions, internal signal comments, logic block descriptions — all in English.

## Design-Specific Pitfalls

1. **CRC-32 latency**: IEEE 802.3 CRC takes 8 clocks minimum in a byte-serial implementation. Pipeline it or accept the gap — don't try to compute it in one cycle for full frames.

2. **Frame gap (IFG)**: Minimum 12-byte IFG between frames on TX. The MAC must enforce this; the DMA must provision for it in descriptor chains.

3. **Preamble/SFD**: RX must handle shortened preamble (SFEC mode). TX must always output full 7-byte preamble + 1-byte SFD.

4. **Jumbo frames**: If supported, frame FIFO must be sized for ≥ 9KB. Descriptor chains must handle fragmented jumbo frames across multiple descriptors.

5. **Pause frame response**: IEEE 802.3 Annex 31B. Pause quanta timer must be per-port, and the MAC must stop TX within 512 bit-times of a valid pause frame.

6. **GMII RX_ER/RX_DV combinations**: RX_ER=1 with RX_DV=1 signals a receive error (false carrier, bad SFD, etc.). The RX datapath must drop the current frame and increment error counters — don't present garbage to the DMA.

7. **Async FIFO depth**: Between GMII domains and core_clk, minimum FIFO depth is 4 entries (realistically 8+ for jumbo frames). Use Gray-code pointers; never use async FIFOs with depth not a power of 2.

## Available Skills

- **`/rtl-generator`** — Generate Verilog/SystemVerilog modules from structured JSON specs
- **`/rtl-reviewer`** — Systematic code review: synthesizability, CDC, FSM, timing, naming
- **`/cdc-review`** — Analyze cross-clock-domain paths, recommend synchronization strategies
- **`/drawio`** — Hardware block diagrams and architecture drawings (draw.io format)

## Design Flow

```
Micro-architecture doc → /rtl-generator (module by module, bottom-up)
                       → /rtl-reviewer   (each module after generation)
                       → /cdc-review     (after all clock domains are wired)
                       → simulation → synthesis → STA → ECO
```
