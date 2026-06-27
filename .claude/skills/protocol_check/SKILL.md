---
name: protocol-check
description: 严格检查 RTL 代码中的标准协议逻辑是否符合协议规范（AHB/APB/AXI/RGMII/GMII/Handshake），逐信号逐相位比对
triggers:
  - 协议检查
  - 协议符合
  - 协议合规
  - protocol check
  - AHB检查
  - AXI检查
  - RGMII检查
---

# Protocol Check — 标准协议合规性严格检查

对 RTL 中的标准协议接口进行逐信号、逐相位检查。不匹配时报告具体违规条款和修复建议。

## 覆盖协议

| 协议 | 版本 | 检查范围 |
|------|------|---------|
| AMBA AHB | 2.0 | Master / Slave 完整信号时序 |
| AMBA APB | 2.0/3.0 | Master / Slave 状态机 |
| AMBA AXI | 3.0/4.0 | Read/Write channels, handshake |
| RGMII | v2.6 | TX/RX DDR timing, skew |
| GMII/MII | 802.3 | TX/RX SDR timing |
| Valid/Ready | 通用 | 反压、数据丢弃、FIFO 行为 |

---

## AMBA AHB 2.0

### AHB Slave — 逐信号检查

```
信号        规则                                                                  违规级别
─────────────────────────────────────────────────────────────────────────────────────────
HREADY       复位后必须 =1；Wait state 时 =0，最长 16 周期                  Error
HRESP        仅允许 OKAY(0)/ERROR(1)；禁止不支持的 RETRY/SPLIT              Error
HWDATA       仅在 Phase 2（数据周期）采样；禁止在 Phase 1 锁存               Error
HADDR        在 Phase 1（地址周期）锁存，HREADY=1 时有效                     Warning
HSIZE        检查是否匹配寄存器位宽；不匹配 → ERROR 或忽略                    Warning
HBURST       不支持的类型 → ERROR；INCR 不跨 1KB 边界                        Error
HTRANS       BUSY(01) 不启动新传输；IDLE(00) 时不做任何操作                  Warning
HREADYOUT    不可组合逻辑直接输出，必须寄存                                    Info
```

### AHB Master — 逐信号检查

```
信号        规则                                                                  违规级别
─────────────────────────────────────────────────────────────────────────────────────────
HTRANS       空闲=IDLE(00)；首 beat=NONSEQ(10)；后续=SEQ(11)                  Error
HADDR        仅在 HREADY=1 时更新地址                                           Error
HPROT        AMBA 2.0 要求必须驱动；默认=4'b0011                                Error
HWDATA       对于写操作，每 beat 必须更新数据                                    Error
HBURST       INCR 不能跨 1KB 边界；不支持 WRAP 则不使用                          Error
HSIZE        保持与实际数据宽度一致                                               Warning
HREADY       采样: Slave de-assert HREADY → Master 必须等待                      Error
HRESP        ERROR → 终止 burst；RETRY/SPLIT → 重试或放弃                       Error
```

### AHB 时序检查

```
检查项                                                       违规级别
─────────────────────────────────────────────────────────────────────
Phase 1(Addr) 与 Phase 2(Data) 是流水线关系，非同一周期            Error
Slave 在 Phase 1 捕获地址，Phase 2 输出数据                         Error
Master 在 Phase 1 驱动地址，Phase 2 采样数据                        Error
HREADY=1 时，地址+数据同时生效                                      Error
HREADY=0 时，所有信号必须保持; Master 不能更新地址                   Error
```

---

## AMBA APB

```
检查项                                                       违规级别
─────────────────────────────────────────────────────────────────────
PSEL=1/PENABLE=1 同时有效时 PREADY=1 才能完成传输 (APB3+)         Error
PENABLE 在 PSEL 之后一个周期才置位                                  Error
PWRITE/PADDR 在 PSEL 置位后不能再变化                               Error
写数据 PWDATA 必须在 PENABLE 周期有效                               Warning
APB2: 无 PREADY, 固定 2 周期                                      Info
```

---

## RGMII v2.6

```
检查项                                                       违规级别
─────────────────────────────────────────────────────────────────────
TXC: 125MHz, MAC 驱动 (输出), 占空比 45~55%                       Error
TXD[3:0]: DDR, 上升沿发低 4-bit, 下降沿发高 4-bit                  Error
TX_CTL: DDR, 上升沿=TX_EN, 下降沿=TX_EN^TX_ER                      Error
RXC: 125MHz, PHY 驱动 (输入), 占空比 45~55%                        Error
RXD[3:0]: DDR, 上升沿采低 4-bit, 下降沿采高 4-bit                  Error
RX_CTL: DDR, 上升沿=RX_DV, 下降沿=RX_DV^RX_ER                      Error
TXC→TXD skew: ≤ 2.0ns, MAC 内部延时 ~1.5-2ns                       Warning
RXC→RXD: PHY 侧已做中心对齐，MAC 直接采样                          Info
禁止直接用 clk 电平做 DDR mux (必须用 ODDR 原语)                    Error
IDLE 期间 TX_CTL=0, TXD=0                                           Warning
```

---

## Valid/Ready Handshake

```
检查项                                                       违规级别
─────────────────────────────────────────────────────────────────────
VALID 不能依赖 READY 来置位 (VALID→READY, 不是 READY→VALID)        Error
READY 可以依赖 VALID (READY=1 时若 VALID=1 则握手完成)              Info
VALID=1 且 READY=1 → 握手成功, 数据已传输                            Error
VALID=1 且 READY=0 → 必须保持 VALID 和数据, 不能丢弃                Error
VALID=0 时数据无效, Master 可任意改变                                 Warning
接口输出必须寄存 (IP boundary rule)                                  Warning
```

---

## 检查流程

```
Step 1: 读取 RTL, grep 识别协议信号名
        hsel/haddr/htrans → AHB Slave
        hm_addr/hm_write → AHB Master
        rgmii_txc/rgmii_rxd → RGMII
        valid+ready 成对 → Handshake

Step 2: 逐信号检查
        - 是否按协议定义的方向 (input/output)?
        - 位宽是否匹配?
        - 是否有时序违规 (Phase 1 vs Phase 2)?

Step 3: 时序检查
        - AHB: 地址→数据是流水线, hready 控制等周期
        - RGMII: DDR 上下沿数据对应关系
        - Handshake: VALID 不能等 READY

Step 4: 报告
        - [PROTO-ERR-xxx] 违规项
        - 协议条款引用
        - 修复建议代码
```

---

## 报告模板

```markdown
# Protocol Compliance Check Report

## Summary
| Protocol | Interface | Error | Warning | Info |
|----------|----------|:-----:|:-------:|:----:|
| AHB 2.0  | Slave    | 0     | 0       | 1    |
| AHB 2.0  | Master   | 1     | 0       | 0    |
| RGMII    | PHY IF   | 0     | 2       | 0    |

## Violations

### [PROTO-ERR-AHB-001] HWDATA sampled in Phase 1
- File: ahb_slave_if.v:96
- Protocol: AMBA 2.0 §3.2 — HWDATA valid only in data phase
- Code: `wdata_reg <= hwdata;` inside Phase 1 always block
- Fix: Move hwdata capture to a separate always block triggered in Phase 2,
  or use combinational pass-through: `assign reg_wr_data = hwdata;`

### [PROTO-ERR-AHB-002] HPROT not driven
- File: ahb_master_if.v:44
- Protocol: AMBA 2.0 §4.1 — HPROT must be driven by master
- Code: missing port declaration
- Fix: Add `output wire [3:0] hprot_o` and assign `4'h3`
```
