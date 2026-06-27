---
name: testbench-gen
description: 通用 Verilog testbench 生成器。分析 DUT 端口自动识别接口协议，生成时钟复位、BFM、激励、scoreboard、波形 dump。
triggers:
  - 生成testbench
  - 生成tb
  - 仿真环境
  - testbench生成
  - 写testbench
  - BFM
  - generate testbench
  - 验证环境
---

# Testbench Generator — 通用验证环境生成器

分析任意 DUT 模块，自动生成完整的 Verilog testbench。

## 输入

- DUT 模块文件（.v / .sv）
- 接口协议类型（可选；未指定时从端口名自动推断）
- 测试场景描述（可选）
- 时钟频率配置（可选；默认从 `timescale` 推断）

## 输出

- `tb_<dut_name>.v` — 顶层 testbench
- BFM 模块（按需生成）— AHB/APB/AXI Master, 通用 Slave Memory, Handshake Driver/Monitor

## 自动识别规则

根据 DUT 端口名称模式推断接口协议：

| 端口模式 | 推断协议 | BFM 策略 |
|---------|---------|---------|
| `hsel`, `haddr`, `hwrite`, `htrans`, `hrdata`, `hready`, `hresp` | AMBA AHB | AHB Master BFM + Slave Memory |
| `psel`, `penable`, `paddr`, `pwrite`, `pwdata`, `prdata`, `pready` | AMBA APB | APB Master BFM |
| `awvalid`, `awaddr`, `wdata`, `bready`, `arvalid`, `rdata` | AXI4/AXI-Lite | AXI Master BFM |
| `rgmii_txc`, `rgmii_txd`, `rgmii_rxc`, `rgmii_rxd`, `rgmii_*_ctl` | RGMII | RGMII PHY BFM (DDR ↔ SDR) |
| `gmii_txd`, `gmii_tx_en`, `gmii_rxd`, `gmii_rx_dv` | GMII/MII | GMII PHY BFM (8-bit SDR) |
| `valid` + `ready`（成对出现在输入或输出方向） | Valid/Ready Handshake | Handshake Driver (master) / Monitor (slave) |
| 含 `clk` 的 input 1-bit | Clock | 时钟生成 |
| 含 `rst` 的 input 1-bit | Reset | 复位序列 |

## 流程

### Step 1: 分析 DUT

```verilog
// 读取 DUT module 声明，提取：
module dut_name #(
    parameter P1 = <default>,   // → 参数列表（名/默认值）
    ...
) (
    input  wire        clk,      // → 时钟（含 "clk"）
    input  wire        rst_n,    // → 复位（含 "rst"）
    input  wire        valid_i,  // → handshake master port
    output wire        ready_o,  // → handshake slave port
    ...
);
```

输出分析结果：

```json
{
  "name": "dut_name",
  "parameters": [
    {"name": "P_DATA_WIDTH", "default": 32}
  ],
  "clocks": ["hclk", "gmii_tx_clk"],
  "resets": ["hresetn", "rst_n"],
  "interfaces": [
    {"type": "AHB_Slave", "prefix": "", "signals": ["hsel","haddr",...]},
    {"type": "AHB_Master", "prefix": "hm_", "signals": ["hm_addr_o",...]},
    {"type": "RGMII", "prefix": "rgmii_", "signals": ["rgmii_rxc",...]},
    {"type": "Handshake_Source", "prefix": "tx_", "signals": ["tx_valid","tx_data","tx_ready"]}
  ],
  "generic_ports": [
    {"name": "intr_o", "dir": "output", "width": 1, "type": "interrupt"}
  ]
}
```

### Step 2: 生成时钟与复位

为每个检测到的时钟域生成独立的 clock generator：

```verilog
// Clock generation — one per detected clock domain
reg <clk_name>;
initial <clk_name> = 0;
initial forever #<half_period> <clk_name> = ~<clk_name>;

// 默认频率推断:
//   hclk / pclk / sys_clk → 100MHz (period 10ns, half 5ns)
//   gmii_tx_clk / gtx_clk → 125MHz (period 8ns, half 4ns)
//   gmii_rx_clk / rx_clk → 125MHz (period 8ns, half 4ns)
//   其他 → 100MHz default
```

复位序列（适配检测到的复位名）：

```verilog
// Reset sequence
reg <rst_name>;
initial begin
    <rst_name> = 0;                         // assert
    repeat(20) @(posedge <fastest_clk>);    // hold ≥10 target cycles
    <rst_name> = 1;                         // de-assert synchronously
end
```

### Step 3: 生成 BFM

按识别出的接口类型生成对应的 BFM task。

#### AHB Master BFM

```verilog
reg        <ahb_hsel>;
reg [A:0]  <ahb_haddr>;
reg        <ahb_hwrite>;
reg [31:0] <ahb_hwdata>;
reg [ 1:0] <ahb_htrans>;

// Write task
task <prefix>_write;
    input [A:0] addr;
    input [31:0] data;
begin
    @(posedge <hclk>);
    <ahb_hsel> = 1; <ahb_haddr> = addr; <ahb_hwrite> = 1;
    <ahb_hwdata> = data; <ahb_htrans> = 2'b10;
    @(posedge <hclk>);
    while (!<ahb_hready>) @(posedge <hclk>);
    <ahb_hsel> = 0; <ahb_htrans> = 2'b00;
end
endtask

// Read task
task <prefix>_read;
    input  [A:0] addr;
    output [31:0] data;
begin
    @(posedge <hclk>);
    <ahb_hsel> = 1; <ahb_haddr> = addr; <ahb_hwrite> = 0; <ahb_htrans> = 2'b10;
    @(posedge <hclk>);
    while (!<ahb_hready>) @(posedge <hclk>);
    data = <ahb_hrdata>;
    <ahb_hsel> = 0; <ahb_htrans> = 2'b00;
end
endtask
```

#### AHB Slave Memory BFM（用于 DMA 目标）

```verilog
reg [31:0] mem [0:65535];   // 256KB simulated memory

always @(posedge <hclk>) begin
    if (<hm_hsel> && <hm_htrans>[1]) begin
        if (<hm_hwrite>)
            mem[<hm_haddr>[17:2]] <= <hm_hwdata>;
        else
            <hm_hrdata> <= mem[<hm_haddr>[17:2]];
        <hm_hready> <= 1; <hm_hresp> <= 0;
    end else begin
        <hm_hready> <= 1; <hm_hresp> <= 0;
    end
end
```

#### APB Master BFM

```verilog
task <prefix>_write;
    input [A:0] addr; input [31:0] data;
begin
    @(posedge <pclk>);
    <psel> = 1; <paddr> = addr; <pwrite> = 1; <pwdata> = data;
    @(posedge <pclk>); <penable> = 1;
    @(posedge <pclk>);
    while (!<pready>) @(posedge <pclk>);
    <psel> = 0; <penable> = 0;
end
endtask
```

#### Valid/Ready Handshake Driver（Master 侧）

```verilog
task <prefix>_send;
    input [W-1:0] data;
    input         is_last;    // optional end-of-packet flag
begin
    <valid> = 1; <data> = data; <last> = is_last;
    do @(posedge <clk>); while (!<ready>);
    <valid> = 0;
end
endtask
```

#### Valid/Ready Handshake Monitor（Slave 侧，被动接收）

```verilog
always @(posedge <clk>) begin
    if (<valid> && <ready>) begin
        rx_data[byte_cnt] <= <data>;
        byte_cnt <= (byte_cnt == <max_len>-1) ? 0 : byte_cnt + 1;
    end
end
```

### Step 4: 生成 Scoreboard

```verilog
// Auto-generated scoreboard: compare output with expected
integer pass_cnt, fail_cnt;

task check_equal;
    input [1023:0] name;   // check description
    input [W-1:0]  actual, expected;
begin
    if (actual === expected) begin
        $display("[PASS] %0s: 0x%0h", name, actual);
        pass_cnt++;
    end else begin
        $display("[FAIL] %0s: got 0x%0h, expected 0x%0h", name, actual, expected);
        fail_cnt++;
    end
end
endtask
```

### Step 5: 生成 Waveform Dump

```verilog
// FSDB for Verdi (VCS)
initial begin
    $fsdbDumpfile("tb_<dut_name>.fsdb");
    $fsdbDumpvars(0, tb_<dut_name>);
end

// VCD for open-source simulators (Icarus, Verilator)
// initial begin
//     $dumpfile("tb_<dut_name>.vcd");
//     $dumpvars(0, tb_<dut_name>);
// end
```

### Step 6: 组装

将所有生成的 block 组合：

```verilog
module tb_<dut_name>;

    // === Parameters ===
    localparam CLK_PERIOD = <period>;   // from auto-detect

    // === Clock & Reset ===
    // ... generated in Step 2 ...

    // === DUT Instance ===
    <dut_name> #(
        .<P1>(<default>), ...
    ) u_dut (
        .<port1>(<wire1>), ...
    );

    // === Master BFM instances ===
    // ... generated in Step 3 ...

    // === Slave BFM / Memory instances ===
    // ... generated in Step 3 ...

    // === Monitor / Scoreboard ===
    // ... generated in Step 4 ...

    // === Waveform Dump ===
    // ... generated in Step 5 ...

    // === Test Sequence ===
    initial begin
        $display("[TB] Starting testbench for <dut_name>");
        wait(<rst_name>); repeat(10) @(posedge <fastest_clk>);
        $display("[TB] Reset released");

        // --- User test sequence starts here ---
        // Fill with auto-generated basic test or user-provided scenario
        // ---

        $display("[TB] PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("[TB] ALL TESTS PASSED");
        else               $display("[TB] %0d TESTS FAILED", fail_cnt);
        $finish;
    end

endmodule
```

---

## 测试场景

### 场景 1: 寄存器读写测试（自动生成）

```
适用: 检测到 AHB/APB Slave 接口时自动生成
步骤: 写 → 读 → 比对 → 报告
覆盖: CSR 地址译码、读写通路
```

### 场景 2: 数据通路测试（需用户指定激励数据）

```
适用: 检测到流式数据接口（Valid/Ready Handshake, AXI Stream）
步骤: 用户提供输入数据向量 → Driver 发送 → Monitor 采集 → Scoreboard 比对
覆盖: 数据通路功能、背压行为
```

### 场景 3: 中断测试（检测到 intr 端口时）

```
适用: 检测到 interrupt 类型输出端口
步骤: 触发中断条件 → 等待 intr 断言 → 软件清除 → 确认 de-assert
覆盖: 中断产生/清除逻辑
```

---

## 使用示例

### 最小输入

```
/testbench_gen  DUT=rtl/my_module.v
```

### 指定协议

```
/testbench_gen  DUT=rtl/my_module.v  协议=AHB
```

### 指定时钟频率

```
/testbench_gen  DUT=rtl/my_module.v  clk=200MHz  rst=async_low
```

### 带测试场景

```
/testbench_gen  DUT=rtl/my_module.v  场景=CSR读写+数据通路
```

---

## 注意事项

1. **参数化 DUT**: DUT 的所有 `parameter` 在 tb 中用默认值例化，可通过 `defparam` 或 `#()` 覆盖
2. **多时钟域**: 每个独立时钟域生成各自的 `forever` block；跨域接口在 BFM task 中标注 `@(posedge <clk>)` 边界
3. **复位策略**: 自动检测 `rst_n`（低有效）vs `rst`（高有效）；检测不到时默认低有效
4. **BFM 复用**: 同类型的多个接口共用同一套 BFM task，通过前缀区分信号名
5. **可综合性除外**: 生成的 testbench 仅供仿真——允许 `initial`, `forever`, `$display`, `$finish`
