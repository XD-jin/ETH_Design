---
name: rtl-reviewer
description: RTL 代码评审助手，系统性检查代码风格、可综合性、时钟复位、状态机、跨时钟域、资源性能，并支持 RTL 与设计规格一致性检查
triggers:
  - RTL审查
  - 代码检查
  - 代码风格
  - RTL review
  - 设计评审
  - 代码评审
  - 规格一致性
---

# RTL Reviewer — RTL 代码评审

对 RTL 代码进行系统性评审，覆盖代码风格、可综合性、时钟复位、状态机、组合/时序逻辑、跨时钟域和资源性能。当提供设计规格时，自动调用 `consistency_check` 进行 RTL 与规格的一致性检查。

## 输入

- RTL 代码文件（.v / .sv）
- 设计规格 / 规格定义 JSON（可选，用于一致性检查）
- 检查配置（可选）

## 输出

- 评审报告（Markdown）
- 问题清单（按 Error / Warning / Info 分级）
- 修复建议 + 代码质量评分

## 评审维度

### 1. 文件结构与注释

| 检查项 | 说明 | 级别 |
|---|---|---|
| 文件头完整 | 含文件名、作者、版本、日期、功能描述 | Info |
| 模块名与文件名一致 | `tx_fifo.v` 对应 `TX_FIFO` | Error |
| 单文件单模块 | 一个文件只包含一个模块 | Error |
| 端口注释 | 每个端口有行内注释 | Info |
| 关键逻辑注释 | 复杂逻辑、状态机、跨域处理有注释 | Info |
| 注释使用英文 | 所有注释必须使用英文，简洁易懂 | Warning |

### 2. 命名规范

| 检查项 | 说明 | 级别 |
|---|---|---|
| 模块/实例名大写 | `FIFO U_FIFO (...)` | Error |
| 信号名小写下划线 | `ram_addr`, `wr_data` | Warning |
| 常量全大写 | `DATA_WIDTH`, `MAX_COUNT` | Warning |
| 时钟含 `clk` | `clk`, `hclk`, `clk_77m` | Warning |
| 复位含 `rst` | `rst_n`, `hrst_n` | Warning |
| 低有效后缀 `_n` | `rst_n`, `we_n` | Warning |
| FSM 变量规范 | `xxx_curr_st`, `xxx_next_st` | Info |
| 关键字禁用 | 禁止 Verilog/VHDL 关键字作标识符 | Error |

**命名约定速查**：

| 类型 | 规范 | 示例 |
|---|---|---|
| 时钟 | `clk`, `clk_xxx` | `clk_sys` |
| 复位 | `rst_n`, `xxx_rst_n` | `sys_rst_n` |
| 使能 | `xxx_en` | `clk_en` |
| 有效 | `xxx_valid` / `xxx_vld` | `data_valid` |
| 准备 | `xxx_ready` / `xxx_rdy` | `tx_ready` |
| 低有效 | `xxx_n` | `irq_n` |
| 计数器 | `xxx_cnt` | `timeout_cnt` |
| 延迟寄存器 | `xxx_ff1`, `xxx_ff2` | `data_ff1` |
| 锁存器 | `xxx_lat` | `addr_lat` |
| 异步信号 | `xxx_a` | `irq_a` |

### 3. 模块声明与信号

| 检查项 | 说明 | 级别 |
|---|---|---|
| 端口声明顺序 | 先 input 后 output，先 clock 后 reset | Info |
| 端口位宽明确 | 避免隐式 1-bit | Warning |
| 命名端口连接 | 实例化必须使用命名端口连接 | Error |
| wire 显式声明 | 所有 wire 必须显式声明 | Error |
| 过程赋值信号声明为 reg | `always` 块内赋值的信号必须声明为 `reg`，禁止 `wire`（Verilog 语法要求，`wire` 只能用于 `assign` 连续赋值） | Error |
| 信号集中声明 | 内部 wire 集中在一个区域 | Info |
| 端口无内联表达式 | 端口连接中避免 glue logic | Warning |
| 例化端口位宽匹配 | 实例化时连接双方端口位宽必须一致（如 `[3:0]`→`[3:0]`）。特例：显式截断需注释说明 | Error |
| 参数化位宽一致性 | 同一 parameter 值在两端的位宽推导必须一致（如 `P_DATA_WIDTH=32`→例化端口32-bit，但连接信号为8-bit） | Error |
| 悬空输出端口 | 未连接的 output 端口在综合后可能被优化，需用 `.port()` 显式留空 | Warning |

**位宽不匹配常见模式**：

| 模式 | VCS Warning | 示例 | 修复 |
|------|-----------|------|------|
| port 定义偏大 | PCWM: N-bit → M-bit port | `wire [3:0] intr;` → port `input [31:0] cfg_intr` | port 改为 `[3:0]` |
| 协议端口超宽 | PCWM: 3-bit → 4-bit | `wire [2:0] hburst;` → port `output [3:0] ahb_burst` | AMBA HBURST=3-bit, port 改为 `[2:0]` |
| 参数化 FIFO 不匹配 | PCWM: 8-bit → 32-bit | `wire [7:0] rd;` → `async_fifo #(.W(32))` 的 rd_data | 信号改为 `[31:0]`，使用时取 `[7:0]` |
| 未连接端口 | TFIPC | 例化时缺少端口连接 | 补充 `.port_name(signal)` |

### 4. 可综合性

| 检查项 | 说明 | 级别 |
|---|---|---|
| 无 initial 块 | 除 testbench 外禁止 initial | Error |
| 无 `#` 延迟 | 禁止延迟控制语句 | Error |
| 无系统任务 | 禁止 `$display`/`$monitor`/`$printf` 等 | Error |
| 无 real/event 类型 | 禁止不可综合数据类型 | Error |
| 无 UDP 原语 | 禁止 Verilog 原语 | Error |
| 无递归调用 | 禁止递归模块调用 | Error |
| 单时钟 per always | 每个 always 块只有一个时钟 | Error |
| 循环静态范围 | 循环范围在编译时确定 | Error |
| 禁止 `full_case`/`parallel_case` | 禁止综合指令 | Warning |
| case 有 default | case 语句必须有 default 分支 | Error |
| 未用输入驱动 | 未用的 module 输入必须驱动 | Warning |
| 未用输出留空连接 | 未用的 module 输出留空连接 `.port()`，禁止声明 `_nc`/`_unused` 信号 | Info |
| 避免顶层 glue logic | 顶层模块只做实例化 | Warning |
| latch 存在|尽量不使用 latch，若必须使用，需在评审报告中说明 | Warning |

### 5. 时钟与复位

| 检查项 | 说明 | 级别 |
|---|---|---|
| 复位策略一致 | 同一模块内复位策略统一 | Error |
| 复位类型明确 | 同步/异步、高/低有效 | Error |
| 所有寄存器可复位 | 所有寄存器都有复位路径 | Warning |
| 复位文档化 | 复位策略在文件头说明 | Info |
| 无手工时钟门控 | 使用综合工具插入 ICG | Warning |
| 无时钟双沿 | 禁止使用时钟双沿 | Error |
| 无内部时钟 | 禁止内部生成的时钟 | Error |
| 无内部 set/reset | 禁止内部生成的 set/reset 信号 | Error |

### 6. 状态机设计

| 检查项 | 说明 | 级别 |
|---|---|---|
| 三段式 FSM | 推荐三段式（curr/next/output） | Warning |
| 状态编码用 parameter | FSM 状态编码必须使用 parameter | Error |
| default 状态 | 状态机必须有默认状态 | Error |
| 无死锁 | 所有状态可达且可跳出 | Error |
| 无非法跳转 | 状态转换路径完整 | Error |

**三段式 FSM 模板**：

```verilog
// State register
always @(posedge clk or negedge rst_n) begin
    if (rst_n == 1'b0)
        curr_st <= ST_IDLE;
    else
        curr_st <= next_st;
end

// Next state logic
always @(*) begin
    case (curr_st)
        ST_IDLE : next_st = ST_READ;
        ST_READ : next_st = ST_WRITE;
        default : next_st = ST_IDLE;
    endcase
end

// Output logic
always @(posedge clk or negedge rst_n) begin
    if (rst_n == 1'b0)
        out <= 2'b0;
    else begin
        if (curr_st == ST_WRITE)
            out <= data;
        else
            out <= 2'b0;
    end
end
```

### 7. 组合逻辑

| 检查项 | 说明 | 级别 |
|---|---|---|
| 完整敏感列表 | `always @(*)` 或完整列表 | Error |
| 无意外 latch | 组合逻辑必须完整赋值 | Error |
| 完整分支 | if-else / case 完整 | Warning |
| 阻塞赋值 `=` | 组合 always 块用阻塞赋值 | Error |
| `assign` 仅用于重命名 | 避免复杂 assign 逻辑 | Warning |
| 括号明确优先级 | 复杂表达式加括号 | Warning |

### 8. 时序逻辑

| 检查项 | 说明 | 级别 |
|---|---|---|
| 非阻塞赋值 `<=` | 时序 always 块用非阻塞赋值 | Error |
| 过程赋值信号声明为 reg | 时序 always 块内赋值的信号必须声明为 `reg`，禁止 `wire`（参见维度 3 同名检查项） | Error |
| 操作数位宽匹配 | 运算双方位宽一致 | Error |
| 条件表达式 1-bit | 条件表达式应为 1-bit 值 | Warning |
| 避免组合环 | 禁止组合逻辑反馈环 | Error |
| IP 接口输出寄存 | IP 模块接口输出必须寄存 | Warning |

### 9. 跨时钟域

| 检查项 | 说明 | 级别 |
|---|---|---|
| 识别跨域信号 | 标注所有跨时钟域连接 | Error |
| 单比特有同步器 | 控制/使能信号使用双触发器 | Error |
| 多比特用握手/FIFO | 数据总线使用异步 FIFO | Error |
| 同步器在目标域 | 同步器放在目标时钟域 | Error |
| 无时钟作数据 | 禁止时钟信号作为数据 | Error |
| 异步逻辑独立 | 异步逻辑独立成单独模块 | Warning |

### 10. 资源与性能

| 检查项 | 说明 | 级别 |
|---|---|---|
| 关键路径关注 | 长组合逻辑路径需关注 | Info |
| 流水线使用 | 适合场景使用流水线 | Info |
| 资源复用 | 大型重复逻辑考虑资源共享 | Info |
| 避免 latch | 禁止使用 latch | Error |
| 避免三态 | 禁止三态器件和双向 net | Error |

### 10.5 标准单元封装使用

> 检查 RTL 是否正确使用 `rtl/std_cell/` 下的封装模块，而非内联运算符或手工实现。

| 检查项 | 说明 | 级别 |
|---|---|---|
| 禁止内联 `*` 乘法 | 乘法必须使用 `mul_pipe` / `mul_pipe_s` 实例 | Error |
| 禁止内联 `/` 除法 | 除法必须使用 `div_pipe` 实例 | Error |
| 禁止手写迭代除法器 | 恢复余数/非恢复余数等迭代除法器应替换为 `div_pipe` + 序列器 | Error |
| 禁止手工时钟门控 | 时钟门控必须使用 `clk_gate` 封装 | Error |
| 未用输出留空连接 | 封装模块未用输出端口留空连接 `.port()`，禁止声明 `_nc`/`_unused` 信号 | Warning |
| P_LATENCY 一致性 | 封装实例的 P_LATENCY 与上下文流水线匹配 | Warning |
| 有符号乘法用 `_s` | 有符号乘法必须使用 `mul_pipe_s`，而非 `mul_pipe` | Error |
| 条件编译宏完整 | 封装模块内 `ifdef` 宏命名符合 `USE_FOUNDRY_*` 规范 | Info |

**封装模块速查**：

| 模块 | 文件 | 用途 | 关键参数 |
|------|------|------|----------|


**违规示例与修正**：

```verilog
// ❌ Error: 内联乘法
assign addr = row * cols + offset;

// ✅ Correct: 使用封装
agdc_mul_pipe #(.P_WIDTH_A(12), .P_WIDTH_B(7)) u_mul_addr
(
    .core_clk (core_clk  ),
    .rst_n    (rst_n     ),
    .din_a    (row       ),
    .din_b    (cols      ),
    .dout     (row_cols  )
);
assign addr = row_cols + offset;
```

```verilog
// ❌ Error: 内联除法
assign tiles_per_row = (width + tile_w - 1) / tile_w;

// ✅ Correct: 使用封装（P_CEIL=1 自动向上取整，无需手动 +tile_w-1）
agdc_div_pipe #(.P_WIDTH_N(13), .P_WIDTH_D(8), .P_LATENCY(1), .P_CEIL(1))
u_div_tiles
(
    .core_clk   (core_clk       ),
    .rst_n      (rst_n          ),
    .din_vld    (div_start      ),
    .din_numer  (width          ),
    .din_denom  (tile_w         ),
    .dout_vld   (div_done       ),
    .dout_quot  (tiles_per_row  ),
    .dout_ready (div_rdy_nc     )
);
```

### 11. RTL 与设计规格一致性

> 当提供设计规格时，调用 `consistency_check` skill 进行详细检查。

| 检查项 | 说明 | 级别 |
|---|---|---|
| 寄存器一致性 | 位域、属性、复位值与文档匹配 | Error |
| 接口一致性 | 端口名称、方向、位宽与文档匹配 | Error |
| 功能特性一致 | 状态机、中断、参数与文档匹配 | Warning |
| 时钟复位一致 | 时钟域、复位策略与文档匹配 | Error |

**检查方法**：
1. 若输入包含设计规格 / 规格定义 JSON，调用 `consistency_check` skill
2. 将一致性检查结果合并到评审报告中
3. 在问题清单中标注「一致性」维度的问题

## 代码模板参考

```verilog
// ============================================================================
// Module: example_module
// Description: 示例模块功能描述
// Author: xxx
// Version: v1.0
// Date: YYYY-MM-DD
// Reset: 异步复位，低有效 (rst_n)
// Clock: clk — 系统时钟
// ============================================================================

module example_module #(
    parameter DATA_WIDTH = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    data_valid,
    input  wire [DATA_WIDTH-1:0]   data_in,
    output reg  [DATA_WIDTH-1:0]   data_out
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] data_reg;

    //--------------------------------------------------------------------------
    // Main Logic
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= {DATA_WIDTH{1'b0}};
            data_out <= {DATA_WIDTH{1'b0}};
        end else begin
            if (data_valid) begin
                data_reg <= data_in;
            end
            data_out <= data_reg;
        end
    end

endmodule
```

## 评审报告模板

```markdown
# RTL 代码评审报告

## 基本信息
- **模块名**: xxx
- **文件路径**: xxx.v
- **行数**: xxx
- **评审日期**: YYYY-MM-DD

## 评审结果汇总

| 维度 | Error | Warning | Info |
|---|---|---|---|
| 文件结构与注释 | 0 | 0 | 2 |
| 命名规范 | 0 | 2 | 1 |
| 模块声明与信号 | 0 | 1 | 0 |
| 可综合性 | 1 | 0 | 0 |
| 时钟与复位 | 0 | 1 | 0 |
| 状态机设计 | 0 | 0 | 1 |
| 组合逻辑 | 1 | 0 | 0 |
| 时序逻辑 | 0 | 0 | 0 |
| 跨时钟域 | 0 | 1 | 0 |
| 资源与性能 | 0 | 0 | 1 |
| RTL与规格一致性 | 0 | 1 | 0 |
| **总计** | **2** | **6** | **5** |

## 问题详情

### [ERROR-001] 可综合性 — initial 块
- **位置**: Line 45
- **代码**: `initial begin cnt = 0; end`
- **建议**: 移除 initial 块，使用复位初始化

### [ERROR-002] 组合逻辑 — latch 生成
- **位置**: Line 78
- **代码**: `always @(*) if (en) q = d;`
- **建议**: 添加 else 分支

### [WARNING-001] 命名规范
- **位置**: Line 12
- **代码**: `reg [7:0] counter;`
- **建议**: 使用 `cnt` 或 `cnt_reg`

## 代码质量评分

| 维度 | 评分 |
|---|---|
| 可综合性 | ⭐⭐⭐⭐☆ |
| 可读性 | ⭐⭐⭐☆☆ |
| 可维护性 | ⭐⭐⭐⭐☆ |
| 时序设计 | ⭐⭐⭐☆☆ |
| **综合评分** | **72/100** |
```

## 与其他 Skill 配合

```
doc_parser → spec_parser → rtl_generator → rtl_reviewer ─┬→ consistency_check (有规格时)
                                               ↓        │
                                         cdc_review (深度CDC)  │
                                         timing_review (综合后)│
                                                          ↓
                                                    完整评审报告
```

**调用关系说明**：
- 当输入包含设计规格时，`rtl_reviewer` 自动调用 `consistency_check` 进行 RTL 与规格的一致性检查
- 一致性检查结果合并到评审报告中，标注为「RTL与规格一致性」维度
