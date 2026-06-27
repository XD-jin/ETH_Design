# ETH_MAC IP Specification v1.0

> Gigabit Ethernet MAC Controller with AHB Host Interface and RGMII PHY Interface
> 1000Mbps Full-Duplex | 2-Channel DMA | IEEE 802.3x Flow Control

---

## 1. Overview

### 1.1 功能定位

ETH_MAC 是一个全双工千兆以太网 MAC 控制器 IP，提供从 AHB 系统总线到 RGMII PHY 接口的完整数据通路。

### 1.2 关键指标

| 参数 | 规格 |
|------|------|
| 线速率 | 1000 Mbps (仅全双工) |
| PHY 接口 | RGMII v2.6, 4-bit DDR @ 125 MHz |
| 主机接口 | AHB Master (DMA) + AHB Slave (CSR) |
| AHB 数据宽度 | 32-bit |
| DMA 通道 | 2 Tx Channels + 2 Rx Channels |
| 描述符格式 | 16-Byte Ring Descriptor |
| 流控 | IEEE 802.3x Pause Frame (全双工) |
| 帧长 | 64 ~ 1518 Bytes (标准) |
| 地址过滤 | Perfect Match (4 entries) + 64-bit Hash Filter |
| 时钟域 | hclk (AHB) + gmii_tx_clk (125MHz PLL) + gmii_rx_clk (125MHz PHY) |

### 1.2b V1.0 Scope — 明确边界

| 功能 | V1.0 状态 | 说明 |
|------|:---------:|------|
| 基础 MAC Frame TX/RX | ✅ 完整 | CRC-32, PAD, Preamble, IFG |
| 地址过滤 (Perfect + Hash) | ✅ 完整 | 4 精确匹配 entries, 64-bit hash |
| IEEE 802.3x Flow Control | ✅ 完整 | Pause 帧自动收发 |
| 2-Channel DMA (TX+RX) | ✅ 完整 | 4 通道全部连通, 环描述符 |
| MTL 队列管理 | ✅ 完整 | 异步 FIFO, SP/WRR 调度 |
| gmii_tx_clk 独立时钟 | ✅ 完整 | 顶层端口, 与 hclk 完全异步 |
| P_SHELL_MODE | ✅ 完整 | 所有 20 模块 |
| Jumbo Frame (JE) | ❌ 不实现 | V1.0 最大 1518B |
| VLAN (802.1Q) | ❌ 不实现 | 无 Tag 插入/剥离/过滤 |
| Checksum Offload | ❌ 不实现 | 无 IP/TCP/UDP checksum |
| IEEE 1588 / PTP | ❌ 不实现 | 无时间戳 |
| EEE (802.3az) | ❌ 不实现 | 无低功耗 idle |
| TSN (802.1Qbv/Qbu) | ❌ 不实现 | 无 EST/FPE |
| MDIO Master | ❌ 不实现 | `mdio_clk` 未连接 |
| RMON/MIB Counters | ❌ 不实现 | 无统计计数器 |
| Register File (reg_file.v) | ❌ 待实现 | 46 个寄存器待 RTL 化 |
| RGMII DDR 原语 | ❌ 待 FPGA | IDDR/ODDR 由综合工具推断 |

### 1.3 顶层接口信号

```
                    ┌──────────────────────────┐
    AHB Slave       │                          │      RGMII
    (CSR Access)    │        ETH_MAC           │
   ────────────────►│                          ├────────────────►
                    │                          │   rgmii_txc
   AHB Master       │                          │   rgmii_txd[3:0]
   (DMA Data)       │                          │   rgmii_tx_ctl
   ◄────────────────┤                          │
                    │                          │   rgmii_rxc
   Interrupt        │                          │   rgmii_rxd[3:0]
   ◄────────────────┤                          │   rgmii_rx_ctl
                    │                          │
   Clocks & Reset   │                          │   MDIO (optional)
   ────────────────►│                          ├────────────────►
                    └──────────────────────────┘
```

### 1.4 数据流概览

```
  TX Path:
    CPU 准备描述符+数据 → AHB Master 读 → MTL Tx Queue → MAC TX → RGMII TX

  RX Path:
    RGMII RX → MAC RX → MTL Rx Queue → AHB Master 写 → 描述符写回 → 中断
```

---

## 2. Top-Level Architecture

### 2.1 四层结构

```
  ┌─────────────────────────────────────────────────────────┐
  │                    软件 (Driver)                         │
  └────────────────────────┬────────────────────────────────┘
                           │
  ┌────────────────────────┴────────────────────────────────┐
  │  L1: BUS Interface     │  AHB Slave (CSR) + AHB Master  │  hclk
  ├────────────────────────┼────────────────────────────────┤
  │  L2: DMA Controller    │  描述符引擎 + 通道仲裁 + 中断    │  hclk
  ├────────────────────────┼────────────────────────────────┤
  │  L3: MTL (Transaction) │  队列缓冲 + 调度 + 流控水位      │  跨域
  ├────────────────────────┼────────────────────────────────┤
  │  L4: MAC Core          │  帧处理 + CRC + RGMII           │  gmii_clk
  └────────────────────────┴────────────────────────────────┘
```

### 2.2 模块层次

```
ETH_MAC_TOP
├── AHB_SLAVE_IF        — CSR 寄存器访问 (AHB Slave)
├── AHB_MASTER_IF       — DMA 数据搬运 (AHB Master)
├── DMA_CONTROLLER      — 描述符引擎 + 通道仲裁 + 中断管理
│   ├── DMA_TX_CH0      — 发送通道 0
│   ├── DMA_TX_CH1      — 发送通道 1
│   ├── DMA_RX_CH0      — 接收通道 0
│   ├── DMA_RX_CH1      — 接收通道 1
│   └── DMA_ARBITER     — 通道仲裁 (Tx: SP, Rx: RR)
├── MTL                  — MAC Transaction Layer (新增独立层)
│   ├── MTL_TX           — Tx Queues (共享 SRAM) + Tx Scheduler
│   ├── MTL_RX           — Rx Queues (共享 SRAM) + Rx Router
│   └── MTL_FLOW         — 流控水位检测 / Pause 触发逻辑
├── MAC_CORE
│   ├── MAC_TX           — TX Pipeline: TBU → TPC → TPE
│   ├── MAC_RX           — RX Pipeline: RxMAC → CRC → RPC → RBI
│   ├── CRC32            — CRC-32 生成 / 校验
│   ├── ADDR_FILTER      — 地址过滤 (Perfect + Hash)
│   └── FLOW_CONTROL     — IEEE 802.3x Pause 帧生成/检测
├── RGMII_IF             — RGMII TX/RX 接口 (DDR 处理)
└── MDIO_MASTER          — MDIO Clause 22 接口 (可选)
```

### 2.3 内部互联与时钟域

```
                    ◄────── hclk domain ──────►  ◄─ gmii_clk domain ──►

  ┌─────────┐     ┌──────────────┐
  │AHB Slave│◄────┤     CSR      │              ┌──────────────────────┐
  │  (CSR)  │     │  Register    │──────────────│ config to all blocks │
  └─────────┘     │    File      │              └──────────────────────┘
                  └──────────────┘

  ┌─────────┐     ┌──────────────┐    ┌──────────────┐    ┌──────────┐
  │AHB      │◄───►│     DMA      │◄──►│     MTL      │◄──►│   MAC    │
  │Master   │     │  Controller  │ ATI│  ┌────────┐  │ MTI│  Core    ├──► RGMII TX
  │(DMA)    │     │  Ch0/Ch1 T/R │    │  │Tx Queue│──┼───►│  TX Path │
  └─────────┘     └──────┬───────┘    │  │+ Sched  │  │    └──────────┘
                         │            │  ├────────┤  │    ┌──────────┐
                         │ 中断       │  │Rx Queue│◄─┼────│  RX Path │◄── RGMII RX
                         │            │  │+ Router │  │ MRI└──────────┘
                         │            │  └────────┘  │    ┌──────────┐
                         │            │       │      │    │  Flow    │
                         │            │  水位检测 ────┼───►│  Control │
                         │            └──────┬───────┘    └──────────┘
                         │                   │
                         │            Async FIFO (hclk ↔ gmii_clk)
                         │            Gray-code 指针同步
                         │
                  ┌──────┴───────┐
                  │  Interrupt   │
                  │  Controller  │──► intr_o (to CPU)
                  └──────────────┘
```

**MTL 层的核心价值**：
1. **时钟域隔离** — DMA 全速跑 hclk，MAC 跑 gmii_clk，MTL 的异步 FIFO 扛住跨域
2. **队列管理** — 多 Queue 共享 SRAM 的分区、调度、流控水位检测，全在 MTL 里
3. **解耦** — 增加 DMA Channel 只需在 MTL 多分一个 Queue，MAC 完全不感知

---

## 3. Module Descriptions

### 3.1 AHB Slave Interface (CSR)

**功能**：提供 CPU 对内部寄存器映射的读写访问。

| 特性 | 规格 |
|------|------|
| 协议 | AMBA 2.0 AHB Slave |
| 数据宽度 | 32-bit |
| 访问粒度 | 32-bit word (不支持字节/半字) |
| 响应 | OKAY only (无 SPLIT/RETRY) |
| 访问延迟 | 2 个 hclk 周期 (无等待) |
| 地址空间 | 4KB (12-bit address) |

**接口信号**：

```verilog
input  wire        hclk,
input  wire        hresetn,
input  wire        hsel,
input  wire [11:0] haddr,
input  wire        hwrite,
input  wire [31:0] hwdata,
input  wire [ 1:0] htrans,
input  wire [ 2:0] hsize,
input  wire [ 2:0] hburst,
output wire [31:0] hrdata,
output wire        hready,
output wire        hresp
```

### 3.2 AHB Master Interface (DMA)

**功能**：DMA 通过 AHB Master 读写系统内存中的描述符和数据缓冲区。

| 特性 | 规格 |
|------|------|
| 协议 | AMBA 2.0 AHB Master |
| 数据宽度 | 32-bit (可配置 64-bit) |
| 地址宽度 | 32-bit |
| 突发类型 | SINGLE, INCR4, INCR8, INCR16 |
| 最大突发长度 | 16 beats (可编程) |
| 对齐 | 地址对齐到总线宽度 |
| 边界处理 | 1KB 边界自动拆分 |
| 响应处理 | OKAY / ERROR |

**接口信号**：

```verilog
output wire [31:0] haddr_o,
output wire        hwrite_o,
output wire [31:0] hwdata_o,
output wire [ 2:0] hsize_o,
output wire [ 2:0] hburst_o,
output wire [ 3:0] hprot_o,
output wire [ 1:0] htrans_o,
input  wire [31:0] hrdata_i,
input  wire        hready_i,
input  wire        hresp_i
```

### 3.3 DMA Controller

#### 3.3.1 总体架构

```
  ┌─────────────────────────────────────────────┐
  │              DMA Controller                  │
  │                                              │
  │  ┌──────────┐  ┌──────────┐                 │
  │  │ Tx Ch 0  │  │ Tx Ch 1  │                 │
  │  │ Desc Fetch│  │ Desc Fetch│               │
  │  │ Data Read │  │ Data Read │               │
  │  └────┬─────┘  └────┬─────┘                 │
  │       │              │                       │
  │       ▼              ▼                       │
  │  ┌─────────────────────────┐                │
  │  │     Tx Arbiter (SP)     │                │
  │  │  Priority: Ch0 > Ch1    │                │
  │  └───────────┬─────────────┘                │
  │              │                               │
  │              ▼  to MTL Tx Queue                   │
  │  ┌─────────────────────────┐                │
  │  │       Interrupt Ctrl    │                │
  │  │  TX/RX per-channel intr │                │
  │  │  Timer-based coalescing │                │
  │  └─────────────────────────┘                │
  │              ▲                               │
  │  ┌──────────┐  ┌──────────┐                 │
  │  │ Rx Ch 0  │  │ Rx Ch 1  │                 │
  │  │ Desc Fetch│  │ Desc Fetch│               │
  │  │ Data Write│  │ Data Write│               │
  │  └────┬─────┘  └────┬─────┘                 │
  │       │              │                       │
  │  ┌─────────────────────────┐                │
  │  │     Rx Arbiter (RR)     │                │
  │  └─────────────────────────┘                │
  │              ▲                               │
  │              │ from MTL Rx Queue                  │
  └─────────────────────────────────────────────┘
```

#### 3.3.2 TX DMA 操作

```
1. CPU 准备 Tx 描述符 (OWN=1)，写 Tail Pointer 寄存器
2. DMA 检测到 Tail > Current → 开始处理
3. DMA 读取描述符 (通过 AHB Master 读 16 字节)
4. DMA 解析描述符: BUF1ADDR, BUF1LEN, BUF2ADDR, BUF2LEN, FD, LD, CPC, IOC
5. DMA 读取数据缓冲区 (AHB Master 突发读)
6. DMA 将数据写入 MTL Tx Queue (带 SOP/EOP 标记)
7. MAC 发送完成后 → Tx Status 回传
8. DMA 写回描述符状态 (仅 LD=1 的描述符)
9. IOC=1 → 产生中断 / IOC=0 → 等中断聚合定时器
```

#### 3.3.3 RX DMA 操作

```
1. CPU 准备 Rx 描述符 (OWN=1, 空缓冲区地址)，写 Tail Pointer 寄存器
2. DMA 检测到 MTL Rx Queue 有数据 → 开始
3. DMA 读取描述符 (通过 AHB Master 读 16 字节)
4. DMA 从 MTL Rx Queue 读取数据 (SOP/EOP + 包数据 + Rx Status)
5. DMA 将数据写入 Buffer (AHB Master 突发写)
6. DMA 写回描述符状态 (PL, CE, OE, RE, LT, ES)
7. 产生中断
```

#### 3.3.4 通道仲裁

**Tx 仲裁 (SP - Strict Priority)**：
- 优先级: Channel 0 > Channel 1
- Channel 0 队列空时, Channel 1 才能发送
- 防止低优先级通道饥饿: 每发完 8 个包轮换一次 (可配置)

**Rx 仲裁 (RR - Round Robin)**：
- 两个通道轮流服务
- 每次服务一个完整包
- 公平分配 Rx 带宽

### 3.4 MTL — MAC Transaction Layer

MTL 是 DMA 和 MAC 之间的中间层，负责队列缓冲、跨时钟域隔离、发送调度、接收路由和流控水位检测。

#### 3.4.1 为什么必须独立

| 职责 | 归属 | 原因 |
|------|------|------|
| 描述符管理、AHB 总线搬运 | DMA | DMA 只关心"从哪读到哪写" |
| 队列缓冲、调度、流控水位 | MTL | 需要时钟域隔离 + 队列视角 |
| 帧组装/解析、CRC、前导码 | MAC | MAC 只关心"比特和协议" |

DMA 和 MAC 通过 MTL 的 ATI/ARI 接口通信——DMA 只看到"往 Queue N 推数据"，MAC 只看到"从 Queue 拿 8-bit 帧流"。

#### 3.4.2 MTL TX

```
  来自 DMA (ATI 接口, 32-bit, hclk)
        │
        ▼
  ┌─────────────────────────────────────────┐
  │             MTL TX                      │
  │                                         │
  │  ┌────────────────────────────┐         │
  │  │    Tx Queue SRAM           │         │
  │  │  ┌──────────┬──────────┐   │         │
  │  │  │ Queue 0  │ Queue 1  │   │         │
  │  │  │ (4KB)    │ (4KB)    │   │         │
  │  │  │          │          │   │         │
  │  │  │共享: 8KB │          │   │         │
  │  │  └──────────┴──────────┘   │         │
  │  └────────────┬───────────────┘         │
  │               │                          │
  │               ▼                          │
  │  ┌────────────────────────────┐         │
  │  │    Tx Scheduler            │         │
  │  │    算法: WRR / SP          │         │
  │  │    Queue0 > Queue1 (SP)    │         │
  │  │    每 8 帧强制轮换防饥饿    │         │
  │  └────────────┬───────────────┘         │
  │               │                          │
  │               ▼                          │
  │        MTI 接口 (8-bit, gmii_clk)        │
  │        去 MAC TX Pipeline                │
  └─────────────────────────────────────────┘
```

| 参数 | 值 |
|------|-----|
| 每 Queue 深度 | 4KB (可容纳 ~2.7 个最大帧) |
| 总 SRAM | 8KB (2 queues 共享地址空间) |
| 写接口 | ATI (32-bit, hclk, SOP/EOP 边带) |
| 读接口 | MTI (8-bit, gmii_clk, SOP/EOP 边带) |
| 发送模式 | Store-and-Forward (TSF=1) 或 Threshold (TSF=0) |
| 调度算法 | Strict Priority (SP, 默认) 或 Weighted Round Robin (WRR) |

#### 3.4.3 MTL RX

```
  来自 MAC (MRI 接口, 8-bit, gmii_clk)
        │
        ▼
  ┌─────────────────────────────────────────┐
  │             MTL RX                      │
  │                                         │
  │  ┌────────────────────────────┐         │
  │  │    Rx Queue Router         │         │
  │  │    DA 匹配 → Queue0/1      │         │
  │  │    Broadcast → Queue0      │         │
  │  │    Default   → Queue0      │         │
  │  └────────────┬───────────────┘         │
  │               │                          │
  │               ▼                          │
  │  ┌────────────────────────────┐         │
  │  │    Rx Queue SRAM           │         │
  │  │  ┌──────────┬──────────┐   │         │
  │  │  │ Queue 0  │ Queue 1  │   │         │
  │  │  │ (8KB)    │ (8KB)    │   │         │
  │  │  │          │          │   │         │
  │  │  │共享: 16KB│          │   │         │
  │  │  └──────────┴──────────┘   │         │
  │  └────────────┬───────────────┘         │
  │               │                          │
  │               ▼                          │
  │  ┌────────────────────────────┐         │
  │  │    Rx Scheduler            │         │
  │  │    算法: RR (Round Robin)  │         │
  │  │    每次服务一个完整包        │         │
  │  └────────────┬───────────────┘         │
  │               │                          │
  │               ▼                          │
  │        ARI 接口 (32-bit, hclk)           │
  │        去 DMA Rx Channel                 │
  └─────────────────────────────────────────┘
```

| 参数 | 值 |
|------|-----|
| 每 Queue 深度 | 8KB (可容纳 ~5.4 个最大帧) |
| 总 SRAM | 16KB (2 queues 共享地址空间) |
| 写接口 | MRI (8-bit, gmii_clk, SOP/EOP + Rx Status) |
| 读接口 | ARI (32-bit, hclk, SOP/EOP + Rx Status) |
| 接收模式 | Threshold (Cut-through, 默认 64B 阈值) 或 Store-and-Forward |
| 调度算法 | Round Robin (RR, 默认) 或 Strict Priority (SP) |
| 队列路由 | 基于 DA 匹配 MAC 地址寄存器 (MAC_ADDR0→Q0, MAC_ADDR1→Q1) |

#### 3.4.4 MTL Flow Control 水位检测

MTL 直接监测 Rx Queue SRAM 的实时填充水位 (rx_clk 域)：

```
  Rx Queue 填充率:

  0% ─────────────────────────────────────────────────── 100%
       │              │                    │
       │    PLT 水位   │     RFA 水位       │
       │   (低, 解除)   │   (高, 触发)       │
       │              │                    │
       │  正常接收     │   触发 Pause 帧      │  Overflow
       │              │   TFE=1 → 发 Pause │
       │              │                    │
       └── Pause=0 ───┘                    │
           解除暂停                           │
```

| 信号 | 方向 | 描述 |
|------|------|------|
| `mtl_rx_watermark_high` | MTL → MAC Flow Control | FIFO 达到 RFA 阈值, 触发 Pause |
| `mtl_rx_watermark_low` | MTL → MAC Flow Control | FIFO 降到 PLT 阈值, 发 Pause=0 |
| `mtl_rx_overflow` | MTL → MAC Status | FIFO 溢出, 记录丢包 |

#### 3.4.5 异步 FIFO 与 CDC

```
  MTL 是 hclk 和 gmii_clk 之间的唯一 CDC 通道:

  TX 路径:  hclk ──► [ATI I/F] ──► [Async TX FIFO] ──► [MTI I/F] ──► gmii_clk
                              Gray-code 写指针 → 双FF同步 → Gray-code 读指针

  RX 路径:  gmii_clk ──► [MRI I/F] ──► [Async RX FIFO] ──► [ARI I/F] ──► hclk
                              Gray-code 写指针 → 双FF同步 → Gray-code 读指针
```

| CDC 约束 | 值 |
|----------|-----|
| FIFO 深度 | 必须是 2 的幂 (Gray-code 指针要求) |
| 同步器 | 双触发器 (2-FF), 目标时钟域 |
| 指针编码 | Binary → Gray → 2FF sync → Gray → Binary |
| 满/空检测 | 写域: 满 (wr_ptr_gray == rd_ptr_sync_gray, 最高两位取反) |

### 3.5 MAC TX Pipeline

```
   From MTL MTI interface (8-bit, gtx_clk domain)
        │
        ▼
  ┌─────────────────────────┐
  │ TBU (Tx Bus Interface)  │  32-bit → 8-bit 转换, 字节序
  │                         │  输出 Tx Status
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ TPC (Tx Packet Ctrl)    │  CRC/PAD 控制
  │                         │  最小帧长检查 (< 60B → 自动 PAD)
  │                         │  缓冲 8 级寄存器
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ TPE (Tx Protocol Eng)   │  发送状态机
  │                         │  输出: Preamble (7B) + SFD (1B)
  │                         │  IFG 控制 (96 bit times)
  │                         │  CRC 追加 (4B FCS)
  └────────────┬────────────┘
               │
               ▼
        To RGMII_IF (4-bit DDR)
```

**TX 状态机**：

```
  IDLE ──► PREAMBLE ──► DATA ──► CRC ──► IFG ──► IDLE
   ▲         │            │        │       │
   │         │ 7 bytes    │0~N B   │ 4 B   │ ≥12 B
   │         └────────────┴────────┴───────┘
   └────────────────────────────────────────── 循环
```

**CRC-32 生成器**：
- 多项式: `0x04C11DB7` (IEEE 802.3)
- 初始值: `0xFFFF_FFFF`
- 输出反相: 按位取反后小端发送
- 计算范围: DA[0] ~ 最后一个 Data byte

**PAD 生成**：
- 帧长 < 60 Bytes (DA+SA+LT+Data < 60) → 追加 0x00 至 60 字节
- 可通过描述符 CPC 位禁止 PAD 追加

### 3.6 MAC RX Pipeline

```
   From RGMII_IF (8-bit recovered, rx_clk domain)
        │
        ▼
  ┌─────────────────────────┐
  │ Rx MAC                  │  Preamble + SFD 检测/剥离
  │                         │  DA/SA/Type 提取
  │                         │  RX_ER 检测
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ CRC Checker             │  接收数据的 CRC-32 重新计算
  │                         │  与收到的 FCS 比较
  │                         │  不匹配 → CE=1
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ Address Filter          │  Perfect Match: 4 entries
  │                         │  Hash Filter: 64-bit table
  │                         │  Promiscuous / Broadcast / Multicast
  │                         │  Pause Frame DA 检测
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ RPC (Rx Packet Ctrl)    │  PAD 剥离 (可选)
  │                         │  CRC 剥离 (可选)
  │                         │  Watchdog 超时 (2048B)
  │                         │  组装 Rx Status Word
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────┐
  │ RBI (Rx Bus Interface)  │  8-bit → 32-bit 转换
  │                         │  字节序调整
  └────────────┬────────────┘
               │
               ▼
        To MTL (MRI interface)
```

**RX 状态机**：

```
  IDLE ──► SFD_DETECT ──► DATA ──► CRC_CHECK ──► STATUS ──► IDLE
              │             │           │             │
              └─ 检测 0xD5 ─┘           └─ 最后4B=CRC─┘
```

**地址过滤逻辑**：

```
  收到 DA
    │
    ├── Promiscuous Mode? ──── Yes ──► PASS
    │
    ├── DA == FF:FF:FF:FF:FF:FF? ── Yes ──► PASS (Broadcast)
    │
    ├── DA[0] == 1? ── Yes (Multicast)
    │       │
    │       ├── Hash Filter Hit? ── Yes ──► PASS
    │       │
    │       └── Pass All Multicast? ── Yes ──► PASS
    │
    ├── DA == MAC_Addr[0]? ── Yes ──► PASS
    ├── DA == MAC_Addr[1]? ── Yes ──► PASS
    ├── DA == MAC_Addr[2]? ── Yes ──► PASS
    ├── DA == MAC_Addr[3]? ── Yes ──► PASS
    │
    └── DROP (更新 Missed Frame Counter)
```

### 3.7 RGMII Interface

#### 3.7.1 RGMII v2.6 规范

| 信号 | 方向 | 宽度 | 描述 |
|------|------|------|------|
| `rgmii_txc` | Output | 1 | TX 时钟, 125 MHz |
| `rgmii_txd` | Output | 4 | TX 数据, DDR (上升沿 [3:0], 下降沿 [7:4]) |
| `rgmii_tx_ctl` | Output | 1 | TX 控制, DDR (上升沿=TX_EN, 下降沿=TX_EN XOR TX_ER) |
| `rgmii_rxc` | Input | 1 | RX 时钟, 125 MHz (来自 PHY) |
| `rgmii_rxd` | Input | 4 | RX 数据, DDR |
| `rgmii_rx_ctl` | Input | 1 | RX 控制, DDR (上升沿=RX_DV, 下降沿=RX_DV XOR RX_ER) |

#### 3.7.2 TX 时序

```
  rgmii_txc     _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
                ‾\__/‾\__/‾\__/‾\__/‾\__/

  rgmii_txd     ──<TXD[3:0]>──<TXD[7:4]>──
  rgmii_tx_ctl  ──<TX_EN   >──<TX_EN^ER >──

                ◄── 上升沿采样 ──►◄── 下降沿采样 ──►

  MAC → PHY: 时钟由 MAC 输出，TXC 与 TXD/TX_CTL 中心对齐
  Skew: MAC 内部需加 ~1.5~2.0ns 延时，使时钟边沿对准数据中心
```

#### 3.7.3 RX 时序

```
  rgmii_rxc     _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
                ‾\__/‾\__/‾\__/‾\__/‾\__/

  rgmii_rxd     ──<RXD[3:0]>──<RXD[7:4]>──
  rgmii_rx_ctl  ──<RX_DV   >──<RX_DV^ER >──

  PHY → MAC: 时钟由 PHY 输出，RXC 与 RXD/RX_CTL 中心对齐
  MAC 接收端: 直接采样，或加 IDELAY 补偿 PCB 走线延时
```

#### 3.7.4 RGMII_IF 模块内部结构

```verilog
module rgmii_if (
    // GMAC side (8-bit SDR)
    input  wire        gtx_clk,
    input  wire [7:0]  tx_data,
    input  wire        tx_en,
    input  wire        tx_er,
    
    output wire        rx_clk,
    output wire [7:0]  rx_data,
    output wire        rx_dv,
    output wire        rx_er,
    
    // RGMII external pads
    output wire        rgmii_txc,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    input  wire        rgmii_rxc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl
);

// TX: 8-bit SDR → 4-bit DDR
//    上升沿发 tx_data[3:0], tx_en
//    下降沿发 tx_data[7:4], tx_en ^ tx_er
//    TXC 加可配置延迟 (~2ns)

// RX: 4-bit DDR → 8-bit SDR
//    上升沿采 rxd[3:0], rx_dv
//    下降沿采 rxd[7:4], rx_dv ^ rx_er = rx_er

endmodule
```

---

## 4. Clock & Reset

### 4.1 时钟域

```
  ┌───────────────────────────────────────────────────────┐
  │                                                        │
  │   hclk          app_clk       gtx_clk      rx_clk     │
  │   (AHB Bus)     (DMA内部)     (125MHz)     (125MHz)   │
  │      │             │             │            │        │
  │      ▼             ▼             ▼            ▼        │
  │  ┌──────┐     ┌──────┐     ┌──────┐    ┌──────┐      │
  │  │CSR   │     │DMA   │     │MAC TX│    │MAC RX│      │
  │  │Slave │     │Engine│     │      │    │      │      │
  │  └──────┘     └──┬───┘     └──▲───┘    └──┬───┘      │
  │                 │             │            │           │
  │                 ▼             │            ▼           │
  │            ┌────────┐   Async FIFO   ┌────────┐      │
  │            │TX FIFO ├───────────────►│TX FIFO │      │
  │            │(Wr)    │                │(Rd)    │      │
  │            └────────┘                └────────┘      │
  │                                                        │
  │            ┌────────┐   Async FIFO   ┌────────┐      │
  │            │RX FIFO │◄───────────────┤RX FIFO │      │
  │            │(Rd)    │                │(Wr)    │      │
  │            └────────┘                └────────┘      │
  └───────────────────────────────────────────────────────┘

  hclk      : 典型 100~150 MHz (系统 AHB 总线时钟)
  app_clk   : = hclk (DMA 内部时钟, 与 AHB 同源)
  gtx_clk   : 125 MHz (RGMII TX, MAC 内部产生)
  rx_clk    : 125 MHz (RGMII RX, 来自 PHY, 与 gtx_clk 异步!)
```

### 4.2 复位策略

| 复位信号 | 域 | 类型 | 描述 |
|----------|-----|------|------|
| `hresetn` | hclk | 异步有效, 同步释放 | AHB + DMA + CSR 复位 |
| `gtx_resetn` | gtx_clk | 异步有效, 同步释放 | MAC TX 复位 |
| `rx_resetn` | rx_clk | 异步有效, 同步释放 | MAC RX 复位 |

**复位流程**：
1. 上电 → 所有复位有效, ≥ 10 个时钟周期
2. 释放 hresetn → CSR 可访问, 配置寄存器
3. 释放 gtx_resetn, rx_resetn → MAC 启动
4. 写 MAC_Config.TE=1, RE=1 → 收发使能

### 4.3 CDC 同步策略

| 跨域路径 | 信号类型 | 同步方法 |
|----------|---------|----------|
| TX FIFO (hclk→gtx_clk) | 数据 + 控制 | 异步 FIFO, Gray 码指针 |
| RX FIFO (rx_clk→hclk) | 数据 + 控制 | 异步 FIFO, Gray 码指针 |
| CSR → MAC (hclk→gtx_clk) | 配置信号 | 双触发器同步 (2-FF) |
| MAC → CSR (gtx_clk→hclk) | 状态计数器 | 双触发器同步 + 脉冲展宽 |

---

## 5. Register Map

V1.0 实现 46 个核心寄存器。以下无 V1.0 标记的寄存器为预留（后续版本实现）。

```
  Offset       Block          V1.0 寄存器数
  ───────────────────────────────────────
  0x0000       MAC            12 (核心) + 8 (地址)
  0x0C00       MTL            12
  0x1000       DMA            6
  0x1100       DMA_CH         8 / channel × 2 = 16
  Total V1.0                   46
```

### 5.1 寄存器总览

| Offset | 缩写 | 名称 | 复位值 | V1.0 |
|--------|------|------|--------|:----:|
| **EQOS_MAC Block — Core (0x0000 ~ 0x00FF)** |
| 0x0000 | MAC_Configuration | MAC Configuration | 0x0000_0000 | ✅ |
| 0x0008 | MAC_Packet_Filter | MAC Packet Filter Control | 0x0000_0000 | ✅ |
| 0x000C | MAC_Watchdog_Timeout | MAC Watchdog Timeout | 0x0000_0000 | ✅ |
| 0x0010 | MAC_Hash_Table_Reg0 | Hash Table Bits [31:0] | 0x0000_0000 | ✅ |
| 0x0014 | MAC_Hash_Table_Reg1 | Hash Table Bits [63:32] | 0x0000_0000 | ✅ |
| 0x0070 | MAC_Q0_Tx_Flow_Ctrl | Queue 0 Tx Flow Control | 0x0000_0000 | ✅ |
| 0x0074 | MAC_Q1_Tx_Flow_Ctrl | Queue 1 Tx Flow Control | 0x0000_0000 | ✅ |
| 0x0090 | MAC_Rx_Flow_Ctrl | Rx Flow Control | 0x0000_0000 | ✅ |
| 0x00B0 | MAC_Interrupt_Status | MAC Interrupt Status (RC/W1C) | 0x0000_0000 | ✅ |
| 0x00B4 | MAC_Interrupt_Enable | MAC Interrupt Enable | 0x0000_0000 | ✅ |
| 0x00B8 | MAC_Rx_Tx_Status | MAC Rx/Tx Error Status | 0x0000_0000 | ✅ |
| 0x0110 | MAC_Version | MAC Version (RO) | 0x0000_0100 | ✅ |
| **EQOS_MAC Block — Addresses (0x0300 ~ 0x033F)** |
| 0x0300 | MAC_Address0_High | MAC Address 0 High [47:32] | 0x0000_0000 | ✅ |
| 0x0304 | MAC_Address0_Low | MAC Address 0 Low [31:0] | 0x0000_0000 | ✅ |
| 0x0308 | MAC_Address1_High | MAC Address 1 High | 0x0000_0000 | ✅ |
| 0x030C | MAC_Address1_Low | MAC Address 1 Low | 0x0000_0000 | ✅ |
| 0x0310 | MAC_Address2_High | MAC Address 2 High | 0x0000_0000 | ✅ |
| 0x0314 | MAC_Address2_Low | MAC Address 2 Low | 0x0000_0000 | ✅ |
| 0x0318 | MAC_Address3_High | MAC Address 3 High | 0x0000_0000 | ✅ |
| 0x031C | MAC_Address3_Low | MAC Address 3 Low | 0x0000_0000 | ✅ |
| **EQOS_MTL Block (0x0C00 ~ 0x0CFF)** |
| 0x0C00 | MTL_Operation_Mode | MTL Operation Mode | 0x0000_0000 | ✅ |
| 0x0C20 | MTL_Interrupt_Status | MTL Interrupt Status | 0x0000_0000 | ✅ |
| 0x0C30 | MTL_RxQ_DMA_Map0 | Rx Queue to DMA Channel Mapping 0 | 0x0000_0000 | ✅ |
| 0x0D00 | MTL_TxQ0_Operation_Mode | Tx Queue 0 Operation Mode | 0x0000_0000 | ✅ |
| 0x0D04 | MTL_TxQ0_Underflow | Tx Queue 0 Underflow Count | 0x0000_0000 | ✅ |
| 0x0D30 | MTL_RxQ0_Operation_Mode | Rx Queue 0 Operation Mode | 0x0000_0000 | ✅ |
| 0x0D34 | MTL_RxQ0_Missed_Pkt | Rx Queue 0 Missed Packet/Overflow | 0x0000_0000 | ✅ |
| 0x0D40 | MTL_TxQ1_Operation_Mode | Tx Queue 1 Operation Mode | 0x0000_0000 | ✅ |
| 0x0D44 | MTL_TxQ1_Underflow | Tx Queue 1 Underflow Count | 0x0000_0000 | ✅ |
| 0x0D70 | MTL_RxQ1_Operation_Mode | Rx Queue 1 Operation Mode | 0x0000_0000 | ✅ |
| 0x0D74 | MTL_RxQ1_Missed_Pkt | Rx Queue 1 Missed Packet/Overflow | 0x0000_0000 | ✅ |
| **EQOS_DMA Block (0x1000 ~ 0x10FF)** |
| 0x1000 | DMA_Mode | DMA Mode | 0x0000_0000 | ✅ |
| 0x1004 | DMA_SysBus_Mode | DMA System Bus Mode | 0x0100_0000 | ✅ |
| 0x1008 | DMA_Interrupt_Status | DMA Interrupt Status (RC/W1C) | 0x0000_0000 | ✅ |
| 0x100C | DMA_Interrupt_Enable | DMA Interrupt Enable | 0x0000_0000 | ✅ |
| 0x1014 | DMA_Tx_Intr_Timer | Tx Interrupt Coalescing Timer | 0x0000_0000 | ✅ |
| 0x1018 | DMA_Rx_Intr_Timer | Rx Interrupt Coalescing Timer | 0x0000_0000 | ✅ |
| **EQOS_DMA_CH0 Block (0x1100 ~ 0x117F)** |
| 0x1100 | DMA_CH0_Control | Channel 0 Control | 0x0000_0000 | ✅ |
| 0x1104 | DMA_CH0_Tx_Control | Channel 0 Tx Control | 0x0000_0000 | ✅ |
| 0x1108 | DMA_CH0_Rx_Control | Channel 0 Rx Control | 0x0000_0000 | ✅ |
| 0x1114 | DMA_CH0_TxDesc_List_Addr | Channel 0 Tx Desc List Address | 0x0000_0000 | ✅ |
| 0x111C | DMA_CH0_RxDesc_List_Addr | Channel 0 Rx Desc List Address | 0x0000_0000 | ✅ |
| 0x1128 | DMA_CH0_TxDesc_Tail_Pointer | Channel 0 Tx Tail Pointer | 0x0000_0000 | ✅ |
| 0x112C | DMA_CH0_RxDesc_Tail_Pointer | Channel 0 Rx Tail Pointer | 0x0000_0000 | ✅ |
| 0x1144 | DMA_CH0_Status | Channel 0 Status (RC) | 0x0000_0000 | ✅ |
| **EQOS_DMA_CH1 Block (0x1180 ~ 0x11FF)** |
| 0x1180 | DMA_CH1_Control | Channel 1 Control | 0x0000_0000 | ✅ |
| 0x1184 | DMA_CH1_Tx_Control | Channel 1 Tx Control | 0x0000_0000 | ✅ |
| 0x1188 | DMA_CH1_Rx_Control | Channel 1 Rx Control | 0x0000_0000 | ✅ |
| 0x1194 | DMA_CH1_TxDesc_List_Addr | Channel 1 Tx Desc List Address | 0x0000_0000 | ✅ |
| 0x119C | DMA_CH1_RxDesc_List_Addr | Channel 1 Rx Desc List Address | 0x0000_0000 | ✅ |
| 0x11A8 | DMA_CH1_TxDesc_Tail_Pointer | Channel 1 Tx Tail Pointer | 0x0000_0000 | ✅ |
| 0x11AC | DMA_CH1_RxDesc_Tail_Pointer | Channel 1 Rx Tail Pointer | 0x0000_0000 | ✅ |
| 0x11C4 | DMA_CH1_Status | Channel 1 Status (RC) | 0x0000_0000 | ✅ |

### 5.1b V1.0 不实现：已移除的 DWC_ether_qos 寄存器

以下寄存器在 DWC_ether_qos databook 中存在，但本 IP V1.0 **明确不实现**（功能不在 V1.0 范围内）：

| 不实现的寄存器类别 | 原因 |
|-------------------|------|
| `MAC_Ext_Configuration` (0x0004) | EEE/GPSL/SAF/VLAN 扩展控制 — 无 EEE/VLAN |
| `MAC_VLAN_Tag*`, `MAC_VLAN_Incl`, `MAC_Inner_VLAN_Incl` | VLAN Tag 插入/过滤 — V1.0 无 VLAN |
| `MAC_PMT_Control_Status`, `MAC_RWK_Packet_Filter` | 电源管理/远程唤醒 — V1.0 无 PMT |
| `MAC_LPI_*` (0x00D0~0x00DC) | Energy Efficient Ethernet — V1.0 无 EEE |
| `MAC_AN_*` (0x00E0~0x00F4) | Auto-Negotiation — 由外部 PHY 通过 MDIO 管理 |
| `MAC_MDIO_Address/Data` (0x0200~0x0204) | MDIO Master — V1.0 无 MDIO |
| `MAC_ARP_Address` (0x0210) | ARP Offload — V1.0 无 ARP 卸载 |
| `MAC_HW_Feature*` (0x011C~0x0128) | 硬件特性寄存器 — 可选, V1.0 不实现 |
| `MAC_FPE_CTRL_STS` (0x0234) | Frame Preemption — V1.0 无 FPE (802.3br) |
| `MMC_*` (0x0700~0x0808) | RMON/MIB 计数器 — V1.0 不实现 |
| `MTL_DBG_*` (0x0C08~0x0C10) | FIFO Debug 访问 — V1.0 不实现 |
| `MTL_EST_*`, `MTL_TBS_*` | TSN 调度 — V1.0 无 TSN |
| `MTL_TxQ*_Debug` (0x0D08) | Queue Debug — V1.0 不实现 |
| `DMA_CH*_TxDesc_List_HAddr` | High Address (32-bit addr only) — V1.0 仅 32-bit 地址 |
| `DMA_CH*_RxDesc_List_HAddr` | 同上 |
| `DMA_CH*_Current_App_*Desc` | Current Descriptor Pointer (RO) — 可选, V1.0 不实现 |
| `DMA_CH*_TxDesc_Ring_Length` | 环长度可配置 — V1.0 固定 64 entries, 用 parameter |
| `DMA_CH*_RxDesc_Ring_Length` | 同上 |

> **地址模式**: MAC 地址寄存器 `0x0300 + n*8` (n=0~3), DMA 通道寄存器 `0x1100 + ch*0x80 + reg_offset`。
> **读写属性**: RO=Read Only, RW=Read/Write, RC=Read Clear, W1C=Write 1 Clear.

### 5.2 MAC_Configuration (0x0000)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:17 | RSVD | RO | 0 | Reserved |
| 16 | JE | RW | 0 | **Jumbo Frame Enable**: 0=Max 1518B, 1=Max 9018B |
| 15 | RSVD | RO | 0 | Reserved |
| 14 | CST | RW | 0 | **CRC Stripping for Type Frames**: 1=剥离 Type 帧 CRC |
| 13:12 | RSVD | RO | 0 | Reserved |
| 11 | SARC | RW | 0 | **Source Address Replacement Control**: 1=使用 MAC_Addr1~3 替换 SA |
| 10 | RSVD | RO | 0 | Reserved |
| 9 | PS | RW | 1 | **Port Select**: 1=GMII/RGMII 1000Mbps |
| 8 | DM | RW | 1 | **Duplex Mode**: 1=Full Duplex |
| 7 | RSVD | RO | 0 | Reserved |
| 6:5 | IFG | RW | 0 | **Inter-Frame Gap**: 00=96, 01=88, 10=80, 11=72 bit times |
| 4 | JD | RW | 0 | **Jabber Disable**: 1=禁止 Jabber 检测 |
| 3 | TE | RW | 0 | **Transmitter Enable**: 1=使能 TX |
| 2 | RE | RW | 0 | **Receiver Enable**: 1=使能 RX |
| 1 | PRELEN | RW | 0 | **Preamble Length**: 0=7B, 1=5B (缩短前导码) |
| 0 | ACS | RW | 0 | **Automatic Pad/CRC Stripping**: 1=RX 自动剥离 PAD+CRC |

### 5.3 MAC_Packet_Filter (0x0008)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31 | RA | RW | 0 | **Receive All**: 1=接收所有帧 (Promiscuous, 不过滤) |
| 30:16 | RSVD | RO | 0 | Reserved |
| 15:12 | RSVD | RO | 0 | Reserved |
| 11 | VTFE | RW | 0 | **VLAN Tag Filter Enable**: V1.0 reserved |
| 10 | HPF | RW | 0 | **Hash or Perfect Filter**: 0=Perfect Match, 1=Hash Filter |
| 9 | SAF | RW | 0 | **Source Address Filter Enable**: V1.0 reserved |
| 8 | SAIF | RW | 0 | **SA Inverse Filtering**: V1.0 reserved |
| 7 | PCF | RW | 0 | **Pass Control Frames**: 1=转发 Pause/PFC 帧到应用 |
| 6 | DBF | RW | 0 | **Disable Broadcast Frames**: 1=过滤广播帧 |
| 5 | PMF | RW | 0 | **Pass All Multicast**: 1=转发所有组播帧 |
| 4 | DAIF | RW | 0 | **DA Inverse Filtering**: 1=反向过滤 |
| 3 | HM | RW | 0 | **Hash Multicast**: 1=组播用 Hash 过滤 |
| 2 | HU | RW | 0 | **Hash Unicast**: 1=单播用 Hash 过滤 |
| 1:0 | RSVD | RO | 0 | Reserved |

### 5.4 MAC_Q0_Tx_Flow_Ctrl / MAC_Q1_Tx_Flow_Ctrl (0x0070 / 0x0074)

每 Queue 独立的 TX Flow Control 寄存器。Q0 和 Q1 各有一份，寄存器布局相同。

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:16 | PT | RW | 0xFFFF | **Pause Time**: Pause Quanta 值 (16-bit, 单位 512 bit times)。0x0000=Zero-Quanta (取消暂停), 0xFFFF=最大暂停时间 |
| 15:8 | RSVD | RO | 0 | Reserved |
| 7:4 | PLT | RW | 0 | **Pause Low Threshold**: Rx FIFO 低于此水位时发送 Pause=0 解除暂停 (单位 512B) |
| 3 | DZPQ | RW | 0 | **Disable Zero-Quanta Pause**: 1=禁止自动发 Pause=0, 靠定时器自然到期 |
| 2:1 | RFA | RW | 0 | **Rx FIFO Activate Threshold**: 00=50%, 01=62.5%, 10=75%, 11=87.5% (触发 Pause 的水位) |
| 0 | TFE | RW | 0 | **Tx Flow Control Enable**: 1=该 Queue 使能自动 Pause 帧发送 |

### 5.5 MAC_Rx_Flow_Ctrl (0x0090)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:8 | RSVD | RO | 0 | Reserved |
| 7 | RFE | RW | 0 | **Rx Flow Control Enable**: 1=收到 Pause 帧时停止 TX |
| 6:1 | RSVD | RO | 0 | Reserved |
| 0 | UP | RW | 0 | **Unicast Pause Detect**: 1=除了标准组播 DA, 也检测单播 Pause |


### 5.6 MAC_Interrupt_Status (0x00B0) — RC/W1C

| Bits | Name | Description |
|------|------|-------------|
| 31:4 | RSVD | Reserved |
| 3 | TS | **Tx Status**: 帧发送完成 |
| 2 | RSVD | Reserved |
| 1 | PC | **Pause Control**: 收到有效 Pause 帧 |
| 0 | RO | **Receive Overrun**: RX FIFO 溢出 |

> MAC_Interrupt_Enable (0x00B4) 位定义相同, RW 属性。写 1=使能对应中断, 写 0=屏蔽。

### 5.7 MTL_Operation_Mode (0x0C00)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:4 | RSVD | RO | 0 | Reserved |
| 3 | RAA | RW | 0 | **Receive Arbitration Algorithm**: 0=SP, 1=WRR (V1.0 仅 SP) |
| 2 | SCHALG | RW | 0 | **Tx Scheduling Algorithm**: 0=WRR, 1=SP |
| 1 | CNTCLR | RW | 0 | **Counters Clear**: 写 1 清零 MTL counters (自清零) |
| 0 | DTXSTS | RW | 0 | **Drop Tx Status**: 1=不返回 Tx Status, 提高吞吐 |

### 5.8 MTL_TxQx_Operation_Mode (0x0D00 / 0x0D40)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:21 | RSVD | RO | 0 | Reserved |
| 20:16 | TQS | RW | 配置 | **Tx Queue Size**: 队列大小 (256B 粒度) |
| 15:8 | RSVD | RO | 0 | Reserved |
| 7 | RSVD | RO | 0 | Reserved |
| 6:4 | TXQEN | RW | 0 | **Tx Queue Enable**: [6] AV, [5] DCB, [4] Generic. V1.0=0x4 |
| 3 | TSF | RW | 0 | **Tx Store and Forward**: 1=SF 模式, 0=Threshold |
| 2 | FTQ | RW | 0 | **Flush Tx Queue**: 写 1 清空队列 (自清零) |
| 1 | RSVD | RO | 0 | Reserved |
| 0 | RSVD | RO | 0 | Reserved |

### 5.9 MTL_RxQx_Operation_Mode (0x0D30 / 0x0D70)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:25 | RSVD | RO | 0 | Reserved |
| 24:20 | RQS | RW | 配置 | **Rx Queue Size**: 队列大小 (256B 粒度) |
| 19:16 | RSVD | RO | 0 | Reserved |
| 15:8 | RSVD | RO | 0 | Reserved |
| 7 | RSVD | RO | 0 | Reserved |
| 6:4 | RXQEN | RW | 0 | **Rx Queue Enable**: V1.0=0x4 |
| 3 | RSF | RW | 0 | **Rx Store and Forward**: 1=SF 模式, 0=Threshold |
| 2:1 | RTC | RW | 0 | **Rx Threshold Control**: 00=64B, 01=128B, 10=192B, 11=256B |
| 0 | FEP | RW | 0 | **Forward Error Packet**: 1=错误帧也转发给 DMA |

### 5.10 MTL_RxQ_DMA_Map0 (0x0C30)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:8 | RSVD | RO | 0 | Reserved |
| 7:4 | Q1DDMACH | RW | 0 | **Queue 1 DMA Channel**: 0000=Ch0, 0001=Ch1 |
| 3:0 | Q0DDMACH | RW | 0 | **Queue 0 DMA Channel**: 0000=Ch0, 0001=Ch1 |

### 5.11 DMA_Mode (0x1000)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:16 | RSVD | RO | 0 | Reserved |
| 15 | RSVD | RO | 0 | Reserved |
| 14:12 | TXPR | RW | 0 | **Tx Priority Ratio**: Tx 通道间优先级权重 |
| 11:8 | RSVD | RO | 0 | Reserved |
| 7 | RSVD | RO | 0 | Reserved |
| 6:5 | RSVD | RO | 0 | Reserved |
| 4:3 | RSVD | RO | 0 | Reserved |
| 2 | RSVD | RO | 0 | Reserved |
| 1 | DA | RW | 0 | **DMA Arbitration**: 0=Tx/Rx RR, 1=Rx 优先 |
| 0 | SWR | RW | 0 | **Software Reset**: 1=复位所有 DMA (自清零) |

### 5.12 DMA_SysBus_Mode (0x1004)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:16 | RSVD | RO | 0 | Reserved |
| 15:12 | WR_OSR_LMT | RW | 4 | **Write Outstanding Request Limit**: 最大 outstanding write |
| 11:8 | RD_OSR_LMT | RW | 4 | **Read Outstanding Request Limit**: 最大 outstanding read |
| 7 | RSVD | RO | 0 | Reserved |
| 6:5 | RSVD | RO | 0 | Reserved |
| 4:1 | BLEN | RW | 0 | **Burst Length**: AHB 最大 burst = BLEN*8 beats |
| 0 | UNDEF | RW | 0 | **Undefined Burst**: 0=INCRx, 1=INCR (未定义长度) |

### 5.13 DMA_Interrupt_Status (0x1008)

| Bits | Name | Description |
|------|------|-------------|
| 31:8 | RSVD | Reserved |
| 7:4 | RSVD | Reserved |
| 3 | CH1_RX | Channel 1 Rx Complete |
| 2 | CH1_TX | Channel 1 Tx Complete |
| 1 | CH0_RX | Channel 0 Rx Complete |
| 0 | CH0_TX | Channel 0 Tx Complete |

> DMA_Interrupt_Enable (0x100C) 位定义相同, RW 属性。

### 5.14 DMA_CHx_Control (0x1100 / 0x1180)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:18 | RSVD | RO | 0 | Reserved |
| 17:16 | DSL | RW | 0 | **Descriptor Skip Length**: 描述符间距 (0=4word/16B) |
| 15:8 | RSVD | RO | 0 | Reserved |
| 7:5 | PBL | RW | 4 | **Programmable Burst Len**: 1/2/4/8/16/32 beats |
| 4:1 | RSVD | RO | 0 | Reserved |
| 0 | RSVD | RO | 0 | Reserved |

### 5.15 DMA_CHx_Tx_Control (0x1104 / 0x1184)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:24 | RSVD | RO | 0 | Reserved |
| 23:16 | TXPBL | RW | 0 | **Tx Programmable Burst Length** |
| 15:8 | RSVD | RO | 0 | Reserved |
| 7 | RSVD | RO | 0 | Reserved |
| 6:4 | RSVD | RO | 0 | Reserved |
| 3 | OSF | RW | 0 | **Operate on Second Packet**: 1=不等状态, 提前取下一个描述符 |
| 2:1 | RSVD | RO | 0 | Reserved |
| 0 | ST | RW | 0 | **Start/Stop Transmission**: 1=启动, 0=停止 |

### 5.16 DMA_CHx_Rx_Control (0x1108 / 0x1188)

| Bits | Name | R/W | Reset | Description |
|------|------|-----|-------|-------------|
| 31:24 | RSVD | RO | 0 | Reserved |
| 23:16 | RXPBL | RW | 0 | **Rx Programmable Burst Length** |
| 15:1 | RBSZ | RW | 0 | **Receive Buffer Size**: 单个缓冲区大小 (bytes) |
| 0 | SR | RW | 0 | **Start/Stop Reception**: 1=启动, 0=停止 |

### 5.17 DMA_CHx_Status (0x1144 / 0x11C4) — RC

| Bits | Name | Description |
|------|------|-------------|
| 31:20 | RSVD | Reserved |
| 19 | TPS | **Tx Process Stopped**: 1=Tx 通道因 OWN=0 或 Tail==Current 而暂停 |
| 18 | RPS | **Rx Process Stopped**: 1=Rx 通道因 OWN=0 或 Tail==Current 而暂停 |
| 17 | TBU | **Tx Buffer Unavailable**: 1=下一个描述符 OWN=0, 无可用 Tx Buffer |
| 16 | RBU | **Rx Buffer Unavailable**: 1=下一个描述符 OWN=0, 无可用 Rx Buffer |
| 15:8 | RSVD | Reserved |
| 7 | ETI | **Early Tx Interrupt**: 非 LD 的描述符完成 + IOC=1 |
| 6 | RI | **Receive Interrupt**: Rx 包接收完成 |
| 5:4 | RSVD | Reserved |
| 3:2 | RSVD | Reserved |
| 1 | TI | **Transmit Interrupt**: Tx 包发送完成 (LD=1 + IOC=1) |
| 0 | CDE | **Chained Descriptor Error**: 描述符链错误 |

---

## 6. Descriptor Format

### 6.1 TX Descriptor (16-Byte)

#### Read Format (软件 → DMA)

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ TDES0                    Buffer 1 Address [31:0]                  │
├──────────────────────────────────────────────────────────────────┤
│ TDES1                    Buffer 2 Address [31:0]                  │
├────────────┬─────────────┬──────────────────────┬────────────────┤
│ TDES2      │ IOC │ RSVD  │  BUF2_LEN [23:16]    │ BUF1_LEN [15:0]│
│            │     │       │                      │                │
├────────────┼─────┼───────┼──────┼──────┼────────┼────────────────┤
│ TDES3      │ OWN │ RSVD  │  FD  │  LD  │  CPC   │  FRAME_LEN     │
│            │     │       │      │      │        │  [14:0]        │
└────────────┴─────┴───────┴──────┴──────┴────────┴────────────────┘
```

| Field | Bits | Description |
|-------|------|-------------|
| **BUF1ADDR** | TDES0[31:0] | Buffer 1 物理地址 (32-bit) |
| **BUF2ADDR** | TDES1[31:0] | Buffer 2 物理地址 (32-bit) |
| **IOC** | TDES2[31] | Interrupt on Completion: 1=此帧发完后产生中断 |
| **BUF2_LEN** | TDES2[23:16] | Buffer 2 有效字节数 (最大 256, 粒度 8 bytes) |
| **BUF1_LEN** | TDES2[15:0] | Buffer 1 有效字节数 (最大 65535) |
| **OWN** | TDES3[31] | 1=DMA 拥有, 0=CPU 拥有 |
| **FD** | TDES3[29] | First Descriptor: 1=包的第一个描述符 |
| **LD** | TDES3[28] | Last Descriptor: 1=包的最后一个描述符 |
| **CPC** | TDES3[27:26] | CRC Pad Control: 00=CRC+PAD, 01=仅CRC, 10=不加CRC, 11=替换CRC |
| **FRAME_LEN** | TDES3[14:0] | 包总长度 (不含 Preamble/SFD/CRC), 软件必须填写 |

#### Write-Back Format (DMA → 软件, 仅 LD=1 时)

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ TDES0                    Reserved (Timestamp Low — not used)      │
├──────────────────────────────────────────────────────────────────┤
│ TDES1                    Reserved (Timestamp High — not used)     │
├──────────────────────────────────────────────────────────────────┤
│ TDES2                    Reserved                                 │
├────┬────┬─────┬──────┬───────┬──────┬─────┬──────┬───────┬───────┤
│TDES3│OWN │RSVD │  FD  │  LD   │ DE   │ ES  │  UF  │  EC   │  RSVD │
│    │    │     │      │       │      │     │      │       │       │
└────┴────┴─────┴──────┴───────┴──────┴─────┴──────┴───────┴───────┘
```

| Field | Bits | Description |
|-------|------|-------------|
| **OWN** | [31] | DMA 写回时清零 |
| **FD** | [29] | 同 Read 格式 |
| **LD** | [28] | 同 Read 格式 |
| **DE** | [23] | Descriptor Error: 描述符内容非法 |
| **ES** | [15] | Error Summary: UF/EC 的逻辑或 |
| **UF** | [2] | Underflow Error: FIFO 欠载 |
| **EC** | [8] | Excessive Collision (半双工时, 全双工 reserved) |

### 6.2 RX Descriptor (16-Byte)

#### Read Format (软件 → DMA)

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ RDES0                    Buffer 1 Address [31:0]                  │
├──────────────────────────────────────────────────────────────────┤
│ RDES1                    Buffer 2 Address [31:0]                  │
├──────────────────────────────────────────────────────────────────┤
│ RDES2                    Reserved (软件可用来存上下文)            │
├────┬────┬────────┬──────┬───────┬────────────────────────────────┤
│RDES3│OWN │  IOC   │RSVD  │BUF2V  │ BUF1V │  RSVD                 │
│    │    │        │      │       │       │                        │
└────┴────┴────────┴──────┴───────┴───────┴────────────────────────┘
```

| Field | Bits | Description |
|-------|------|-------------|
| **BUF1ADDR** | RDES0[31:0] | Buffer 1 物理地址 |
| **BUF2ADDR** | RDES1[31:0] | Buffer 2 物理地址 |
| **OWN** | RDES3[31] | 1=DMA 拥有 (软件给 DMA 时必须设为 1) |
| **IOC** | RDES3[30] | 1=完成时发中断 |
| **BUF2V** | RDES3[25] | 1=Buffer 2 地址有效 |
| **BUF1V** | RDES3[24] | 1=Buffer 1 地址有效 |

#### Write-Back Format (DMA → 软件)

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ RDES0                    Reserved                                 │
├──────────────────────────────────────────────────────────────────┤
│ RDES1                    Extended Status (RSVD for V1.0)          │
├──────────────────────────────────────────────────────────────────┤
│ RDES2                    Filter Status  │ RSVD  │ FRAME_LEN [14:0]│
├────┬────┬─────┬──────┬───────┬──────┬──────┬──────┬───────┬──────┤
│RDES3│OWN │RSVD │  FD  │  LD   │  CE  │  OE  │  RE  │  ES   │  PL  │
│    │    │     │      │       │      │      │      │       │[14:0]│
└────┴────┴─────┴──────┴───────┴──────┴──────┴──────┴───────┴──────┘
```

| Field | Bits | Description |
|-------|------|-------------|
| **OWN** | [31] | DMA 写回时清零 |
| **FD** | [29] | First Descriptor |
| **LD** | [28] | Last Descriptor |
| **CE** | [24] | CRC Error: 帧 CRC 校验失败 |
| **OE** | [21] | Overflow Error: RX FIFO 溢出 |
| **RE** | [20] | Receive Error: gmii_rxer 有效 |
| **ES** | [15] | Error Summary: CE/OE/RE 的逻辑或 |
| **PL** | [14:0] | Packet Length: 收到的帧字节数 (含 CRC) |

**注**: V1.0 不包含 VLAN、Timestamp、L3/L4 过滤器状态。RX Write-Back 为简化版。

### 6.3 描述符环操作

```
  1. 软件分配连续内存 → Descriptor Ring
  2. 写 DMA_CHx_XXX_DESC_BASE → Ring 基地址 (32-bit aligned)
  3. 写 DMA_CHx_XXX_DESC_LEN  → Ring 中描述符数量 (N)
  4. 软件填充前 M 个描述符 (OWN=1, BUF 指向有效缓冲区)
  5. 写 DMA_CHx_XXX_DESC_TAIL → 最后一个就绪描述符的 index
  
  处理流程:
  while (DMA Active) {
      desc = ReadDesc(Base + Current * 16);
      if (desc.OWN == 0) {
          Suspend;  // 等待 Tail 推进
          continue;
      }
      ProcessPacket(desc);
      if (desc.LD) WriteBack(desc);  // 写回状态, OWN=0
      Current = (Current + 1) % Ring_Length;
  }
```

---

## 7. Interrupts

### 7.1 中断源汇总

| 中断 | 来源 | 触发条件 |
|------|------|---------|
| **DMA_CH0_TX** | DMA Ch0 Tx | LD=1 描述符发送完成 + IOC=1 |
| **DMA_CH1_TX** | DMA Ch1 Tx | LD=1 描述符发送完成 + IOC=1 |
| **DMA_CH0_RX** | DMA Ch0 Rx | LD=1 描述符接收完成 + IOC=1 |
| **DMA_CH1_RX** | DMA Ch1 Rx | LD=1 描述符接收完成 + IOC=1 |
| **MAC_TS** | MAC TX | 帧发送完成 |
| **MAC_PC** | MAC RX | 收到 Pause 帧 |
| **MAC_RO** | MAC RX | RX FIFO 溢出 |

### 7.2 中断信号

```verilog
output wire intr_o,               // 总中断输出 (OR 所有使能的中断)
output wire [7:0] intr_vector_o   // 中断向量 (每位对应一个中断源)
```

### 7.3 中断聚合 (Interrupt Coalescing)

```
  DMA_INTR_TIMER 寄存器 (0x010C):
    [15:0] ICT: Interrupt Coalescing Timer (单位: μs, 基于 hclk 计数器)
  
  原理:
    发完包后不立即产生中断
    → 启动计数器 (ICT 值 × 1μs)
    → 计数器到期前又有包完成 → 合并
    → 计数器到期 → 产生一次中断, 报告所有累积的中断状态

  目的: 高速流量下降低中断频率, 减少 CPU 上下文切换
```

---

## 8. Flow Control

### 8.1 TX Flow Control (发送 Pause)

```
  触发条件: RX FIFO 水位 ≥ RFA 阈值 (MAC_TX_FLOW_CTRL.RFA)
  
  MAC 自动发送 Pause 帧:
    DA     = 01:80:C2:00:00:01
    SA     = MAC_ADDR0 (软件配置)
    Type   = 0x8808
    Opcode = 0x0001
    Pause  = MAC_TX_FLOW_CTRL.PT [31:16]
    FCS    = 硬件 CRC

  FIFO 水位降至 RFA 以下 → 自动发送 Pause=0 (Zero-Quanta)
```

### 8.2 RX Flow Control (响应 Pause)

```
  收到 Pause 帧:
    DA = 01:80:C2:00:00:01
    Type = 0x8808
    Opcode = 0x0001
    
    MAC 自动:
    - 更新 MAC_RX_FLOW_STATUS.PT
    - Pause Time > 0:
        → 停止 TX 数据通路
        → 启动内部定时器 (Pause Time × 512 bit times)
        → 定时器到期 → 恢复 TX
    - Pause Time = 0:
        → 立即清除定时器
        → 立即恢复 TX
    
    MAC_RX_FLOW_STATUS.PR = 1 (产生中断)
```

---

## 9. Configuration Parameters

### 9.1 RTL Verilog Parameters

```verilog
module eth_mac_top #(
    // AHB Interface
    parameter P_AHB_DATA_WIDTH     = 32,    // 32 or 64
    parameter P_AHB_ADDR_WIDTH     = 32,    // 32

    // TX FIFO
    parameter P_TX_FIFO_DEPTH      = 4096,  // bytes per queue
    parameter P_TX_FIFO_QUEUES     = 2,     // number of TX queues

    // RX FIFO
    parameter P_RX_FIFO_DEPTH      = 8192,  // bytes per queue
    parameter P_RX_FIFO_QUEUES     = 2,     // number of RX queues

    // DMA
    parameter P_TX_DESC_RING_LEN   = 64,    // max descriptors per TX ring
    parameter P_RX_DESC_RING_LEN   = 64,    // max descriptors per RX ring
    parameter P_MAX_BURST_LEN      = 16,    // max AHB burst beats

    // MAC
    parameter P_MAC_ADDR_ENTRIES   = 4,     // perfect match DA entries
    parameter P_HASH_TABLE_WIDTH   = 64,    // hash filter table width
    parameter P_JUMBO_EN           = 1,     // 0=1518, 1=9018 max frame
    
    // SHELL_MODE (per coding convention)
    parameter P_SHELL_MODE         = 0      // 1=bypass mode for sim
) (
    ...
);
```

### 9.2 推荐配置 (V1.0 默认)

| 参数 | 值 | 说明 |
|------|-----|------|
| AHB 数据宽度 | 32-bit | 系统总线匹配 |
| TX FIFO 深度 | 4KB/队列 | 容纳 2.7 个最大帧 |
| RX FIFO 深度 | 8KB/队列 | 容纳 5.4 个最大帧 |
| 描述符环长 | 64 | 足够管理流量 |
| MAC 地址条目 | 4 | 支持多播/虚拟 MAC |
| Hash 表 | 64-bit | 标准组播过滤 |
| Jumbo Frame | Disabled | 标准 1518B 最大帧 |

---

## 10. Performance

### 10.1 吞吐量

```
  1 Gbps line rate = 1,000,000,000 bps
  Frame overhead per packet (minimum):
    Preamble (8B) + IFG (12B) = 20B = 160 bits
  最小帧 (64B):  64+20 = 84B = 672 bits
    Max packets/sec = 1e9 / 672 ≈ 1,488,095 pps
  最大标准帧 (1518B): 1518+20 = 1538B = 12,304 bits
    Max packets/sec = 1e9 / 12,304 ≈ 81,274 pps

  AHB 32-bit @ 100MHz:
    峰值带宽 = 400 MB/s ≫ 125 MB/s (1Gbps 线速)
    DMA burst overhead ≈ 15% → 有效 340 MB/s → margin 2.7×
```

### 10.2 延迟

| 路径 | 延迟 | 计算 |
|------|------|------|
| TX: CPU 写 Tail → 帧到线缆 | < 2 μs | DMA Desc Read(100ns) + Data Read(500ns) + FIFO(400ns) + MAC pipeline(200ns) + RGMII(80ns) |
| RX: 帧入 RGMII → DMA 写回完成 | < 2 μs | RGMII(80ns) + MAC pipeline(200ns) + FIFO(400ns) + DMA Write(500ns) + Desc Writeback(100ns) |

### 10.3 资源估算 (FPGA)

| 模块 | LUTs | FFs | BRAM |
|------|------|-----|------|
| MAC TX Pipeline | ~600 | ~400 | 0 |
| MAC RX Pipeline | ~800 | ~500 | 0 |
| CRC-32 | ~200 | ~100 | 0 |
| DMA Controller (×4) | ~1200 | ~800 | 0 |
| TX FIFO (8KB) | ~100 | ~200 | 4 × 18Kb |
| RX FIFO (16KB) | ~100 | ~200 | 8 × 18Kb |
| AHB Master+Slave | ~400 | ~300 | 0 |
| RGMII Interface | ~150 | ~200 | 0 |
| MDIO Master | ~100 | ~80 | 0 |
| Register File | ~300 | ~500 | 0 |
| **Total (est.)** | **~4,000** | **~3,300** | **~216 Kb** |

---

## 11. Initialization Sequence

```
  1. 硬件复位
     hresetn 释放, 等待 ≥ 10 hclk cycles
     gtx_resetn 释放
     rx_resetn 释放
     
  2. 配置 MAC 地址
     Write MAC_ADDR0_HIGH/LOW  ← 本端 MAC 地址
     
  3. 配置 MAC
     Write MAC_CONFIG:
       PS = 1   (1000Mbps)
       DM = 1   (Full Duplex)
       JE = 0   (Standard frames, 或 1 for Jumbo)
       TE = 0, RE = 0  (暂时不使能)
     
  4. 配置 Frame Filter
     Write MAC_FRAME_FILTER:
       RA = 0   (非 Promiscuous)
       HPF = 0  (Perfect Match)
       PMF = 0  (不过滤组播)
       PCF = 0  (不转发 Control 帧)
     
  5. 配置 Flow Control (可选)
     Write MAC_TX_FLOW_CTRL:
       TFE = 1
       RFA = 010 (75% 触发)
       PT = 0xFFFF (最大暂停时间)
     Write MAC_RX_FLOW_CTRL:
       RFE = 1
     
  6. 配置 DMA
     Write DMA_CH0_TX_DESC_BASE → Tx Ring 0 基地址
     Write DMA_CH0_TX_DESC_LEN  → 64
     Write DMA_CH0_RX_DESC_BASE → Rx Ring 0 基地址
     Write DMA_CH0_RX_DESC_LEN  → 64
     (同样配置 Channel 1)
     
  7. 准备描述符
     软件填充 RX Ring: OWN=1, BUF1/BUF2 指向有效缓冲区
     写 Rx Tail Pointer
     
  8. 启动 DMA
     Write DMA_CH0_RX_CTRL: SR=1
     Write DMA_CH1_RX_CTRL: SR=1
     
  9. 使能 MAC
     Write MAC_CONFIG: TE=1, RE=1
     
  10. 启动 TX DMA (开始发送)
     Write DMA_CH0_TX_CTRL: ST=1
     Write DMA_CH1_TX_CTRL: ST=1
     
  11. 软件填充 TX Ring, 写 Tx Tail → 开始发送
```

---

## 12. 文件组织 (RTL Implementation)

```
rtl/
├── eth_mac_top.v              # 顶层集成
├── ahb/
│   ├── ahb_slave_if.v         # AHB Slave (CSR)
│   └── ahb_master_if.v        # AHB Master (DMA)
├── dma/
│   ├── dma_controller.v       # DMA 顶层
│   ├── dma_tx_channel.v       # TX 通道
│   ├── dma_rx_channel.v       # RX 通道
│   ├── dma_arbiter.v          # 通道仲裁
│   └── dma_intr_ctrl.v        # 中断控制
├── mtl/                        # MTL — MAC Transaction Layer
│   ├── mtl_top.v              # MTL 顶层
│   ├── mtl_tx.v               # Tx Queues + Scheduler
│   ├── mtl_rx.v               # Rx Queues + Router
│   ├── mtl_flow.v             # 流控水位检测
│   ├── async_fifo.v           # 通用异步 FIFO (Gray-code)
│   └── mtl_arbiter.v          # Queue 调度仲裁
├── mac/
│   ├── mac_core.v             # MAC 顶层
│   ├── mac_tx.v               # TX Pipeline (TBU+TPC+TPE)
│   ├── mac_rx.v               # RX Pipeline (RxMAC+CRC+RPC+RBI)
│   ├── crc32.v                # CRC-32 生成/校验
│   ├── addr_filter.v          # 地址过滤器
│   └── flow_control.v         # IEEE 802.3x 流控
├── rgmii/
│   └── rgmii_if.v             # RGMII DDR 接口
├── mdio/
│   └── mdio_master.v          # MDIO Clause 22
└── std_cell/
    ├── agdc_clk_gate.v        # 时钟门控
    └── sync_2ff.v             # 双触发器同步器
```
