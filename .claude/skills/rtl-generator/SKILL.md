---
name: rtl-generator
description: 根据结构化规格生成可综合的 Verilog/SystemVerilog RTL 代码
triggers:
  - 生成RTL
  - 生成Verilog
  - 生成模块代码
  - RTL生成
---
# RTL Generator - RTL 代码生成器

根据 spec-parser 输出的 JSON 规格生成可综合的 RTL 代码。

## 输入

- spec-parser 输出的 JSON 规格
- 或用户描述的模块接口和功能

## 输出

- 单个或多个 `.v` / `.sv` 文件
- 模块骨架或完整实现

## 流程

### Step 1: 确定生成顺序

按 `connections` 中的依赖关系确定模块生成顺序：

1. 先生成无依赖的叶子模块
2. 再生成依赖已生成模块的父模块
3. 最后生成顶层模块

### Step 2: 生成模块声明

```verilog
module module_name #(
  parameter DATA_WIDTH = 32
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [DATA_WIDTH-1:0] data_in,
  output reg  [DATA_WIDTH-1:0] data_out
);
```

### Step 3: 声明内部信号

根据端口连接需求推断内部信号：

```verilog
  // 内部信号
  wire [DATA_WIDTH-1:0] mul_result;
  reg  [DATA_WIDTH-1:0] acc_reg;
```

### Step 4: 生成逻辑

#### 叶子模块

根据端口名称和功能描述生成：

- 时序逻辑：`always @(posedge clk)`
- 组合逻辑：`assign` 或 `always @(*)`
- 状态机：三段式 FSM

#### 父模块

实例化子模块并完成端口连接：

```verilog
  // 子模块实例
  multiplier #(
    .DATA_WIDTH(DATA_WIDTH)
  ) u_mul (
    .clk     (clk),
    .a       (data_in),
    .b       (32'd2),
    .result  (mul_result)
  );
```

### Step 5: 代码风格规范

所有生成的 RTL 代码必须遵循以下编码约定。

#### 文件组织与头部

- 每个文件只包含一个模块（M2 强制）
- 文件名与模块名一致，小写（如 `tx_fifo.v` 对应 `TX_FIFO`）
- 每个文件必须包含文件头，含：文件名、作者、版本号、日期、功能描述、参数说明
- 文件头用标准边界标记起止（`//********************`）
- 额外构造（task/function）需独立头部，含：名称、类型、用途、参数
- 文件头建议包含：复位策略、时钟策略、关键时序、测试特性、异步接口说明

#### 命名规范

- **模块/实例名**：大写字母（`BLOCK1 U_BLOCK1 (...)`）
- **端口/信号/变量名**：小写字母，用下划线分隔单词（`ram_addr`, `wr_data`）
- **常量（parameter / `define）**：大写字母（`BUS_WIDTH `, `AHB_TRANS_SEQ`）
- **时钟信号**：统一含 `clk`（`clk`, `hclk`, `clk_77m`，agdc_clk,isp_clk等）
- **复位信号**：统一含 `rst`（`rst_n`, `hrst_n`）
- **低有效信号**：后缀 `_n`（`rst_n`, `we_n`）
- **FSM 变量**：`<fsm_name>_curr_st`, `<fsm_name>_next_st`
- **锁存器信号**：后缀 `_lat`
- **三态信号**：后缀 `_z`
- **异步信号**：后缀 `_a`
- **延迟寄存器**：后缀 `_ff1`, `_ff2`, `_ff3`...
- **仅字母、数字、下划线**，首字符必须是字母（M1 强制）
- 信号名长度不超过 20 字符
- 信号名在整个层次结构中保持一致
- 禁止使用 Verilog/VHDL 关键字作为标识符（M1 强制）
- 禁止使用_reg为后缀

#### 寄存器排布规范

适用于 AHB/APB 从机寄存器接口模块的位域定义与 RTL 编码。

##### 1. 配对合并

逻辑上成对的参数合并到同一个 32-bit 寄存器，减少地址空间占用，避免配置中间态：

| 成对关系 | 合并寄存器 | 位域布局 |
|----------|-----------|---------|
| 宽+高 | `XXX_SIZE` | [27:16]=h, [15:12] rsvd, [11:0]=w |
| X+Y 坐标 | `XXX_ORIGIN` | [27:16]=y, [15:12] rsvd, [11:0]=x |
| 行+列 | `XXX_GRID` | [14:8]=rows, [7] rsvd, [6:0]=cols |
| 基地址 L/R | `XXX_BASE_L` / `XXX_BASE_R` | 保持独立地址（地址类不适合合并） |

释放的地址标记为保留。同一类布局风格在项目内保持统一（尺寸类高半字放 H、低半字放 W；坐标类高半字放 Y、低半字放 X）。

##### 2. 位域对齐

多 bit 配置项按 4/8/16 bit 边界排布，禁止跨边界字段：

- 1-bit 标志位：可放任意位置
- 2~4 bit 字段：起始位为 4 的倍数（bit0/4/8/12/16/20/24/28）
- 5~8 bit 字段：起始位为 8 的倍数（bit0/8/16/24）
- 9~16 bit 字段：起始位为 16 的倍数（bit0/16）

**反例**（禁止）：5-bit 字段占据 [6:2]，8-bit 字段占据 [19:12]。
**正例**：5-bit 字段占据 [12:8]（8 边界），8-bit 字段占据 [23:16]（16 边界）。

对齐后产生的间隙填 rsvd，读回 0。好处：软件可用 byte/halfword 掩码独立访问字段，仿真波形中字段边界对齐十六进制显示。

##### 3. 命名风格

寄存器与位域命名遵循简洁、统一原则：

- 寄存器名：`大写模块前缀_功能`，如 `AGDC_FRAME_SIZE`、`AGDC_MESH_GRID`
- 位域信号：`cfg_功能_细节`，如 `cfg_frame_w`、`cfg_mesh_cols`
- 尺寸类统一后缀：`_w`/`_h`（宽高）、`_size`（合并寄存器名）
- 坐标类统一后缀：`_x`/`_y`、`_origin`（合并寄存器名）
- 网格类统一后缀：`_cols`/`_rows`、`_grid`（合并寄存器名）
- 避免同义异名：统一用 `cfg_` 前缀表示配置输出，`status_` 表示状态输入

#### 信号命名缩写约定

| 全称        | 缩写    |  | 全称          | 缩写     |
| :---------- | :------ | :- | :------------ | :------- |
| acknowledge | ack     |  | address       | addr(ad) |
| arbiter     | arb     |  | check         | chk      |
| clock       | clk     |  | config        | cfg      |
| control     | ctrl    |  | count         | cnt      |
| data in     | din(di) |  | data out      | dout(do) |
| decode      | dec     |  | delay         | dly      |
| disable     | dis     |  | error         | err      |
| enable      | en(e)   |  | frame         | frm      |
| generate    | gen     |  | grant         | gnt      |
| increase    | inc     |  | input         | in(i)    |
| length      | len     |  | output        | out(o)   |
| packet      | pkt     |  | priority      | pri      |
| pointer     | ptr     |  | rd enable     | ren      |
| read        | rd      |  | ready         | rdy      |
| receive     | rx      |  | request       | req      |
| reset       | rst     |  | segment       | seg      |
| source      | scr     |  | statistics    | stat     |
| timer       | tmr     |  | switch fabric | sf       |
| temporary   | tmp     |  | transmit      | tx       |
| valid       | vld(v)  |  | wr enable     | wen      |
| write       | wr      |  |               |          |

#### 编码风格

- **4 空格缩进**，不使用 Tab（M2 强制）
- 每条 HDL 语句占独立一行（M1 强制）
- 每个端口声明占独立一行（M1 强制）
- 行宽不超过 72 字符
- 端口声明顺序：先 input 后 output，先 clock 后 reset
- 所有内部 wire 集中在一个区域声明
- `parameter` 优于 `define` 用于可配置常量
- 保持常量间的数学关系（`WORD = 2 * HALFWORD`）
- **实例化必须使用命名端口连接**
- 端口连接中避免内联表达式（避免不必要的 glue logic）
- **实例化端口对齐规范**（M2 强制）—— 基于 agdc_cdc 风格：
  - 模块声明：每个端口独占一行，逗号 `,` 推至右侧对齐列，最后一个端口无逗号，`);` 独占一行
  - 无参数例化：`MOD_NAME u_inst` 同行，`(` 换行独占一行
  - 有参数例化：`MOD_NAME #(` 换行 → 参数块 → `)` 换行 → `u_inst` 独占一行 → `(` 换行
  - 实例名：小写字母
  - 同一实例块内对齐：`.port_name` 按该块最长端口名用空格补齐，`(signal` 紧随其后，`),` 推至同一右侧列
  - `#()` 与 `()` 对齐：有参数时 `#(` 和 `(` 同缩进列，内部 `)` 同右侧列
  - 示例（无参数）：
    ```verilog
    agdc_sync u_sync_sw_reset
    (
        .clk        (core_clk              ),
        .rst_n      (rst_n                 ),
        .din        (cfg_sw_reset_hclk     ),
        .dout       (                      ),
        .dout_pulse (cfg_sw_reset_pulse    )
    );
    ```
  - 示例（有参数）：
    ```verilog
    agdc_sync #
    (
        .EDGE_DETECT (1                     )
    )
    u_sync_sw_reset
    (
        .clk        (core_clk              ),
        .rst_n      (rst_n                 ),
        .din        (cfg_sw_reset_hclk     ),
        .dout       (                      ),
        .dout_pulse (cfg_sw_reset_pulse    )
    );
    ```
- FSM 状态编码必须使用 parameter
- 复杂表达式加括号明确优先级
- wire 必须显式声明
- 操作数位宽必须匹配
- 条件表达式应为 1-bit 值
- `assign` 仅用于信号重命名
- always块内尽量只操作一个寄存器信号名称
- 避免使用 for 循环
- **注释必须使用英文**，简洁易懂（M2 强制）
  - 文件头、端口注释、内部信号注释、逻辑块注释一律使用英文
  - 避免复杂从句，使用简单的主谓宾结构
  - 示例：`// Internal signals` 而非 `// 内部信号`

#### FSM 编码风格（三进程法）

```verilog
// State register
always @(posedge clock or negedge reset_n) begin
    if (reset_n == 1'b0)
        curr_st <= ST_IDLE;
    else
        curr_st <= next_st;
end

// Next state logic
always @(*) begin
    case (curr_st)
        ST_IDLE : next_st = ST_READ;
        ST_READ : next_st = ST_WRITE;
        // ...
        default : next_st = ST_IDLE;
    endcase
end

// Output logic
always @(posedge clock or negedge reset_n) begin
    if (reset_n == 1'b0)
        out <= 2'b0;
    else begin
        if (curr_st == ST_WRITE)
            out <= data;
        else
            out <= 2'b0;
    end
end
```

#### 可综合设计（Synthesis）

- 只使用可综合语句（M1 强制）
- 禁止波形语句（如 `$finish`, `$shm_open`）（M1 强制）
- 禁止仿真系统任务（`$display`, `$monitor`, `$printf` 等）（M1 强制）
- 禁止 `wait` 语句和 `#delay` 延迟语句（M1 强制）
- 禁止 `real` 和 `event` 数据类型（M1 强制）
- 每个 always 块只能有一个时钟（M1 强制）
- 循环必须是静态范围（M1 强制）
- 禁止内嵌综合脚本
- 禁止 `full_case` / `parallel_case` 指令
- 组合逻辑必须完整赋值，避免 latch
- 禁止 Verilog 原语（UDP）（M1 强制）
- 未用的 module 输入必须驱动（M1 强制）
- 未用的 module 输出留空连接（`.port()`），禁止声明 `_nc`/`_unused` 信号
- 避免顶层 glue logic
- case 语句必须有 default 分支
- 状态机必须有默认状态

#### 标准单元封装（rtl/std_cell/）

功能 RTL 中禁止直接使用 `*`（乘法）、`/`（除法）运算符或手工实现迭代除法器/乘法器。必须使用 `rtl/std_cell/` 下的封装模块，以便后续流片时替换为晶圆厂 IP。

##### 封装模块清单

| 模块 | 用途 | 参数要点 | 晶圆厂替换宏 |
|------|------|----------|-------------|
| `agdc_div_pipe` | 流水线除法器 | `P_WIDTH_N/P_WIDTH_D/P_WIDTH_Q/P_LATENCY/P_CEIL` | `AGDC_USE_FOUNDRY_DIV` |
| `agdc_mul_pipe` | 无符号乘法器 | `P_WIDTH_A/P_WIDTH_B/P_LATENCY` | `AGDC_USE_FOUNDRY_DSP` |
| `agdc_mul_pipe_s` | 有符号乘法器 | `P_WIDTH_A/P_WIDTH_B/P_LATENCY` | `AGDC_USE_FOUNDRY_DSP` |
| `agdc_clk_gate` | 时钟门控 | 无参数，端口：`clk_in/en/te/clk_out` | `AGDC_USE_FOUNDRY_ICG` |

##### 使用规则

1. **禁止内联 `*` 运算符**：所有乘法必须通过 `agdc_mul_pipe`（无符号）或 `agdc_mul_pipe_s`（有符号）实例完成
2. **禁止内联 `/` 运算符**：所有除法必须通过 `agdc_div_pipe` 实例完成
3. **禁止手写迭代除法器**：如恢复余数除法器，改用 `agdc_div_pipe` 封装 + 简化序列器 FSM
4. **P_LATENCY 默认为 0**：组合逻辑输出，与原有行为一致；需要时设为 1 或更高
5. **P_CEIL=1 用于向上取整除法**：`ceil(a/b)` 等价于 `(a + b - 1) / b`，也可直接用 `P_CEIL=1` 避免手动偏移
6. **时钟门控**：使用 `agdc_clk_gate` 封装，`te` 端口接 `scan_mode`，功能模式下 `te=0`
7. **未用输出留空连接**：封装模块的未用输出端口留空连接 `.port()`，禁止声明 `_nc`/`_unused` 信号

##### 除法器封装实例模板

```verilog
agdc_div_pipe #
(
    .P_WIDTH_N (42  ),
    .P_WIDTH_D (12  ),
    .P_WIDTH_Q (42  ),
    .P_LATENCY (41  ),
    .P_CEIL    (1   )
)
u_div_x
(
    .core_clk   (core_clk    ),
    .rst_n      (rst_n       ),
    .din_vld    (div_start   ),
    .din_numer  (dividend    ),
    .din_denom  (divisor     ),
    .dout_vld   (div_done    ),
    .dout_quot  (div_result  ),
    .dout_ready (             )
);
```

##### 乘法器封装实例模板

```verilog
// Unsigned
agdc_mul_pipe #
(
    .P_WIDTH_A (12),
    .P_WIDTH_B (7 ),
    .P_LATENCY (0 )
)
u_mul_addr
(
    .core_clk (core_clk  ),
    .rst_n    (rst_n     ),
    .din_a    (row       ),
    .din_b    (cols      ),
    .dout     (addr_prod )
);

// Signed
agdc_mul_pipe_s #
(
    .P_WIDTH_A (18),
    .P_WIDTH_B (18),
    .P_LATENCY (0 )
)
u_mul_affine
(
    .core_clk (core_clk   ),
    .rst_n    (rst_n      ),
    .din_a    (coeff_a    ),
    .din_b    (coord_u    ),
    .dout     (prod_au    )
);
```

##### 时钟门控实例模板

```verilog
agdc_clk_gate u_ckg_pipe0
(
    .clk_in  (core_clk             ),
    .en      (pipe0_active | ckg_dis),
    .te      (scan_mode            ),
    .clk_out (core_clk_gated_pipe0 )
);
```

##### 条件编译策略

所有封装模块内部使用 `ifdef` 保护，不定义宏时走行为模型（默认），定义后走晶圆厂 IP：

| 宏定义 | 影响模块 |
|--------|----------|
| `AGDC_USE_FOUNDRY_DIV` | agdc_div_pipe |
| `AGDC_USE_FOUNDRY_DSP` | agdc_mul_pipe, agdc_mul_pipe_s |
| `AGDC_USE_FOUNDRY_ICG` | agdc_clk_gate |

流片时在综合脚本中定义对应宏即可切换，功能 RTL 无需修改。

#### SHELL_MODE 空壳模式（M2 强制）

每个模块顶层必须包含 `P_SHELL_MODE` 参数，用于系统级仿真时将不需要的模块变为空壳，避免其输出影响总线行为。

##### 设计意图

- 系统仿真时，某些模块可能尚未准备好或不需要参与仿真
- 若简单地将模块输入悬空，内部逻辑可能产生 X 态传播，或输出非法值导致总线 hang 住
- SHELL_MODE 将整个模块变为空壳，所有输出接固定安全值，彻底隔离该模块

##### 实现规范

1. **参数声明**：每个模块顶层必须声明 `parameter P_SHELL_MODE = 0`
2. **generate 隔离**：使用 `generate if (P_SHELL_MODE) ... else ... endgenerate` 将空壳逻辑与正常逻辑完全隔离
3. **输出信号 tie-off 规则**：
   - **握手 ready 信号**（含 `ready`/`rdy` 的输出）：接 `1'b1`，表示本模块始终准备好接收，不会阻塞上游
   - **握手 valid 信号**（含 `valid`/`vld` 的输出）：接 `1'b0`，表示本模块无有效数据产出
   - **数据信号**（`data`/`addr`/`len` 等）：接 `'0`（全零）
   - **中断/错误信号**：接 `1'b0`（不触发）
   - **状态信号**：接空闲状态值
4. **输入处理**：空壳模式下所有输入未使用，综合工具会自动优化
5. **子模块例化**：空壳分支内不例化任何子模块，纯 wire 赋值

##### 代码模板

```verilog
module agdc_example #(
    parameter P_DATA_WIDTH  = 32,
    parameter P_SHELL_MODE  = 0      // 1 = shell mode, bypass all internal logic
) (
    input  wire                        core_clk,
    input  wire                        rst_n,
    // Upstream handshake
    input  wire                        pready,
    output wire                        pvalid,
    output wire [P_DATA_WIDTH-1:0]     pdata,
    // Downstream handshake
    output wire                        sready,
    input  wire                        svalid,
    input  wire [P_DATA_WIDTH-1:0]     sdata,
    // Status
    output wire                        interrupt
);

    //--------------------------------------------------------------------------
    // Shell Mode: tie outputs to safe fixed values, no internal logic
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            // Handshake: upstream — not ready to accept, no valid output
            assign sready  = 1'b0;                     // backpressure: not ready
            assign pvalid  = 1'b0;                     // no valid data produced
            assign pdata   = {P_DATA_WIDTH{1'b0}};     // data tied to 0

            // Status / interrupt
            assign interrupt = 1'b0;                   // no interrupt

            // Unused inputs are optimized away by synthesis

        //--------------------------------------------------------------------------
        // Active Mode: normal functional logic
        //--------------------------------------------------------------------------
        end else begin : gen_active

            // ... normal RTL implementation ...

            // Example handshake logic
            assign sready  = ~fifo_full;
            assign pvalid  = fifo_not_empty;
            assign pdata   = fifo_rdata;

            // ... submodule instantiations ...

        end
    endgenerate

endmodule
```

##### 信号 tie-off 速查表

| 信号类型 | 方向 | SHELL_MODE 值 | 说明 |
|----------|------|---------------|------|
| `*ready` / `*rdy` | output | `1'b1` | 表示始终可接收，不阻塞上游 |
| `*valid` / `*vld` | output | `1'b0` | 表示无有效数据，下游不采样 |
| `*data` / `*addr` / `*len` / `*size` | output | `'0` | 数据总线接全零 |
| `*interrupt` / `*error` / `*err` | output | `1'b0` | 不触发中断/错误 |
| `*last` / `*end` | output | `1'b0` | 非最后一拍 |
| `*keep` / `*strobe` | output | `'0` | 字节使能全零 |
| `*id` / `*user` | output | `'0` | 侧带信号全零 |
| 总线主接口（如 AXI/AHB master） | output | 所有 output 按上述规则 tie-off | 等同于 master 空闲 |
| 寄存器配置输出（cfg_*） | output | `'0` | 配置值全零（默认值） |

> **注意**：特定模块可能有例外——如某些 ready 信号在 SHELL_MODE 下应接 `1'b0` 以阻断上游数据流。请在模块规格中明确说明例外情况。

##### 顶层集成建议

在顶层 `agdc_top` 中，通过系统级宏定义统一控制所有子模块的 SHELL_MODE：

```verilog
// agdc_top.v
`ifdef AGDC_SHELL_MODE
    localparam LP_SHELL_MODE = 1;
`else
    localparam LP_SHELL_MODE = 0;
`endif

agdc_module_a #(
    .P_SHELL_MODE (LP_SHELL_MODE)
) u_module_a (
    ...
);

agdc_module_b #(
    .P_SHELL_MODE (LP_SHELL_MODE)
) u_module_b (
    ...
);
```

仿真时通过 `+define+AGDC_SHELL_MODE` 一键切换全系统空壳模式。也可以按模块粒度单独控制（如只 shell 掉某个子模块，其余保持正常）。

#### 时序与 STA

- 避免组合逻辑反馈环
- 采用同步设计方法
- 简化寄存器时钟来源
- 避免 multicycle path 和 false path
- 避免时钟作为数据
- 禁止使用 latch（M2 强制）
- 异步逻辑独立成单独模块
- IP 接口输出必须寄存（M2 强制）
- IP 接口寄存器同一时钟单沿触发
- IP 必须是同步设计（M2 强制）
- 时钟方案必须文档化（M1 强制）
- 避免手工时钟门控，使用综合工具插入
- IP 必须可复位，复位策略必须文档化（M1 强制）
- 避免工艺相关单元

#### DFT（可测性设计）

- 禁止三态器件（M1 强制）
- 禁止双向 net
- 禁止在设计中用 latch
- 禁止使用时钟双沿
- 禁止门控时钟
- 禁止内部生成的时钟
- 禁止内部生成的 set/reset 信号
- 禁止用时钟和 set/reset 信号作为数据
- 避免组合环
- 避免常量输入或浮空输出
- 避免时钟或 set/reset 信号直接输出
- 避免时钟作为 set/reset 信号
- 避免异步路径环路

#### 仿真

- **时序 always 块用非阻塞赋值 `<=`**（M1 强制）
- **组合 always 块用阻塞赋值 `=`**（M1 强制）
- 组合 always 块敏感列表必须完整（M1 强制）
- 避免冗余敏感列表
- 初始化控制存储单元
- 禁止赋 X 值（`don't care`）（M1 强制）
- 避免使用 delay 赋值

## 示例

**输入 JSON**：

```json
{
  "modules": [{
    "name": "accumulator",
    "ports": [
      {"name": "clk", "direction": "input", "width": 1, "type": "clock"},
      {"name": "rst_n", "direction": "input", "width": 1, "type": "reset"},
      {"name": "data_in", "direction": "input", "width": 32},
      {"name": "data_valid", "direction": "input", "width": 1},
      {"name": "result", "direction": "output", "width": 32}
    ],
    "description": "累加器，每个valid周期累加输入数据"
  }]
}
```

**输出 Verilog**：

```verilog
// ============================================================================
// Module: accumulator
// Description: 累加器，每个valid周期累加输入数据
// ============================================================================

module accumulator #(
  parameter DATA_WIDTH = 32
) (
  input  wire                    clk,
  input  wire                    rst_n,
  input  wire [DATA_WIDTH-1:0]   data_in,
  input  wire                    data_valid,
  output reg  [DATA_WIDTH-1:0]   result
);

  //--------------------------------------------------------------------------
  // Internal Signals
  //--------------------------------------------------------------------------
  reg [DATA_WIDTH-1:0] acc_reg;

  //--------------------------------------------------------------------------
  // Accumulator Logic
  //--------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_reg <= {DATA_WIDTH{1'b0}};
      result  <= {DATA_WIDTH{1'b0}};
    end else begin
      if (data_valid) begin
        acc_reg <= acc_reg + data_in;
      end
      result <= acc_reg;
    end
  end

endmodule
```

## 可选配置

用户可指定：

- 代码风格：Verilog / SystemVerilog
- 复位策略：异步低有效 / 同步高有效 / 无复位
- 是否生成 testbench 骨架
- 是否生成接口封装（AXI/AHB/APB）
