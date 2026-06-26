# Synopsys DWC_ether_qos 描述符格式详解

> 基于 DWC_ether_qos Databook v5.10a, Chapter 19
> 所有描述符均为 **16 字节 (128-bit)**，在 32-bit 系统中按 4 个 32-bit word 排列 (DES0~DES3)

---

## 一、TX 发送描述符

DMA 至少需要一个描述符来发送一个数据包。支持两种类型：

| 类型 | CTXT bit (TDES3[30]) | 用途 |
|------|----------------------|------|
| **Normal Descriptor** | `0` | 指向数据缓冲区和包控制信息 |
| **Context Descriptor** | `1` | 提供 VLAN Tag、MSS、One-step Timestamp 等全局控制信息 |

### 1.1 TX Normal Descriptor — 读格式 (Read Format)

软件准备好描述符后交给 DMA 读取的格式。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ TDES0            Header or Buffer 1 Address[31:0]                │
├──────────────────────────────────────────────────────────────────┤
│ TDES1            Buffer 2 Address[31:0] or Buf1 Addr[63:32]      │
├────────────────┬─────┬──────────────────┬───────┬────────────────┤
│ TDES2          │IOC  │TTSE  │B2L[29:16] │VTIR   │HL or B1L[13:0]│
│                │     │      │            │[15:14]│                │
├────────────────┼─────┼──────┼────────────┼───────┼────────────────┤
│ TDES3  │OWN│CTXT│FD│LD│CPC │SAIC │SLOTNUM  │TSE│CIC/TPL│FL/TPL   │
│        │   │    │  │  │    │     │/THL[22:19]│   │[17:16]│[14:0]   │
└────────┴───┴────┴──┴──┴────┴─────┴───────────┴───┴───────┴────────┘
```

#### TDES0 — Buffer 1 地址指针

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **BUF1AP** | Buffer 1 物理地址。当 TSE=1 且 FD=1 时，指向 TSO Header 地址 |

#### TDES1 — Buffer 2 地址指针

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **BUF2AP** | Buffer 2 物理地址。在 40/48-bit 地址模式下，存放 Buffer 1 地址的高 8/16 位 |

#### TDES2 — 控制字 1

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **IOC** | **Interrupt on Completion** — 完成时产生中断。LD=0 时置 ETI 位，LD=1 时置 TI 位 |
| `[30]` | **TTSE** | **Transmit Timestamp Enable** — 使能该包的 IEEE 1588 时间戳。TSE=1 时变为 TMWD (禁止外部 TSO Memory 写) |
| `[29:16]` | **B2L** | **Buffer 2 Length** — 驱动设置，指示 Buffer 2 的有效字节长度 |
| `[15:14]` | **VTIR** | **VLAN Tag Insertion or Replacement** |

VTIR 编码：

| 值 | 操作 |
|----|------|
| `00` | 不添加 VLAN Tag |
| `01` | **删除** VLAN Tag（仅 VLAN 帧） |
| `10` | **插入** VLAN Tag（值来自 MAC_VLAN_Incl 寄存器或 Context Descriptor） |
| `11` | **替换** VLAN Tag（仅 VLAN 帧） |

| Bits | 名称 | 描述 |
|------|------|------|
| `[13:0]` | **HL/B1L** | **Header Length** (TSE=1 时): 从 SA 到 TCP Header 末尾的字节数，最大 1023 字节。**Buffer 1 Length** (TSE=0 时) |

#### TDES3 — 控制字 2

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **OWN** | **Own Bit** — `1`=DMA 拥有，`0`=软件拥有。DMA 传输完成后清零 |
| `[30]` | **CTXT** | **Context Type** — Normal Descriptor 必须为 `0` |
| `[29]` | **FD** | **First Descriptor** — `1`=此缓冲区包含包的第一个分段 |
| `[28]` | **LD** | **Last Descriptor** — `1`=此缓冲区包含包的最后一个分段。B1L/B2L 必须非零 |
| `[27:26]` | **CPC** | **CRC Pad Control** |

CPC 编码：

| 值 | 操作 |
|----|------|
| `00` | **CRC + PAD**: ≥60 字节追加 CRC；<60 字节自动追加 PAD + CRC |
| `01` | **仅 CRC**: 追加 CRC，不追加 PAD（软件确保 ≥60 字节） |
| `10` | **禁用 CRC**: 不追加 CRC（软件确保 PAD+CRC 在数据中） |
| `11` | **CRC 替换**: 用重算的 CRC 替换最后 4 字节 |

| Bits | 名称 | 描述 |
|------|------|------|
| `[25:23]` | **SAIC** | **SA Insertion Control** |

SAIC 编码：

| Bit[25] | Bits[24:23] | 操作 |
|---------|-------------|------|
| 0/1 | `00` | 不修改 SA |
| 选择 MAC Addr Reg | `01` | **插入** SA（帧必须不含 SA） |
| 选择 MAC Addr Reg | `10` | **替换** SA（帧必须含 SA） |
| — | `11` | Reserved |

| Bits | 名称 | 描述 |
|------|------|------|
| `[22:19]` | **SLOTNUM/THL** | AV 模式: Slot Number；TSO 模式: TCP/UDP Header Length (最小 5 for TCP, 2 for UDP) |
| `[18]` | **TSE** | **TCP Segmentation Enable** — `1`=启用 TSO/UFO |
| `[17:16]` | **CIC/TPL** | **Checksum Insertion Control**（TSE=0 时）/ TCP Payload Length[17:16]（TSE=1 时） |

CIC 编码 (TSE=0)：

| 值 | 操作 |
|----|------|
| `00` | Checksum 插入禁用 |
| `01` | 仅 IP Header Checksum |
| `10` | IP Header + Payload Checksum (无伪头) |
| `11` | IP Header + Payload Checksum (含伪头，完整卸载) |

| Bits | 名称 | 描述 |
|------|------|------|
| `[15]` | **TPL** | TSE=0 时 Reserved；TSE=1 时 TCP Payload Length[15] |
| `[14:0]` | **FL/TPL** | **Frame Length** (TSE=0 时): 总包长（不含 Preamble/SFD）；**TCP Payload Length[14:0]** (TSE=1 时) |

---

### 1.2 TX Normal Descriptor — 写回格式 (Write-Back Format)

DMA 在发送完成后的**最后一个描述符** (LD=1) 中写入此格式。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ TDES0                   Timestamp Low[31:0]                      │
├──────────────────────────────────────────────────────────────────┤
│ TDES1                   Timestamp High[31:0]                     │
├──────────────────────────────────────────────────────────────────┤
│ TDES2                   Reserved[31:0]                           │
├────┬────┬──┬──┬─────┬────┬──┬──┬──┬──┬──┬──┬──┬──┬────┬──┬──┬──┤
│TDES3│OWN│CT│FD│LD│Rsvd │TTSS│EU│ES│JT│FF│PC│Lo│NC│LC│EC │CC│ED│UF│
│    │   │XT│  │  │     │    │E │  │  │  │E │C │  │  │   │   │  │  │
├────┴────┴──┴──┴──┴─────┴────┼──┼──┼──┼──┼──┼──┼──┼──┼───┼──┼──┼──┤
│TDES3 (续)   │DB│IHE│
└─────────────┴──┴───┘
```

#### TDES0 — Timestamp Low

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **TTSL** | 发送时间戳低 32 位。仅当 TTSE=1 且 TTSS=1 时有效 |

#### TDES1 — Timestamp High

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **TTSH** | 发送时间戳高 32 位 |

#### TDES2 — Reserved

| Bits | 描述 |
|------|------|
| `[31:0]` | Reserved |

#### TDES3 — 状态字

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **OWN** | DMA 完成后清零 |
| `[30]` | **CTXT** | Normal 描述符 = `0` |
| `[29]` | **FD** | 第一分段标记 |
| `[28]` | **LD** | 最后分段标记，DMA 仅在 LD=1 的描述符中写状态 |
| `[27:24]` | Rsvd | Reserved |
| `[23]` | **DE** | **Descriptor Error** — 描述符内容错误（顺序错 / 全1 / CTXT+LD+FD 同时为1） |
| `[22:18]` | Rsvd | Reserved |
| `[17]` | **TTSS** | **Tx Timestamp Status** — `1`=已捕获时间戳，TDES0/1 有效 |
| `[16]` | **EUE** | **ECC Uncorrectable Error** — TSO Memory ECC 不可纠正错误 |
| `[15]` | **ES** | **Error Summary** — 以下错误位的逻辑或：IHE, JT, FF, PCE, LoC, NC, LC, EC, ED, UF, EUE |
| `[14]` | **JT** | **Jabber Timeout** — 发送器 jabber 超时 |
| `[13]` | **FF** | **Packet Flushed** — 软件 flush 命令导致丢包 |
| `[12]` | **PCE** | **Payload Checksum Error** — Checksum Offload 失败（字节不足/Bus Error/MTL 提前转发） |
| `[11]` | **LoC** | **Loss of Carrier** — 半双工模式下发送期间载波丢失 |
| `[10]` | **NC** | **No Carrier** — 发送时 PHY 未检测到载波 |
| `[9]` | **LC** | **Late Collision** — 碰撞窗口（64/512 字节）后的碰撞 |
| `[8]` | **EC** | **Excessive Collision** — 16 次连续碰撞后中止（DR=1 时首次碰撞即中止） |
| `[7:4]` | **CC** | **Collision Count** — 成功发送前经历的碰撞次数（EC=1 时无效） |
| `[3]` | **ED** | **Excessive Deferral** — 超过 24,288 bit times 延迟 |
| `[2]` | **UF** | **Underflow Error** — 数据从系统内存到达太晚，MAC 中止发送 |
| `[1]` | **DB** | **Deferred Bit** — 因载波存在而推迟发送（仅半双工） |
| `[0]` | **IHE** | **IP Header Error** — Checksum Offload 检测到 IP 头错误。全双工+EST 时也表示帧丢弃 |

---

### 1.3 TX Context Descriptor

在 Normal Descriptor 之前发送，提供全局控制信息（VLAN Tag、MSS、One-step Timestamp）。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ TDES0                   Timestamp Low[31:0]                      │
├──────────────────────────────────────────────────────────────────┤
│ TDES1                   Timestamp High[31:0]                     │
├──────────────────────┬─────┬─────────────────────────────────────┤
│ TDES2  │IVT[31:16]   │Rsvd │MSS[13:0]                            │
│        │             │[15: │                                    │
│        │             │14]  │                                    │
├────────┼────┬────────┼─────┼────┬──────┬──┬────┬────┬─────┬──────┤
│ TDES3  │OWN │CTXT=1  │Rsvd │OSTC│TCMSSV│  │ DE │Rsvd│IVTIR│IVLTV │
│        │    │        │     │    │      │  │    │    │     │      │
├────────┴────┴────────┴─────┴────┴──────┴──┴────┴────┼────┴──────┤
│ TDES3 (续)  │VLTV│VT[15:0]                          │
└─────────────┴────┴───────────────────────────────────┘
```

#### TDES0 / TDES1 — 时间戳

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **TTSL** | One-step 时间戳校正低 32 位。仅在 OSTC=1 且 TCMSSV=1 时有效 |
| `[31:0]` | **TTSH** | One-step 时间戳校正高 32 位 |

#### TDES2 — VLAN / MSS

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:16]` | **IVT** | **Inner VLAN Tag** — 后续包的内层 VLAN Tag。IVLTV=1 且 OSTC=0 且 TCMSSV=0 时有效 |
| `[15:14]` | Rsvd | Reserved |
| `[13:0]` | **MSS** | **Maximum Segment Size** — TSO 分段大小。TCMSSV=1 且 OSTC=0 时有效 |

#### TDES3 — 控制

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **OWN** | DMA 读取后立即清零 |
| `[30]` | **CTXT** | Context Descriptor = `1` |
| `[29:28]` | Rsvd | Reserved |
| `[27]` | **OSTC** | **One-Step Timestamp Correction Enable** |
| `[26]` | **TCMSSV** | OSTC=1 时: Timestamp 有效；OSTC=0 时: MSS 有效 |
| `[25:24]` | Rsvd | Reserved |
| `[23]` | **DE** | **Descriptor Error** |
| `[22:20]` | Rsvd | Reserved |
| `[19:18]` | **IVTIR** | **Inner VLAN Tag Insert or Replace** — 编码同 VTIR (见 §1.1 TDES2[15:14]) |
| `[17]` | **IVLTV** | **Inner VLAN Tag Valid** — `1`=TDES2 中 IVT 字段有效 |
| `[16]` | **VLTV** | **VLAN Tag Valid** — `1`=TDES3 中 VT 字段有效 |
| `[15:0]` | **VT** | **VLAN Tag** — 要插入/替换的 VLAN Tag 值（当 MAC_VLAN_Incl 中 VLTI=0 时使用） |

---

## 二、RX 接收描述符

DMA 在接收方向也支持两种类型：

| 类型 | CTXT bit (RDES3[30]) | 用途 |
|------|----------------------|------|
| **Normal Descriptor** | `0` | 软件提供 Buffer 地址供 DMA 写入接收数据 |
| **Context Descriptor** | `1` | DMA 写回扩展状态（Timestamp 等） |

### 2.1 RX Normal Descriptor — 读格式 (Read Format)

软件准备，交给 DMA 写入接收数据前读取。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ RDES0            Header or Buffer 1 Address[31:0]                │
├──────────────────────────────────────────────────────────────────┤
│ RDES1            Reserved (或 64-bit 模式下 BUF1AP[63:32])       │
├──────────────────────────────────────────────────────────────────┤
│ RDES2            Payload or Buffer 2 or Next Desc Address[31:0]  │
├──────────────────────────┬───┬───────┬───────┬───────────────────┤
│ RDES3  │OWN│IOC│Rsvd     │B2V│B1V    │Rsvd   │                   │
│        │   │   │[29:26]  │   │       │[23:0] │                   │
└────────┴───┴───┴─────────┴───┴───────┴───────┴───────────────────┘
```

#### RDES0 — Buffer 1 地址

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **BUF1AP** | Header 或 Buffer 1 物理地址。SPH=1 时指向 Header Buffer（存放 L2/L3/L4 头） |

#### RDES1

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | Reserved | 64-bit 地址模式下：Buffer 1 Address[63:32] |

#### RDES2 — Buffer 2 地址

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **BUF2AP** | Payload 或 Buffer 2 物理地址。SPH=1 时必须是总线宽度对齐 |

#### RDES3 — 控制

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **OWN** | `1`=DMA 拥有。完成接收或缓冲区满后 DMA 清零 |
| `[30]` | **IOC** | **Interrupt on Completion** — `1`=DMA 关闭此描述符时产生中断 |
| `[29:26]` | Rsvd | Reserved |
| `[25]` | **BUF2V** | **Buffer 2 Address Valid** — 软件必须设为 `1` 才能让 DMA 使用 RDES2 地址 |
| `[24]` | **BUF1V** | **Buffer 1 Address Valid** — 软件必须设为 `1` 才能让 DMA 使用 RDES1 地址 |
| `[23:0]` | Rsvd | Reserved |

---

### 2.2 RX Normal Descriptor — 写回格式 (Write-Back Format)

DMA 在完成接收后，在最后一个描述符 (LD=1) 中写入此格式。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ RDES0       Inner VLAN Tag[31:16]    │  Outer VLAN Tag[15:0]     │
├──────────────────────────────────────┼───────────────────────────┤
│ RDES1   OAM Code/MAC Ctrl Opcode     │     Extended Status       │
├────────────────┬──┬─────┬────────────┼──────┬────────────────────┤
│ RDES2  │Filter │HF│MADRM│DAF│SAF│OTS│ITS│Rs │ARPNR│HL[9:0]       │
│        │Status │  │     │   │   │   │   │vd │     │              │
├────────┼──┬──┬──┼──┼──┬──┼───┼──┼──┼───┼──┼──┼─────┼──┬─────────┤
│ RDES3  │OW│CT│FD│LD│RS│RS│RS│CE│GP│RW│OE│RE│DE │LT │ES│PL[14:0] │
│        │N │XT│  │  │2V│1V│0V│  │  │T │  │  │   │   │  │         │
└────────┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴───┴───┴──┴─────────┘
```

#### RDES0 — VLAN Tags

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:16]` | **IVT** | **Inner VLAN Tag** — RS0V=1 时有效（需使能 Double VLAN + Tag Stripping） |
| `[15:0]` | **OVT** | **Outer VLAN Tag** — RS0V=1 时有效 |

#### RDES1 — 扩展状态

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:16]` | **OPC** | **OAM Code / MAC Control Opcode** — 当 LT=111/110 时有效 |
| `[15]` | **TD** | **Timestamp Dropped** — 时间戳已捕获但被 Rx FIFO 溢出丢弃 |
| `[14]` | **TSA** | **Timestamp Available** — `1`=Context Descriptor 中有时间戳 |
| `[13]` | **PV** | **PTP Version** — `0`=v1, `1`=v2 |
| `[12]` | **PFT** | **PTP Packet Type** — `1`=PTP over Ethernet (非 UDP/IP) |
| `[11:8]` | **PMT** | **PTP Message Type** |

PMT 编码：

| 值 | 消息类型 |
|----|---------|
| `0000` | 非 PTP 消息 |
| `0001` | SYNC |
| `0010` | Follow_Up |
| `0011` | Delay_Req |
| `0100` | Delay_Resp |
| `0101` | Pdelay_Req (P2P TC) |
| `0110` | Pdelay_Resp (P2P TC) |
| `0111` | Pdelay_Resp_Follow_Up (P2P TC) |
| `1000` | Announce |
| `1001` | Management |
| `1010` | Signaling |
| `1111` | Reserved 类型 PTP |

| Bits | 名称 | 描述 |
|------|------|------|
| `[7]` | **IPCE** | **IP Payload Error** — TCP/UDP/ICMP checksum 不匹配或长度不一致 |
| `[6]` | **IPCB** | **IP Checksum Bypassed** — Checksum Offload 被旁路 |
| `[5]` | **IPV6** | **IPv6 Header Present** |
| `[4]` | **IPV4** | **IPv4 Header Present** |
| `[3]` | **IPHE** | **IP Header Error** — IPv4 checksum 错误或版本不一致 |
| `[2:0]` | **PT** | **Payload Type** |

PT 编码：

| 值 | 类型 |
|----|------|
| `000` | Unknown / 未处理 |
| `001` | UDP |
| `010` | TCP |
| `011` | ICMP |
| `100` | IGMP (IPv4) 或 DCB/LLDP |
| `101` | AV Untagged Control |
| `110` | AV Tagged Data |
| `111` | AV Tagged Control |

#### RDES2 — 过滤器状态 / Header 长度

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:29]` | **L3L4FM** | **L3/L4 Filter Number Matched** — 匹配的过滤器编号 (0~7) |
| `[28]` | **L4FM** | **Layer 4 Filter Match** |
| `[27]` | **L3FM** | **Layer 3 Filter Match** |
| `[26:19]` | **MADRM** | **MAC Address Match / Hash Value** — HF=0 时为匹配的 MAC 地址寄存器号；HF=1 时为 hash 值 |
| `[18]` | **HF** | **Hash Filter Status** — `1`=通过 hash 过滤 |
| `[17]` | **DAF/RXPI** | **DA Filter Fail** (Parser 禁用) / **RX Parse Incomplete** (Parser 启用+ECC 错误) |
| `[16]` | **SAF/RXPD** | **SA Filter Fail** (Parser 禁用) / **RX Packet Dropped** (Parser 启用) |
| `[15]` | **OTS** | **Outer VLAN Tag Filter Status** (ERVFE 启用时) / VLAN Filter Status (ERVFE 禁用时) |
| `[14]` | **ITS** | **Inner VLAN Tag Filter Status** — 仅 ERVFE 启用且 Double VLAN 时有效 |
| `[13:11]` | Rsvd | Reserved |
| `[10]` | **ARPNR** | **ARP Reply Not Generated** — MAC 正忙处理前一个 ARP 请求 |
| `[9:0]` | **HL** | **L3/L4 Header Length** — FD=1 时有效。MAC 在 L3/L4 边界分离的 Header 字节长度。0=未识别 |

#### RDES3 — 状态字

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **OWN** | 完成接收后 DMA 清零 |
| `[30]` | **CTXT** | Normal Descriptor = `0` |
| `[29]` | **FD** | **First Descriptor** |
| `[28]` | **LD** | **Last Descriptor** — 状态字段仅在 LD=1 时有效 |
| `[27]` | **RS2V** | **RDES2 Valid** — `1`=RDES2 中的状态有效 |
| `[26]` | **RS1V** | **RDES1 Valid** — `1`=RDES1 中的状态有效 |
| `[25]` | **RS0V** | **RDES0 Valid** — `1`=RDES0 中的 VLAN Tags 有效 |
| `[24]` | **CE** | **CRC Error** — 收到包的 CRC 校验失败 |
| `[23]` | **GP** | **Giant Packet** — 包长超过最大以太网帧长 (1518/1522/2000 或 Jumbo 9018/9022) |
| `[22]` | **RWT** | **Receive Watchdog Timeout** — 看门狗超时，包被截断 |
| `[21]` | **OE** | **Overflow Error** — Rx FIFO 溢出（仅 Threshold 模式；SF 模式下溢出包已丢弃） |
| `[20]` | **RE** | **Receive Error** — RX_DV=1 时 RX_ER 被断言 |
| `[19]` | **DE** | **Dribble Bit Error** — 包长度非整数倍字节（奇数 nibble，仅 MII 模式） |
| `[18:16]` | **LT** | **Length/Type Field** |

LT 编码：

| 值 | 含义 |
|----|------|
| `000` | Length 包 |
| `001` | Type 包 |
| `011` | ARP Request 包 |
| `100` | Type 包 + VLAN Tag |
| `101` | Type 包 + Double VLAN Tag |
| `110` | MAC Control 包 |
| `111` | OAM 包 |

| Bits | 名称 | 描述 |
|------|------|------|
| `[15]` | **ES** | **Error Summary** — CE, DE, RE, RWT, OE, GP, DAF, SAF 的逻辑或 |
| `[14:0]` | **PL** | **Packet Length** — 传输到系统内存的字节长度（含 CRC）。LD=1 且 OE=0 时有效 |

---

### 2.3 RX Context Descriptor

DMA 写回扩展状态（时间戳），应用只读。

```
 31                                                                0
┌──────────────────────────────────────────────────────────────────┐
│ RDES0                   Timestamp Low[31:0]                      │
├──────────────────────────────────────────────────────────────────┤
│ RDES1                   Timestamp High[31:0]                     │
├──────────────────────────────────────────────────────────────────┤
│ RDES2                   Reserved[31:0]                           │
├────────┬────────┬───────┬───────────────────────────────────────┤
│ RDES3  │OWN     │CTXT=1 │DE│Rsvd[28:0]                           │
└────────┴────────┴───────┴──┴────────────────────────────────────┘
```

| Bits | 名称 | 描述 |
|------|------|------|
| `[31:0]` | **RTSL** | **Timestamp Low** — 全 1 表示时间戳损坏 |
| `[31:0]` | **RTSH** | **Timestamp High** — 全 1 表示时间戳损坏 |
| `[31:0]` | Reserved | |
| `[31]` | **OWN** | DMA 清零 |
| `[30]` | **CTXT** | Context Descriptor = `1` |
| `[29]` | **DE** | **Descriptor Error** |
| `[28:0]` | Rsvd | Reserved |

CTXT + DE 组合含义:

| {CTXT, DE} | 含义 |
|-------------|------|
| `00` | Reserved |
| `01` | Reserved |
| `10` | 正常的 Context Descriptor |
| `11` | Descriptor Error (全 1) |

---

## 三、Enhanced Descriptor (TBS, 32-Byte)

启用 Time-Based Scheduling (TBS / EST) 时需要 32 字节增强描述符，EDSE=1 时使能。在前 16 字节中增加 4 个扩展字 (ETDESC4~7)。

### 3.1 Enhanced Normal Descriptor — Read 格式

```
 31                                   11  8                     0
┌──────────────────────────────────────────────────────────────────┐
│ ETDESC4   │LTV│Reserved             │GSN[3:0]│LT[31:24]         │
├──────────────────────────────────────────────────────────────────┤
│ ETDESC5                Launch Time[23:0]                         │
├──────────────────────────────────────────────────────────────────┤
│ ETDESC6                Reserved                                  │
├──────────────────────────────────────────────────────────────────┤
│ ETDESC7                Reserved                                  │
├──────────────────────────────────────────────────────────────────┤
│ TDESC0~3              (同 16-byte Normal Descriptor)              │
└──────────────────────────────────────────────────────────────────┘
```

| Bits | 名称 | 描述 |
|------|------|------|
| `[31]` | **LTV** | **Launch Time Valid** — `1`=LT 和 GSN 有效 |
| `[30:12]` | Rsvd | Reserved |
| `[11:8]` | **GSN** | **GCL Slot Number** — 关联的 Gate Control List 时隙号 |
| `[7:0]` + ETDESC5 | **LT** | **Launch Time[31:0]** — 包的发射时间 |

### 3.2 Enhanced Context Descriptor

ETDESC4~7 全部 Reserved（必须为 0），TDESC0~3 同 16-byte Context Descriptor。

---

## 四、描述符环机制

```
  Descriptor Base Address
        │
        ▼
  ┌─────────┐     ┌──────────┐
  │ Desc 0  │ ──► │ Buffer 1  │
  │         │ ──► │ Buffer 2  │
  ├─────────┤     ├──────────┤
  │ Desc 1  │ ──► │ Buffer 1  │
  │         │ ──► │ Buffer 2  │
  ├─────────┤     ├──────────┤
  │   ...   │         ...
  ├─────────┤     ├──────────┤
  │ Desc N  │ ──► │ Buffer 1  │
  │         │ ──► │ Buffer 2  │
  └─────────┘     └──────────┘
       ▲
       │  Wrap around
       │
  Descriptor Ring Length = N+1
```

- **OWN bit** (DES3[31]): `1`=DMA 拥有，`0`=软件拥有
- **Current Descriptor Pointer == Descriptor Tail Pointer** → DMA 暂停
- 软件写 Tail Pointer 寄存器推进尾指针 → DMA 继续
- 到达环尾时自动回绕到 Base Address

### FD/LD 分段控制

| FD | LD | 含义 |
|----|----|------|
| 1 | 0 | 第一个描述符，后续还有 |
| 0 | 0 | 中间描述符 |
| 0 | 1 | 最后一个描述符 |
| 1 | 1 | 单个描述符包含完整包 |

### 常见描述符错误

| 条件 | 含义 |
|------|------|
| OWN=0 且 DMA 需要下一个描述符 | DMA 暂停 (Suspend) |
| FD + LD + CTXT 同时为 1 | Descriptor Error (DE=1) |
| 描述符全 1 | Descriptor Error (DE=1) |
| Context Descriptor 出现在非首位置 | DE=1 |
