---
name: consistency-check
description: 检查 RTL 内部一致性（端口/连线/参数）以及 RTL 与设计规格文档的一致性（寄存器/接口/功能/时钟复位），报告不匹配项
triggers:
  - 规格一致性
  - 端口检查
  - 一致性检查
  - spec check
  - consistency check
  - RTL vs spec
  - 连线检查
  - 参数检查
---

# Consistency Check — RTL 内部一致性 & 规格一致性检查

两层检查：
1. **RTL 内部一致性** — 模块间端口连接、位宽匹配、参数默认值
2. **外部规格一致性** — RTL vs 设计文档（寄存器/接口/功能/时钟复位）

## 输入

- RTL 代码文件（.v / .sv，路径或目录）
- 设计规格文档（Markdown / JSON，可选）
- spec-parser 输出的 JSON（可选）

## 输出

- 一致性报告（Markdown）
- 不匹配清单：Internal / Register / Interface / Feature / Clock-Reset 五类
- 修复建议

---

## 维度 A: RTL 内部一致性 (Internal)

### A1. 端口声明一致性

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 端口方向匹配 | output 端口不能连接到另一个 output；input 不能连接到 input（同名对接时方向相反） | Error |
| 端口位宽匹配 | 连接的双方端口位宽必须一致（允许 `[N:0]` ↔ `[N:0]`，禁止 `[7:0]` → `[3:0]`） | Error |
| 端口类型匹配 | wire 连接到 reg 时，源端必须是 reg 或 wire（target 端不做限制） | Error |
| 悬空输入 | input 端口不能长期悬空（必须由顶层或内部逻辑驱动） | Warning |
| 未用输出 | output 端口未连接时应使用 `.port()` 留空，禁止声明 `_nc` 信号 | Info |

### A2. 连线正确性

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 单驱动原则 | 每个 wire/reg 信号只能有一个驱动源（禁止多个 always 块或 assign 驱动同一信号） | Error |
| 命名端口连接 | 实例化必须使用 `.port_name(signal)` 命名连接，禁止位置连接 | Error |
| 位宽截断 | 宽信号连到窄端口时，高位被截断（工具 Warning，需显式处理） | Warning |
| 跨域信号有同步器 | 跨越不同 `clk` 域的控制信号必须有 2-FF 同步器或 async_fifo | Error |
| 内部生成时钟 | 禁止用寄存器输出作为时钟（`assign clk_out = reg_signal`），必须使用 PLL 或 clk_gate 原语 | Error |

### A3. 参数一致性

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 参数传递完整 | 顶层 parameter 值是否传递到所有依赖该参数的子模块 | Warning |
| 默认值一致 | 同一 parameter 在多个模块中的默认值是否一致 | Warning |
| 参数位宽推导 | `localparam` 中位宽表达式推导结果是否与实例化端口位宽匹配 | Error |

---

## 维度 B: 寄存器一致性 (Register) — RTL vs Spec

检查 RTL 中的 register file 与规格文档中的 Register Map 一致。

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 寄存器地址匹配 | 每个 CSR 寄存器在 RTL 地址译码中都有对应项 | Error |
| 位域定义一致 | 字段名称、位宽、复位值与规格匹配 | Error |
| 读写属性一致 | RO / RW / RC / W1C 等与规格一致 | Warning |
| 保留位处理 | RSVD 位是否可读写（应为 RO 或硬件忽略） | Info |

## 维度 C: 接口一致性 (Interface) — RTL vs Spec

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 端口名称匹配 | RTL port 名与 Spec 中的信号名一致（允许 `_i`/`_o`/`_in`/`_out` 后缀差异） | Error |
| 端口方向匹配 | input/output/inout 与 Spec 一致 | Error |
| 端口位宽匹配 | 位宽与 Spec 一致 | Error |
| 缺少端口 | Spec 中定义了但 RTL 中不存在的端口 | Error |
| 多余端口 | RTL 中存在但 Spec 中未定义的额外端口 | Warning |
| 协议信号完整 | AHB/AXI/APB 等标准协议信号是否完整（如 AHB 必须有 hready/hresp） | Error |

## 维度 D: 功能特性一致性 (Feature) — RTL vs Spec

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 声明功能缺失 | Spec Feature List 中的功能在 RTL 中找不到对应逻辑 | Error |
| 未声明功能存在 | RTL 中有但 Spec 中没有文档化的功能 | Warning |
| 状态机一致 | RTL FSM 状态数与 Spec 状态图一致 | Warning |
| 中断源一致 | RTL 中断源数量/编号与 Spec 中断表一致 | Error |
| Parameter 一致 | RTL parameter 的默认值与 Spec 推荐值一致 | Warning |

## 维度 E: 时钟复位一致性 (Clock & Reset) — RTL vs Spec

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 时钟域数量 | RTL 中实际使用的时钟信号数与 Spec 的 Clock Domains 表一致 | Error |
| 时钟源一致 | 每个模块的时钟源与 Spec 描述一致 | Warning |
| 复位类型一致 | 异步/同步、高/低有效与 Spec 声明一致 | Error |
| CDC 策略一致 | 跨域路径的同步方法与 Spec 的 CDC 策略一致 | Error |
| SHELL_MODE 存在 | 每个模块是否有 P_SHELL_MODE 参数 | Info |

---

## 执行流程

### Step 1: 收集输入

- 扫描 `rtl/` 目录收集所有 `.v` / `.sv` 文件
- 若提供规格文档，搜索 `doc/` 目录（默认: `ETH_MAC_IP_Specification.md`）
- 若有 spec-parser JSON 输出，优先使用其结构化数据

### Step 2: 内部一致性检查

解析每个模块的端口声明和实例化连接：
1. 建立模块端口数据库（名称、方向、位宽、类型）
2. 追踪顶层端口 → 子模块端口 → 内部信号的连接链
3. 检查位宽匹配、方向匹配、单驱动、跨域同步

### Step 3: 外部规格检查（有 Spec 时）

1. **Register Map** → RTL 地址译码对比
2. **Interface Signals** → 端口名/方向/位宽 diff
3. **Feature List** → RTL 模块/FSM/中断 grep 确认
4. **Clock/Reset** → 时钟域、CDC 策略对比

### Step 4: 生成报告

五维度不匹配清单 + 修复建议。

---

## 示例输出

### Pass 示例 — 位宽/方向匹配

```
✅ ETH_MAC_TOP.u_mtl_tx.ati_data[31:0] ← DMA_CONTROLLER.ati_data[31:0]
   Direction: DMA output → MTL input  OK
   Width: 32-bit = 32-bit  OK
```

### Fail 示例 — 缺失连接

```
❌ [ERR-C03] MTL_RX 模块端口未连接
   Port: rx_overflow → top-level wire rx_overflow_sts
   状态: 端口留空 .rx_overflow()
   影响: MTL_RxQ_Missed_Pkt 寄存器始终读回 0
   修复: .rx_overflow(rx_overflow_sts)
```

---

## 报告模板

```markdown
# Consistency Check Report

## Summary

| Dimension | Error | Warning | Info |
|-----------|-------|---------|------|
| Internal: Port Decl | -- | -- | -- |
| Internal: Connection | -- | -- | -- |
| Internal: Parameter | -- | -- | -- |
| Spec: Register | -- | -- | -- |
| Spec: Interface | -- | -- | -- |
| Spec: Feature | -- | -- | -- |
| Spec: Clock/Reset | -- | -- | -- |
| **Total** | -- | -- | -- |

## Issue Details

### [ERR-I01] 位宽不匹配
- 位置: top.v:156
- 源: fifo.data_out[7:0] → 目标: mac.data_in[15:0]
- 修复: 补齐高位或截断

### [ERR-C01] 寄存器地址缺失
- Spec: MAC_Configuration @ 0x0000
- RTL: 未找到译码
- 修复: 添加 case 分支

## Priority
1. Error — 必须修复
2. Warning — 建议修复
3. Info — 可选
```

---

## 与其他 Skill 配合

```
Spec 文档
    │
    ├── spec_parser ──► JSON ──► rtl-generator ──► RTL
    │
    └── consistency_check ──► Internal + External 一致性报告
            │
            ▼
        rtl-reviewer ──► 综合评审报告 (合并一致性结果)
```

当 `rtl-reviewer` 检测到设计规格引用时，自动调用 `consistency_check`。
