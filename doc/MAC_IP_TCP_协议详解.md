# Ethernet / IP / TCP 协议与 DWC_ether_qos 硬件处理

> 覆盖 MAC (L2)、IP (L3)、TCP/UDP (L4) 协议格式，以及在 DWC_ether_qos 硬件中的卸载处理方式。

---

## 一、协议栈总览

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Data (Payload)               │
├─────────────────────────────────────────────────────────────┤
│  L4: TCP Header (20~60B)  /  UDP Header (8B)               │
├─────────────────────────────────────────────────────────────┤
│  L3: IPv4 Header (20~60B) / IPv6 Header (40B + ext)        │
├─────────────────────────────────────────────────────────────┤
│  L2: Ethernet MAC Header (14B) + VLAN Tag (4B × 2) + FCS   │
├─────────────────────────────────────────────────────────────┤
│  L1: Preamble (7B) + SFD (1B) + IFG (12B)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、Ethernet MAC 层 (Layer 2) — IEEE 802.3

### 2.1 完整帧格式

```
  7B        1B      6B       6B      4B        2B      46~1500B    4B
┌────────┬────────┬────────┬────────┬────────┬────────┬──────────┬────────┐
│Preamble│  SFD   │  DA    │  SA    │VLAN Tag│Length/ │  DATA    │  FCS   │
│0x55... │ 0xD5   │        │        │(可选)  │ Type   │ + PAD    │ (CRC)  │
└────────┴────────┴────────┴────────┴────────┴────────┴──────────┴────────┘
│◄───────── 硬件自动添加/删除 ────────►│◄────────── 帧数据 ──────────────►│
  MAC 自动处理，软件不可见               软件/DMA 处理，CRC 硬件计算
```

### 2.2 字段详解

#### Preamble (7 字节)

```
  0x55 0x55 0x55 0x55 0x55 0x55 0x55

  二进制: 10101010 10101010 ... (7次)

  作用: 接收端 PLL 锁定时钟，位同步
  发送: MAC 硬件自动插入
  接收: MAC 硬件自动剥离
```

#### SFD — Start Frame Delimiter (1 字节)

```
  0xD5 = 11010101

  最后 2 bit 是 "11"，告诉接收端"下一个字节开始就是真的数据了"
```

#### DA — Destination Address (6 字节)

```
  ┌──────────────────────────────────┐
  │ Byte 0  │ Byte 1  │ ... │ Byte 5 │
  └──────────────────────────────────┘
                      │
                      ▼ Byte 0 的 Bit 0:
                I/G bit (Individual/Group)
                0 = Unicast
                1 = Multicast/Broadcast
                
                Byte 0 的 Bit 1:
                U/L bit (Universal/Local)
                0 = 全球唯一 (IEEE 分配 OUI)
                1 = 本地管理
```

**特殊地址**：

| 地址 | 用途 |
|------|------|
| `FF:FF:FF:FF:FF:FF` | 广播 |
| `01:80:C2:00:00:00` | 生成树 (STP) |
| `01:80:C2:00:00:01` | Pause 帧 (802.3x) |
| `01:80:C2:00:00:0E` | LLDP |
| `01:1B:19:00:00:00` | PTP (1588) |
| `01:00:5E:00:00:xx` | IPv4 组播 |
| `33:33:xx:xx:xx:xx` | IPv6 组播 |

#### SA — Source Address (6 字节)

```
  发送时: MAC 硬件可自动插入/替换 (SAIC 控制)
  值来自: MAC_Address0 或 MAC_Address1 寄存器
  
  DWC_ether_qos 发送时 SAIC:
    00: 不修改 → 软件在数据中提供
    01: 插入   → 帧不含 SA，硬件添加
    10: 替换   → 帧含 SA，硬件替换
```

#### VLAN Tag (4 字节) — IEEE 802.1Q

```
  ┌────────────────────┬───────┬───────────────┐
  │   TPID (2B)        │ PCP   │ DEI │  VID    │
  │   0x8100 或 0x88A8  │ (3bit)│(1bit)│ (12bit) │
  └────────────────────┴───────┴──────┴────────┘

  TPID (Tag Protocol Identifier):
    0x8100 = 802.1Q VLAN Tag
    0x88A8 = 802.1ad Provider Bridge (外层/双VLAN中的外层)

  PCP (Priority Code Point): 0~7, 数值越大优先级越高

  DEI (Drop Eligible Indicator): 1 = 可丢弃

  VID (VLAN Identifier): 0~4095
    VID=0: 优先级标签，无 VLAN 成员关系
    VID=1: 默认 VLAN
    VID=4095: 保留
```

#### Length / Type (2 字节)

```
  Value ≤ 1500 (0x05DC): Length — 数据字段字节数
  Value ≥ 1536 (0x0600): Type — 上层协议类型

  常见 Type:
    0x0800  IPv4
    0x0806  ARP
    0x86DD  IPv6
    0x8100  VLAN (当出现在这个位置时)
    0x8808  MAC Control (Pause 帧)
    0x88F7  PTP (1588)
    0x8847  MPLS Unicast
    0x8864  PPPoE Discovery
```

#### DATA + PAD (46~1500 字节, 或最大 9000 Jumbo)

```
  最小 DATA = 46 字节 (使得 DA+SA+LT+DATA+PAD ≥ 64 字节)
  
  如果软件提供的 Data < 46 字节:
    CPC=00 → 硬件自动追加 0x00 填充 (PAD)
    CPC=01 → 不追加 PAD（软件需确保总帧长 ≥ 60）
    
  Jumbo Frame: 最大 9000/16000 字节（需配置使能）
```

#### FCS — Frame Check Sequence (4 字节)

```
  CRC-32 多项式: 0x04C11DB7

  计算范围: DA + SA + LT + DATA + PAD (不含 Preamble/SFD/IFG)

  硬件位置: MAC 内部的 CTX (CRC Generator) 模块

  发送时: 硬件自动计算并追加 (CPC ≠ 10)
  接收时: 硬件自动校验，错误时 RDES3[24] CE=1
  接收时: 可选自动剥离 FCS (不送给 DMA)
```

### 2.3 CRC-32 计算

```
  多项式:  x³² + x²⁶ + x²³ + x²² + x¹⁶ + x¹² + x¹¹
          + x¹⁰ + x⁸ + x⁷ + x⁵ + x⁴ + x² + x + 1

  初始值: 0xFFFF_FFFF
  结果:   (按位取反) → FCS[31:0] (小端发送)

  DWC_ether_qos:
    发送: TBU → TPC → CTX 计算 CRC → TPC 追加 FCS → TPE 发送
    接收: RxMAC → CRC Check 模块校验 → 不匹配则 RDES3[24] CE=1
```

### 2.4 IFG — Inter-Frame Gap

```
  最小 12 字节 (96 bit times)

  1 Gbps:  12 × 8 / 125MHz = 96 ns
  100 Mbps: 12 × 8 / 25MHz  = 960 ns
  10 Mbps:  12 × 8 / 2.5MHz  = 9.6 μs

  DWC_ether_qos: 可编程范围 40~96 bit times (步长 8)
  MAC_Configuration.IPG 控制
```

---

## 三、MAC Control 帧 (Pause) — IEEE 802.3x Annex 31B

```
  ┌──────────┬──────────┬──────────┬──────────┬──────┬──────────┬──────┐
  │ DA       │ SA       │ Type     │ Opcode   │Pause │ Reserved │ FCS  │
  │ 01:80:C2 │          │ 0x8808   │ 0x0001   │Time  │ 42B 全0  │      │
  │ :00:00:01│          │ (2B)     │ (2B)     │(2B)  │          │      │
  └──────────┴──────────┴──────────┴──────────┴──────┴──────────┴──────┘

  Opcode 0x0001: Pause 帧 (唯一标准值)
  Pause Time: 暂停时间，单位 512 bit times
    0x0000: 取消暂停 (Zero-Quanta Pause)
    0xFFFF: 最大暂停 (~33.5ms at 1Gbps)

  DWC_ether_qos:
    发送: Flow Control 模块检测到反压 → 自动发 Pause
    接收: 检测 DA=01:80:C2:00:00:01 → 停止 TX 指定时间
```

---

## 四、IPv4 协议 (Layer 3) — RFC 791

### 4.1 IPv4 Header 格式 (20~60 字节)

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌───────┬───────┬───────────────┬─────────────────────────────────────┐
│Version│  IHL  │     DSCP      │           Total Length              │
│  (4)  │  (4)  │   + ECN (8)   │              (16)                  │
├───────┴───────┼───────────────┼─────────────────────────────────────┤
│        Identification         │ Flags (3)   │  Fragment Offset (13) │
│           (16)                │             │                       │
├───────────────────────────────┼─────────────┴───────────────────────┤
│    TTL (8)    │  Protocol (8) │         Header Checksum (16)        │
├───────────────┴───────────────┼─────────────────────────────────────┤
│                         Source IP Address (32)                      │
├───────────────────────────────┼─────────────────────────────────────┤
│                      Destination IP Address (32)                    │
├───────────────────────────────┴─────────────────────────────────────┤
│                         Options (0~40B, if IHL > 5)                 │
└──────────────────────────────────────────────────────────────────────┘
```

| 字段 | bits | 说明 |
|------|------|------|
| **Version** | 4 | `0100` = IPv4 |
| **IHL** | 4 | Internet Header Length，单位 4 字节。最小 5 (=20B)，最大 15 (=60B) |
| **DSCP + ECN** | 8 | QoS + 拥塞通知 |
| **Total Length** | 16 | IP 包总字节数（含 Header + Data），最大 65535 |
| **Identification** | 16 | 分片标识，同一数据报的所有分片共享 |
| **Flags** | 3 | Bit 0=Reserved, Bit 1=DF (Don't Fragment), Bit 2=MF (More Fragments) |
| **Fragment Offset** | 13 | 分片偏移，单位 8 字节 |
| **TTL** | 8 | Time To Live，每跳减 1，到 0 丢弃 |
| **Protocol** | 8 | 上层协议：`1`=ICMP, `6`=TCP, `17`=UDP |
| **Header Checksum** | 16 | IP 头的校验和（仅校验 Header，不含 Data） |
| **Source IP** | 32 | 源 IP 地址 |
| **Dest IP** | 32 | 目的 IP 地址 |

### 4.2 IPv4 Header Checksum

```
  算法: 16-bit 反码求和

  1. 将 Header 按 16-bit 分组 (Checksum 字段自身填 0)
  2. 所有 16-bit 值相加
  3. 如果有进位，加回低 16-bit (One's complement carry)
  4. 结果取反 → 填入 Checksum 字段

  DWC_ether_qos 硬件:
    CIC=01: 仅计算并插入 IP Checksum
    CIC=10: IP + Payload Checksum，无伪头
    CIC=11: IP + Payload Checksum，含伪头 (完整卸载)
```

### 4.3 IPv6 Header 格式 (40 字节固定)

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌───────┬───────────────────────┬─────────────────────────────────────┐
│Version│      Traffic Class    │            Flow Label               │
│  (4)  │          (8)          │              (20)                   │
├───────┴───────────────────────┼───────────────┬─────────────────────┤
│        Payload Length (16)    │  Next Header  │    Hop Limit (8)    │
│                               │      (8)      │                     │
├───────────────────────────────┴───────────────┴─────────────────────┤
│                                                                     │
│                         Source Address (128)                        │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│                      Destination Address (128)                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

  关键区别:
    - 无 Header Checksum (IPv6 依赖上层校验)
    - 无 Fragmentation 字段在 Base Header 中 (由 Extension Header 处理)
    - 无 Options，使用 Next Header 链式扩展
    - 无 IP 头 checksum → 硬件不需要计算 IPv6 Header Checksum
```

---

## 五、TCP 协议 (Layer 4) — RFC 793

### 5.1 TCP Header 格式 (20~60 字节)

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌───────────────────────────────┬─────────────────────────────────────┐
│         Source Port (16)      │        Destination Port (16)        │
├───────────────────────────────┴─────────────────────────────────────┤
│                        Sequence Number (32)                         │
├─────────────────────────────────────────────────────────────────────┤
│                     Acknowledgment Number (32)                      │
├───────┬───────────────┬───────┬─────────────────────────────────────┤
│ Offset│   Reserved    │Flags  │         Window Size (16)            │
│  (4)  │     (3)       │ (9)   │                                     │
├───────┴───────────────┼───────┴─────────────────────────────────────┤
│    Checksum (16)      │      Urgent Pointer (16)                    │
├───────────────────────┴─────────────────────────────────────────────┤
│                        Options (0~40B)                              │
└─────────────────────────────────────────────────────────────────────┘
```

| 字段 | bits | 说明 |
|------|------|------|
| **Source Port** | 16 | 源端口号 |
| **Dest Port** | 16 | 目的端口号 |
| **Sequence Number** | 32 | 发送方数据字节序号 (不含 SYN/FIN 消耗的序号) |
| **ACK Number** | 32 | 期望收到的下一个序号 (仅 ACK=1 时有效) |
| **Data Offset** | 4 | TCP Header 长度 (单位 4 字节)，最小 5 (=20B) |
| **Reserved** | 3 | |
| **Flags** | 9 | NS(1)+CWR+ECE+URG+ACK+PSH+RST+SYN+FIN |
| **Window Size** | 16 | 接收窗口大小，流控核心 |
| **Checksum** | 16 | TCP 校验和 (含伪头) |
| **Urgent Pointer** | 16 | 紧急数据指针 (仅 URG=1) |

**Flags 详解**:

| Flag | 名称 | 说明 |
|------|------|------|
| NS | Nonce Sum | ECN 随机数保护 |
| CWR | Congestion Window Reduced | 发送方收到了拥塞通知 |
| ECE | ECN-Echo | 收到拥塞标记的包 |
| URG | Urgent | Urgent Pointer 有效 |
| ACK | Acknowledgment | ACK Number 有效 |
| PSH | Push | 立即推给应用层，不要缓存 |
| RST | Reset | 重置连接 |
| SYN | Synchronize | 建立连接 |
| FIN | Finish | 关闭连接 |

### 5.2 TCP Checksum (伪头 + TCP Segment)

```
  TCP Checksum 计算范围:

  ┌──────────────────────────────────────────────────────┐
  │                  Pseudo Header                       │
  │  ┌────────────────────────────────────────────────┐  │
  │  │ Source IP (32)                                 │  │
  │  ├────────────────────────────────────────────────┤  │
  │  │ Dest IP (32)                                   │  │
  │  ├────────────────┬───────────────────────────────┤  │
  │  │ Reserved (8)   │ Protocol (8) │ TCP Length (16)│  │
  │  └────────────────┴──────────────┴────────────────┘  │
  ├──────────────────────────────────────────────────────┤
  │                  TCP Header                          │
  │  (Checksum 字段自身填 0)                              │
  ├──────────────────────────────────────────────────────┤
  │                  TCP Payload                         │
  └──────────────────────────────────────────────────────┘

  算法: 同 IPv4 — 16-bit 反码求和

  DWC_ether_qos:
    CIC=10: 校验 TCP 头 + Payload，但不含伪头 (软件自己加伪头校验)
    CIC=11: 完整卸载，硬件自动构造伪头并计算完整 TCP Checksum
```

### 5.3 TCP 连接状态机

```
                    CLOSED
                      │
              主动打开 │ 被动打开
                      ▼
              ┌──────────────┐
              │  SYN_SENT    │◄──── 发送 SYN
              └──────┬───────┘
                     │ 收到 SYN+ACK, 发送 ACK
                     ▼
              ┌──────────────┐
              │ ESTABLISHED  │◄──── 三次握手完成
              └──────┬───────┘
                     │
               数据传送阶段
                     │
              主动关闭 │ 被动关闭
              ┌───────┴───────┐
              ▼               ▼
         FIN_WAIT_1      CLOSE_WAIT
              │               │
              ▼               ▼
         FIN_WAIT_2      LAST_ACK
              │               │
              ▼               ▼
         TIME_WAIT        CLOSED
              │
              ▼ (2MSL 后)
           CLOSED
```

---

## 六、UDP 协议 (Layer 4) — RFC 768

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌───────────────────────────────┬─────────────────────────────────────┐
│         Source Port (16)      │        Destination Port (16)        │
├───────────────────────────────┼─────────────────────────────────────┤
│          Length (16)          │         Checksum (16)               │
├───────────────────────────────┴─────────────────────────────────────┤
│                            Payload                                  │
└─────────────────────────────────────────────────────────────────────┘

  Length: UDP Header + Data 总字节数 (≥ 8)
  Checksum: 覆盖伪头 + UDP Header + UDP Payload (为 0 表示不校验)
            伪头构造同 TCP (Protocol=17)
```

---

## 七、DWC_ether_qos 硬件卸载对照表

### 7.1 TX 方向

```
  软件提供的包:
  ┌──────────┬──────────┬───────────┬──────────┬────────────┐
  │ Eth Hdr  │ IP Hdr   │ TCP Hdr   │ Payload  │  (可选)    │
  │(14~22B)  │ (20~60B) │ (20~60B)  │          │            │
  └──────────┴──────────┴───────────┴──────────┴────────────┘

  硬件可自动完成的:

  ┌────────────────────┬──────────────────────┬─────────────────────┐
  │      功能           │    描述符控制位       │    硬件做的事        │
  ├────────────────────┼──────────────────────┼─────────────────────┤
  │ CRC 追加           │ CPC = 00/01/11       │ 计算并追加 FCS       │
  │ PAD 追加           │ CPC = 00             │ 填充 0x00 到最小 60B  │
  │ SA 插入/替换        │ SAIC = 01/10         │ 从 MAC_Addr 寄存器写 SA│
  │ VLAN 操作          │ VTIR = 00~11         │ 插入/删除/替换 VLAN Tag│
  │ IP Checksum        │ CIC = 01/10/11       │ 计算并插入 IP Header CS│
  │ TCP Checksum       │ CIC = 10/11          │ 计算并插入 TCP CS     │
  │ Pseudo-Header      │ CIC = 11             │ 硬件构造伪头参与 CS 计算│
  │ TSO (TCP分段)       │ TSE = 1             │ 自动分段 + Header 复制  │
  │ UFO (UDP分片)       │ TSE=1 + TSE_MODE    │ 自动 IP 分片          │
  │ One-step Timestamp │ OSTC = 1 (Context)   │ 硬件写 PTP Timestamp  │
  └────────────────────┴──────────────────────┴─────────────────────┘
```

### 7.2 TX Checksum Offload 细节

```
  CIC 编码 (TDES3[17:16]):

  ┌──────┬──────────────────────────────────────────────────┐
  │ CIC  │ 硬件行为                                         │
  ├──────┼──────────────────────────────────────────────────┤
  │  00  │ 不插入任何 Checksum                               │
  │  01  │ 仅 IP Header Checksum                            │
  │      │  - 软件提供正确的 IP Total Length                 │
  │      │  - 硬件计算 IP 头 checksum 并写入 IP Header       │
  │  10  │ IP Header + Payload Checksum, 无伪头              │
  │      │  - TCP/UDP Checksum = TCP头 + Payload 的反码和    │
  │      │  - 伪头校验需要软件在 Payload 中预计算             │
  │  11  │ IP Header + Payload Checksum + Pseudo-Header      │
  │      │  - 硬件自动从 IP Header 提取 SrcIP/DstIP/Protocol  │
  │      │  - 硬件自动计算 TCP Length = TotalLen - IHL*4     │
  │      │  - 构造伪头 → 全量 TCP Checksum                   │
  └──────┴──────────────────────────────────────────────────┘
```

### 7.3 RX Checksum Offload 检查

```
  硬件自动检测并写入 Rx 描述符状态:

  ┌──────────┬──────────────────────────────────────┐
  │ 状态位    │ 含义                                  │
  ├──────────┼──────────────────────────────────────┤
  │ IPHE=1   │ IPv4 Header Checksum 错误             │
  │          │  - CS 不匹配                           │
  │          │  - IP 版本与 Ethernet Type 不一致      │
  │          │  - IP 头长度不足                       │
  ├──────────┼──────────────────────────────────────┤
  │ IPCE=1   │ TCP/UDP/ICMP Payload Checksum 错误    │
  │          │  - CS 不匹配                           │
  │          │  - Segment 长度与 IP Payload Len 不一致│
  │          │  - Segment 长度小于最小允许值          │
  ├──────────┼──────────────────────────────────────┤
  │ IPV4=1   │ 检测到 IPv4 Header                    │
  │ IPV6=1   │ 检测到 IPv6 Header                    │
  ├──────────┼──────────────────────────────────────┤
  │ PT[2:0]  │ Payload Type:                         │
  │          │   000=未知  001=UDP  010=TCP  011=ICMP│
  │          │   100=IGMP  110/111=AV                 │
  └──────────┴──────────────────────────────────────┘
```

### 7.4 TSO 硬件分段流程

```
  软件提供的模板:
  ┌──────────┬──────────┬───────────┬──────────────────┐
  │ Eth Hdr  │ IP Hdr   │ TCP Hdr   │  64KB Payload    │
  │ (固定)    │ (IP ID,  │ (Seq# 需  │                  │
  │          │  Length  │  硬件更新) │                  │
  │          │  需更新)  │           │                  │
  └──────────┴──────────┴───────────┴──────────────────┘
                    │
                    ▼ 硬件逐段处理
  ┌─────────────────────────────────────────────────┐
  │ Segment 1:                                       │
  │  Eth[复制] + IP[Length改,ID改,CS重算]             │
  │  + TCP[Seq=初始,CS重算] + Data[0~1459] + CRC      │
  ├─────────────────────────────────────────────────┤
  │ Segment 2:                                       │
  │  Eth[复制] + IP[Length改,ID+1,CS重算]             │
  │  + TCP[Seq=初始+1460,CS重算] + Data[1460~2919]    │
  ├─────────────────────────────────────────────────┤
  │ ...                                              │
  ├─────────────────────────────────────────────────┤
  │ Segment N (≤MSS):                                 │
  │  Eth[复制] + IP[...] + TCP[Seq,Fin位,CS]          │
  │  + Data[最后块] + CRC                             │
  └─────────────────────────────────────────────────┘

  关键参数:
    THL  = Eth_Hdr_len + IP_Hdr_len + TCP_Hdr_len
    MSS  = 每段最大 Payload 字节 (Context Desc 提供)
    FL   = TCP Payload 总长度
```

### 7.5 ARP Offload

```
  IPv4 ARP Request 格式:
  ┌─────────┬─────────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────────┐
  │Eth DA   │Eth SA   │Type  │HWType│Proto │HWSize│Proto │Opcode│Sender│Target    │
  │全F      │         │0x0806│0x0001│0x0800│6     │Size 4│1=Req │MAC+IP│MAC(全0)  │
  │         │         │      │      │      │      │      │2=Rep │      │+IP       │
  └─────────┴─────────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────────┘

  DWC_ether_qos 硬件 ARP Offload:
    - 检测 ARP Request (Type=0x0806, Opcode=1)
    - 校验 Target IP == MAC_Address 寄存器中的 IP
    - 匹配 → 硬件自动生成 ARP Reply (交换 Sender/Target MAC+IP)
    - 不匹配 → RDES2[10] ARPNR=1 (ARP Reply Not Generated)
```

---

## 八、常见 Protocol 字段值速查

```
  EtherType (2B, MAC 层):
    0x0800  IPv4
    0x0806  ARP
    0x8100  VLAN (802.1Q)
    0x86DD  IPv6
    0x8808  MAC Control
    0x8847  MPLS
    0x8863  PPPoE Discovery
    0x8864  PPPoE Session
    0x8870  Jumbo Frame
    0x88A8  VLAN (802.1ad Provider Bridge)
    0x88CC  LLDP
    0x88F7  PTP (IEEE 1588)

  IP Protocol (1B, IP Header):
    1   ICMP
    2   IGMP
    6   TCP
    17  UDP
    41  IPv6 (tunnel)
    47  GRE
    50  ESP (IPsec)
    51  AH (IPsec)
    89  OSPF

  MAC Control Opcode (2B):
    0x0001  Pause
    0x0002  PFC (Priority Flow Control 多优先级)

  Common Port Numbers:
    20/21  FTP
    22     SSH
    23     Telnet
    25     SMTP
    53     DNS
    67/68  DHCP
    80     HTTP
    123    NTP
    161    SNMP
    319    PTP Event
    320    PTP General
    443    HTTPS
    520    RIP
    319/320 PTP (IEEE 1588)
```

---

## 九、典型包在 DWC_ether_qos 中的处理路径

### TX: 软件发包 → 硬件处理 → 线缆

```
  软件侧                                 硬件侧
  ┌──────────┐                          ┌─────────────────────────┐
  │准备 Eth+IP│                          │ DMA 读描述符              │
  │+TCP+Data │   ── 写 Tail ──────────► │ DMA 读数据到 MTL TxQ     │
  │写描述符    │                          │                         │
  └──────────┘                          │ MTL TxQ → Tx Scheduler   │
                                        │   ↓                     │
                                        │ MAC TBU: 接收, Endian调整│
                                        │   ↓                     │
                                        │ MAC TPC:                  │
                                        │  - SA插入? (SAIC控制)     │
                                        │  - VLAN操作? (VTIR控制)    │
                                        │  - PAD追加? (CPC控制)     │
                                        │  - CRC计算 (CTX)          │
                                        │   ↓                     │
                                        │ MAC TPE:                  │
                                        │  - Preamble+SFD插入       │
                                        │  - IFG控制               │
                                        │  - CSMA/CD (半双工)       │
                                        │   ↓                     │
                                        │ PHY I/F → 外部 PHY → 线缆 │
                                        └─────────────────────────┘
```

### RX: 线缆 → 硬件处理 → 软件收包

```
  线缆侧                                 硬件侧
                                        ┌─────────────────────────┐
  外部 PHY → GMII/RGMII ───────────────►│ MAC RxMAC:               │
                                        │  - Preamble/SFD剥离       │
                                        │  - DA/SA/Type提取         │
                                        │  - RX_ER检测             │
                                        │   ↓                     │
                                        │ MAC CRC Checker:          │
                                        │  - CRC校验 (不匹配→CE=1)  │
                                        │   ↓                     │
                                        │ MAC RPC:                  │
                                        │  - VLAN Tag检测/剥离      │
                                        │  - Pause帧识别            │
                                        │  - Watchdog超时检测       │
                                        │  - DA/SA 过滤             │
                                        │  - PTP 帧检测+Timestamp   │
                                        │   ↓                     │
                                        │ MAC RBI: Endian调整 → MTL│
                                        │   ↓                     │
                                        │ MTL RxQ → Rx Scheduler    │
                                        │   ↓                     │
                                        │ DMA 写数据到系统内存       │
                                        │ DMA 写回 Rx 描述符状态     │
                                        │   ↓                     │
                                        │ 中断通知 CPU             │
                                        └─────────────────────────┘
                                              │
  软件侧                                      │
  ┌──────────┐                               │
  │读描述符状态│ ◄──── 中断 ───────────────────┘
  │解析 VLAN  │
  │解析 PTP   │
  │解析 IP/TCP│
  │提交协议栈  │
  └──────────┘
```
