---
name: cdc-review
description: 跨时钟域检查助手，分析 CDC 路径并给出同步策略建议
triggers:
  - CDC检查
  - 跨时钟域
  - 时钟域检查
  - CDC review
---

# CDC Review - 跨时钟域检查助手

分析 RTL 代码中的跨时钟域路径，识别潜在问题并给出同步策略建议。

## 输入

- RTL 代码文件
- 时钟域定义（时钟信号列表）
- 约束文件（可选）

## 输出

- CDC 路径分析报告
- 同步器缺失警告
- 修复建议

## CDC 问题分类

### 1. 单比特信号跨域

| 类型 | 风险 | 解决方案 |
|---|---|---|
| 控制信号 | 中 | 双触发器同步器 |
| 使能信号 | 中 | 双触发器同步器 + 边沿检测 |
| 握手信号 | 高 | 握手协议同步 |

**双触发器同步器**：
```systemverilog
// 双触发器同步器（适用于单比特控制信号）
module sync_2ff (
  input  wire clk_dst,
  input  wire rst_n,
  input  wire data_in,
  output reg  data_out
);
  reg data_sync1;
  
  always @(posedge clk_dst or negedge rst_n) begin
    if (!rst_n) begin
      data_sync1 <= 1'b0;
      data_out   <= 1'b0;
    end else begin
      data_sync1 <= data_in;
      data_out   <= data_sync1;
    end
  end
endmodule
```

**边沿检测同步器**：
```systemverilog
// 边沿检测同步器（适用于脉冲信号）
module sync_edge_det (
  input  wire clk_dst,
  input  wire rst_n,
  input  wire pulse_in,
  output wire pulse_out
);
  reg [2:0] sync_chain;
  
  always @(posedge clk_dst or negedge rst_n) begin
    if (!rst_n)
      sync_chain <= 3'b000;
    else
      sync_chain <= {sync_chain[1:0], pulse_in};
  end
  
  // 上升沿检测
  assign pulse_out = sync_chain[1] & ~sync_chain[2];
endmodule
```

### 2. 多比特信号跨域

| 类型 | 风险 | 解决方案 |
|---|---|---|
| 数据总线 | 高 | 异步 FIFO |
| 计数器 | 高 | Gray 码计数器 |
| 状态向量 | 高 | 握手协议 |

**异步 FIFO**：
```systemverilog
// 异步 FIFO 示例（使用 Gray 码指针）
module async_fifo #(
  parameter DATA_WIDTH = 32,
  parameter DEPTH      = 16
) (
  // Write domain
  input  wire                  wr_clk,
  input  wire                  wr_rst_n,
  input  wire                  wr_en,
  input  wire [DATA_WIDTH-1:0] wr_data,
  output wire                  full,
  
  // Read domain
  input  wire                  rd_clk,
  input  wire                  rd_rst_n,
  input  wire                  rd_en,
  output wire [DATA_WIDTH-1:0] rd_data,
  output wire                  empty
);
  // Gray code pointers for CDC
  // Pointer sync logic
  // Memory array
  // ... implementation
endmodule
```

**握手协议**：
```systemverilog
// 握手协议同步（适用于多比特数据）
// TX domain -> RX domain
// 1. TX asserts valid with data
// 2. RX syncs valid, captures data
// 3. RX asserts ack
// 4. TX syncs ack, deasserts valid
```

### 3. 快时钟到慢时钟

| 问题 | 风险 | 解决方案 |
|---|---|---|
| 信号丢失 | 高 | 脉冲展宽 |
| 采样失败 | 高 | 握手协议 |

**脉冲展宽**：
```systemverilog
// 脉冲展宽电路（快到慢）
module pulse_stretch (
  input  wire clk_src,
  input  wire clk_dst,
  input  wire rst_n,
  input  wire pulse_in,
  output wire pulse_out
);
  reg stretch_reg;
  reg ack_sync;
  
  // Source domain: stretch pulse until ack
  always @(posedge clk_src or negedge rst_n) begin
    if (!rst_n)
      stretch_reg <= 1'b0;
    else if (pulse_in)
      stretch_reg <= 1'b1;
    else if (ack_sync)
      stretch_reg <= 1'b0;
  end
  
  // Destination domain: sync and detect
  // ack feedback sync
endmodule
```

## CDC 检查流程

### Step 1: 识别时钟域
```
时钟域分析:
  clk_sys   : 系统主时钟  (100 MHz)
  clk_peri  : 外设时钟    (50 MHz)
  clk_slow  : 慢速时钟    (10 MHz)
```

### Step 2: 扫描跨域路径
```
跨域信号扫描:
  [WARNING] sig_ctrl -> clk_sys -> clk_peri (无同步器)
  [OK]      data_bus  -> clk_sys -> clk_peri (使用异步FIFO)
  [OK]      status    -> clk_peri -> clk_sys (双触发器同步)
```

### Step 3: 分析同步策略
| 路径 | 信号类型 | 当前策略 | 建议 |
|---|---|---|---|
| ctrl → peri | 单比特控制 | 无 | 添加双触发器 |
| sys → peri | 数据总线 | 异步FIFO | ✓ 正确 |
| peri → sys | 状态向量 | 握手 | ✓ 正确 |

## 常见 CDC 错误

### 错误 1: 直接跨域连接
```systemverilog
// ❌ 错误: 直接跨域连接
always @(posedge clk_a) begin
  data_a <= data_b;  // data_b 来自 clk_b 域
end

// ✅ 正确: 使用同步器
sync_2ff u_sync (
  .clk_dst  (clk_a),
  .rst_n    (rst_n),
  .data_in  (data_b),
  .data_out (data_b_sync)
);

always @(posedge clk_a) begin
  data_a <= data_b_sync;
end
```

### 错误 2: 多比特直接跨域
```systemverilog
// ❌ 错误: 多比特直接跨域
always @(posedge clk_a) begin
  cnt_a <= cnt_b;  // 8-bit 计数器直接跨域
end

// ✅ 正确: 使用 Gray 码或握手
// 方案1: Gray 码计数器
// 方案2: 握手协议
// 方案3: 异步 FIFO
```

### 错误 3: 同步器位置错误
```systemverilog
// ❌ 错误: 同步器在源域
always @(posedge clk_src) begin
  data_sync <= data_in;  // 应该在目标域同步
end

// ✅ 正确: 同步器在目标域
always @(posedge clk_dst) begin
  data_sync <= data_in;
end
```

## 检查报告模板

```markdown
# CDC 检查报告

## 时钟域定义
| 时钟 | 频率 | 来源 |
|---|---|---|
| clk_sys | 100 MHz | PLL |
| clk_peri | 50 MHz | 分频 |
| clk_slow | 10 MHz | 外部 |

## CDC 路径统计
| 类型 | 数量 | 有同步器 | 无同步器 |
|---|---|---|---|
| 单比特 | 12 | 10 | 2 |
| 多比特 | 3 | 3 | 0 |
| 总线 | 2 | 2 | 0 |

## 问题详情

### [CDC-001] 缺少同步器
- **信号**: ctrl_valid
- **源域**: clk_sys
- **目标域**: clk_peri
- **类型**: 单比特控制信号
- **建议**: 添加双触发器同步器

### [CDC-002] 多比特跨域风险
- **信号**: status_bus[7:0]
- **源域**: clk_peri
- **目标域**: clk_sys
- **类型**: 多比特状态向量
- **建议**: 使用握手协议或 Gray 编码
```
