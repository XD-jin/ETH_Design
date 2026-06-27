---
name: consistency-check
description: 检查 RTL 代码与设计规格文档的一致性（寄存器、接口、功能、时钟复位），报告不匹配项
triggers:
  - 规格一致性
  - 一致性检查
  - spec check
  - consistency check
  - RTL vs spec
---

# Consistency Check — RTL 与设计规格一致性检查

将 RTL 代码与设计规格文档进行对照，逐项检查一致性。输出不匹配清单和修复建议。

## 输入

- RTL 代码文件（.v / .sv，路径或目录）
- 设计规格文档（Markdown / JSON）
- 配置参数（可选）

## 输出

- 一致性报告（Markdown）
- 不匹配清单：Register / Interface / Feature / Clock-Reset 四类
- 修复建议

## 检查维度

### 1. 寄存器一致性 (Register)

检查 RTL 中的 `parameter` 和寄存器位域是否与规格文档中的 Register Map 一致。

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 寄存器地址匹配 | 每个 CSR 寄存器在 RTL 地址译码中都有对应项 | Error |
| 位域定义一致 | 字段名称、位宽、复位值与规格匹配 | Error |
| 读写属性一致 | RO / RW / RC / W1C 等与规格一致 | Warning |
| 保留位处理 | RSVD 位是否可读写（应为 RO 或硬件忽略） | Info |

**检查方法**：
1. 读取 Spec 中的 Register Map 表
2. 在 RTL 中 grep 对应的 `localparam ADDR_xxx` 或 case 语句
3. 逐寄存器对比 Base Address、Offset、Bit fields

### 2. 接口一致性 (Interface)

检查 RTL 模块的端口定义是否与规格文档中的接口描述一致。

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 端口名称匹配 | RTL port 名与 Spec 中的信号名一致（允许 `_i`/`_o` 后缀差异） | Error |
| 端口方向匹配 | input/output/inout 与 Spec 一致 | Error |
| 端口位宽匹配 | 位宽与 Spec 一致（Spec 中的 `[N:0]` vs RTL 中的实际值） | Error |
| 缺少端口 | Spec 中定义了但 RTL 中不存在的端口 | Error |
| 多余端口 | RTL 中存在但 Spec 中未定义的额外端口 | Warning |

**检查方法**：
1. 从 Spec 的界面描述章节提取信号表
2. 解析 RTL 的 `module ... (input/output ...)` 端口声明
3. 两边做 diff

### 3. 功能特性一致性 (Feature)

检查 Spec 中声明的功能是否在 RTL 中实现，以及 RTL 中的实现是否符合 Spec 描述。

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 声明功能缺失 | Spec Feature List 中的功能在 RTL 中找不到对应逻辑 | Error |
| 未声明功能存在 | RTL 中有但 Spec 中没有文档化的功能 | Warning |
| 状态机一致 | RTL FSM 状态数与 Spec 状态图一致 | Warning |
| 中断源一致 | RTL 中断源数量/编号与 Spec 中断表一致 | Error |
| Parameter 一致 | RTL parameter 的默认值与 Spec 推荐值一致 | Warning |

**检查方法**：
1. 从 Spec 的 Features 列表提取功能清单
2. 在 RTL 中搜索对应模块、FSM 状态、中断信号
3. 确认每个功能的实现完整性

### 4. 时钟复位一致性 (Clock & Reset)

检查 RTL 中的时钟域划分和复位策略是否与 Spec 中的 Clock & Reset 章节一致。

| 检查项 | 说明 | 级别 |
|--------|------|------|
| 时钟域数量 | RTL 中实际使用的时钟信号数与 Spec 的 Clock Domains 表一致 | Error |
| 时钟源一致 | 每个模块的时钟源与 Spec 描述一致 | Warning |
| 复位类型一致 | 异步/同步、高/低有效与 Spec 声明一致 | Error |
| CDC 策略一致 | 跨域路径的同步方法与 Spec 的 CDC 策略一致 | Error |
| SHELL_MODE 存在 | 每个模块是否有 P_SHELL_MODE 参数 | Info |

**检查方法**：
1. 从 Spec 的 Clock Domains 表和 CDC 策略提取时钟规划
2. 在 RTL 中 grep `input.*clk` 和 `always @(posedge`
3. 检查 async_fifo / sync_2ff 等 CDC 模块的实例位置

---

## 执行流程

### Step 1: 定位规格文档

在 `doc/` 目录中搜索规格文档（Markdown / JSON）：

```
默认搜索: doc/ETH_MAC_IP_Specification.md
备选: doc/*spec*.md, doc/*Specification*.md
```

### Step 2: 提取规格信息

从规格文档中提取：
- **Register Map**: 寄存器名称、偏移、位域表
- **Interface Signals**: 顶层接口信号表（名称、方向、位宽）
- **Feature List**: 功能特性清单
- **Clock/Reset**: 时钟域表和 CDC 策略

### Step 3: 扫描 RTL 代码

从 RTL 代码中提取：
- **Parameters & Localparams**: 寄存器地址定义、位宽参数
- **Module Ports**: 每个模块的端口声明
- **FSM States**: 状态机状态编码
- **Clock/Reset Signals**: 时钟和复位信号列表

### Step 4: 逐项对比

四维度的每一项逐一对比，生成不匹配清单。

### Step 5: 生成报告

输出 Markdown 格式的一致性检查报告。

---

## 报告模板

```markdown
# RTL-Spec 一致性检查报告

## 基本信息
- 规格文档: xxx.md
- RTL 目录: rtl/
- 检查日期: YYYY-MM-DD
- 模块数量: N

## 汇总

| 维度 | 匹配 | 不匹配 | Error | Warning | Info |
|------|------|--------|-------|---------|------|
| 寄存器 | -- | -- | -- | -- | -- |
| 接口 | -- | -- | -- | -- | -- |
| 功能 | -- | -- | -- | -- | -- |
| 时钟复位 | -- | -- | -- | -- | -- |
| **总计** | -- | -- | -- | -- | -- |

## 不匹配详情

### [ERR-C01] 寄存器地址缺失
- Spec 定义: MAC_Configuration @ 0x0000
- RTL 实际: 未找到地址译码
- 建议: 在 ahb_slave_if 或 register file 中添加 0x0000 的 case

## 修复优先级
1. Error — 必须修复（功能缺陷）
2. Warning — 建议修复（文档/实现不一致）
3. Info — 可选（优化建议）
```

---

## 与其他 Skill 配合

```
Spec 文档
    │
    ├── rtl-generator ──► RTL 代码
    │
    └── consistency_check ──► 检查 RTL vs Spec
            │
            ▼
        rtl-reviewer ──► 综合评审报告
```

当 `rtl-reviewer` 检测到设计规格引用时，自动调用 `consistency_check`。
