---
name: testbench-gen
description: 根据 DUT 模块和接口协议生成 Verilog testbench，包含时钟复位、AHB/RGMII BFM、包生成器、scoreboard、FSDB dumping
triggers:
  - 生成testbench
  - 生成tb
  - 仿真环境
  - testbench生成
  - 写testbench
  - BFM
  - 验证环境
  - generate testbench
---

# Testbench Generator — 验证环境生成器

根据 DUT 模块自动生成完整的 Verilog testbench 验证环境。

## 输入

- DUT 模块文件（.v）
- 接口协议类型（AHB / RGMII / AXI / 自定义）
- 测试场景描述（可选）
- 配置参数（时钟频率、复位策略等）

## 输出

- `tb_<dut_name>.v` — 顶层 testbench
- 辅助 BFM 模块（A）`ahb_master_bfm.v`（AHB 主端 BFM）、（B）`rgmii_phy_bfm.v`（RGMII PHY BFM）
- `eth_pkt_gen.v` — 以太网包生成器/检查器

## Testbench 结构

```
tb_eth_mac_top
├── Clock/Reset Generator     (hclk, gmii_tx_clk, rgmii_rxc)
├── DUT: eth_mac_top           (例化)
├── AHB Master BFM             (CSR 读写 + DMA 数据搬运)
│   ├── Register read/write tasks
│   └── DMA descriptor push + data burst
├── RGMII PHY BFM              (模拟外部 PHY 行为)
│   ├── RX: 注入 GMII 帧到 DUT
│   └── TX: 捕获 DUT 发出的 GMII 帧
├── Packet Generator/Checker   (帧构造 + CRC 计算)
└── Scoreboard                 (比对 TX/RX 帧)
```

## 流程

### Step 1: 分析 DUT

1. 读取 DUT 的 `module` 声明，提取端口列表
2. 识别接口类型：端口名含 `hsel`/`haddr` → AHB；含 `rgmii` → RGMII
3. 确定时钟域数量和复位策略
4. 列出所有 parameter 及其默认值

### Step 2: 生成 Clock/Reset Generator

```verilog
// Clock generator
reg hclk, gmii_tx_clk, rgmii_rxc;
reg hresetn, gtx_resetn, rx_resetn;

initial begin
    hclk = 0; gmii_tx_clk = 0; rgmii_rxc = 0;
    forever #5 hclk = ~hclk;          // 100MHz
end
initial forever #4 gmii_tx_clk = ~gmii_tx_clk;   // 125MHz
initial forever #4 rgmii_rxc = ~rgmii_rxc;        // 125MHz

// Reset sequence: async assert, sync de-assert
initial begin
    hresetn = 0; gtx_resetn = 0; rx_resetn = 0;
    repeat(20) @(posedge hclk);       // Hold reset ≥10 cycles
    hresetn = 1;
    repeat(5) @(posedge gmii_tx_clk); gtx_resetn = 1;
    repeat(5) @(posedge rgmii_rxc);   rx_resetn = 1;
end
```

### Step 3: 生成 AHB Master BFM

```verilog
// AHB Register Write
task ahb_write;
    input [12:0] addr;
    input [31:0] data;
begin
    @(posedge hclk);
    hsel   = 1; haddr = addr; hwrite = 1; hwdata = data; htrans = 2'b10;
    @(posedge hclk);
    while (!hready) @(posedge hclk);
    hsel = 0; htrans = 2'b00;
end
endtask

// AHB Register Read
task ahb_read;
    input  [12:0] addr;
    output [31:0] data;
begin
    @(posedge hclk);
    hsel = 1; haddr = addr; hwrite = 0; htrans = 2'b10;
    @(posedge hclk);
    while (!hready) @(posedge hclk);
    data = hrdata;
    hsel = 0; htrans = 2'b00;
end
endtask
```

### Step 4: 生成 RGMII PHY BFM

```verilog
// RGMII RX: inject frame into DUT (4-bit DDR → 8-bit SDR)
task rgmii_send_frame;
    input [7:0] frame_data [0:511];  // Up to 512 bytes
    input [15:0] frame_len;
    integer i;
begin
    // Preamble + SFD
    for (i = 0; i < 7; i++)   send_byte(8'h55);   // Preamble
    send_byte(8'hD5);                                // SFD
    // Frame data
    for (i = 0; i < frame_len; i++) send_byte(frame_data[i]);
    // De-assert dv after last byte (EOP)
    @(posedge rgmii_rxc);
    rgmii_rx_ctl = 0;
end
endtask

// Send one byte over 4-bit DDR RGMII
task send_byte;
    input [7:0] data;
begin
    @(posedge rgmii_rxc);
    rgmii_rxd    = data[3:0];  rgmii_rx_ctl = 1;
    @(negedge rgmii_rxc);
    rgmii_rxd    = data[7:4];  rgmii_rx_ctl = 1;
end
endtask
```

### Step 5: 生成以太网包构造器

```verilog
// Build a standard Ethernet frame
function void build_eth_frame;
    input [47:0] da, sa;
    input [15:0] etype;
    input [7:0]  payload [*];
    input [15:0] payload_len;
    output [7:0] frame [*];
    output [15:0] frame_len;
    integer i;
begin
    i = 0;
    // DA (6 bytes)
    for (int j = 0; j < 6; j++) frame[i++] = da >> (40 - j*8);
    // SA (6 bytes)
    for (int j = 0; j < 6; j++) frame[i++] = sa >> (40 - j*8);
    // EtherType (2 bytes, big-endian)
    frame[i++] = etype[15:8]; frame[i++] = etype[7:0];
    // Payload
    for (int j = 0; j < payload_len; j++) frame[i++] = payload[j];
    // PAD (if < 46 bytes)
    while (i < 60) frame[i++] = 8'h00;
    // CRC-32 placeholder — CRC32 module computes this
    frame_len = i + 4;  // +4 for CRC appended by MAC
end
endfunction
```

### Step 6: 生成 Scoreboard

```verilog
// Checker: compare TX output with expected RX input
// For loopback test: TX frame should match RX frame (minus PAD/CRC diff)
always @(posedge gmii_tx_clk) begin
    if (gmii_tx_en) begin
        tx_byte_cnt <= tx_byte_cnt + 1;
        tx_buffer[tx_byte_cnt] <= gmii_txd;
    end
    if (tx_frame_done) begin
        if (tx_buffer[0:5] == expected_da &&
            tx_byte_cnt == expected_len)
            $display("[PASS] TX frame match: %0d bytes", tx_byte_cnt);
        else begin
            $display("[FAIL] TX mismatch: got %0d, expected %0d", tx_byte_cnt, expected_len);
            $finish;
        end
        tx_byte_cnt <= 0;
    end
end
```

### Step 7: 生成 FSDB Dumping

```verilog
initial begin
    $fsdbDumpfile("tb_eth_mac_top.fsdb");
    $fsdbDumpvars(0, tb_eth_mac_top);
end
```

### Step 8: 组装顶层 Testbench

将以上模块组合到 `tb_<dut>.v` 中：

```verilog
module tb_eth_mac_top;

    // Clock & Reset
    reg hclk, gmii_tx_clk, rgmii_rxc;
    reg hresetn, gtx_resetn, rx_resetn;

    // AHB Master
    reg        hsel;   reg [12:0] haddr;  reg        hwrite;
    reg [31:0] hwdata; reg [ 1:0] htrans;
    wire       hready; wire [31:0] hrdata; wire       hresp;

    // AHB Slave port (DMA)
    wire [31:0] hm_addr_o, hm_wdata_o;
    wire        hm_write_o; wire [2:0] hm_size_o, hm_burst_o;
    wire [1:0] hm_trans_o;
    reg  [31:0] hm_rdata_i; reg hm_ready_i; reg hm_resp_i;

    // RGMII PHY side
    reg  [3:0] rgmii_rxd;  reg  rgmii_rx_ctl;
    wire        rgmii_txc; wire [3:0] rgmii_txd; wire rgmii_tx_ctl;

    // Interrupt
    wire intr_o;

    // DUT
    eth_mac_top #(.P_SHELL_MODE(0)) u_dut (
        .hclk         (hclk),
        .hresetn      (hresetn),
        .hsel         (hsel),
        .haddr        (haddr),
        .hwrite       (hwrite),
        .hwdata       (hwdata),
        .htrans       (htrans),
        .hrdata       (hrdata),
        .hready       (hready),
        .hresp        (hresp),
        .hm_addr_o    (hm_addr_o),
        .hm_write_o   (hm_write_o),
        .hm_wdata_o   (hm_wdata_o),
        .hm_size_o    (hm_size_o),
        .hm_burst_o   (hm_burst_o),
        .hm_trans_o   (hm_trans_o),
        .hm_rdata_i   (hm_rdata_i),
        .hm_ready_i   (hm_ready_i),
        .hm_resp_i    (hm_resp_i),
        .gmii_tx_clk  (gmii_tx_clk),
        .intr_o       (intr_o),
        .rgmii_rxc    (rgmii_rxc),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl),
        .rgmii_txc    (rgmii_txc),
        .rgmii_txd    (rgmii_txd),
        .rgmii_tx_ctl (rgmii_tx_ctl),
        .mdio_clk     (),
        .mdio_data    ()
    );

    // ... BFM instances, clock gen, scoreboard ...

    // FSDB dumping
    initial begin
        $fsdbDumpfile("tb_eth_mac_top.fsdb");
        $fsdbDumpvars(0, tb_eth_mac_top);
    end

    // Test sequence
    initial begin
        // 1. Wait for reset release
        wait(hresetn); repeat(10) @(posedge hclk);

        // 2. Configure MAC via AHB CSR
        ahb_write(13'h000, {16'd0, 1'b0, 2'd0, 2'b11, 1'b0, 2'd0, 1'b1, 3'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0});
        // TE=1, RE=1, DM=1 (full duplex), PS=1 (1000M)

        // 3. Configure MAC address
        ahb_write(13'h304, 32'h1122_3344);  // MAC_Address0_Low
        ahb_write(13'h300, 32'h0000_5566);  // MAC_Address0_High

        // 4. Setup DMA descriptor ring in simulated memory
        setup_tx_descriptor(0, 32'h1000, 64);  // Buf at 0x1000, 64 bytes

        // 5. Write packet data to simulated memory
        build_eth_frame(48'h001122334455, 48'h665544332211, 16'h0800, payload, 46, frame, len);
        write_mem(32'h1000, frame, len);

        // 6. Start DMA
        ahb_write(13'h1128, 8'd1);  // DMA_CH0_TxDesc_Tail = 1

        // 7. Wait for frame transmission
        repeat(1000) @(posedge gmii_tx_clk);

        // 8. Check results
        if (frame_tx_match) $display("[TEST] PASS");
        else                 $display("[TEST] FAIL");

        $finish;
    end

endmodule
```

---

## 测试场景模板

### 场景 1: CSR 读写测试

```
目标: 验证 AHB 寄存器读写通路
步骤:
  1. 写 MAC_Configuration, 读回检查
  2. 写 MAC_Address0, 读回检查
  3. 写 MAC_Interrupt_Enable, 读回检查
通过条件: 所有读回值 == 写入值
```

### 场景 2: TX 单帧发送

```
目标: 验证 TX 数据通路
步骤:
  1. 配置 MAC + DMA
  2. 构造一个标准以太网帧放入内存
  3. 启动 DMA 发送
  4. 在 RGMII TX 侧捕获输出帧
  5. 比对 DA/SA/Type/Payload/CRC
通过条件: 输出帧 == 输入帧
```

### 场景 3: RX 单帧接收

```
目标: 验证 RX 数据通路
步骤:
  1. 配置 MAC + DMA + 地址过滤
  2. 从 RGMII RX 侧注入一个帧
  3. 检查 DMA 是否将帧写入内存
通过条件: 内存中的帧 == 注入的帧
```

### 场景 4: Flow Control 测试

```
目标: 验证 Pause 帧响应
步骤:
  1. 配置 Flow Control
  2. 从 RGMII RX 注入 Pause 帧 (Pause Time = 100)
  3. 检查 MAC TX 是否暂停
通过条件: TX 在 Pause 期间不发帧
```

---

## 注意事项

1. **时序仿真 vs RTL 仿真**: 生成的 testbench 默认用于 RTL 功能仿真（零延迟）。门级仿真需要 SDF 反标。
2. **FSDB vs VCD**: 优先生成 FSDB（Verdi 原生格式），文件更小。VCS 需要 `-debug_access+all` 且 run 时加 `-ucli -do run.tcl`。
3. **Memory BFM**: AHB slave 内存模型应支持简单的读写响应（OKAY），用于模拟 DMA 访问的系统内存。
4. **异步时钟**: `hclk`、`gmii_tx_clk`、`rgmii_rxc` 使用不同的 `forever` 循环，频率可配，相位关系随机。
5. **复位序列**: 异步复位保持 ≥10 个对应时钟周期后同步释放。
