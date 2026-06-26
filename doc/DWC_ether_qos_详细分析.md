# Synopsys DWC_ether_qos 详细架构分析

> 基于 Synopsys DesignWare Cores Ethernet Quality-of-Service Databook Version 5.10a (December 2017)
> 产品代码: DWC-ETHERNET-QOS-SRC (6842-0)

---

## 一、总体架构

DWC_ether_qos 是一个符合 IEEE 802.3-2015 规范的可配置以太网控制器 IP，支持 10/100/1000 Mbps 三种速率。架构分为四大核心层级：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Application System (CPU + Memory)             │
│   AHB/AXI Bus (32/64/128-bit)                                   │
├────────┬──────────────────┬────────────────┬──────────────┬─────┤
│CSR I/F │  DMA Controller  │   MTL Layer    │   MAC Core   │PHY I│
│AHB/APB │ TxDMA RxDMA Arb  │ TxQ RxQ Sched  │ Tx Rx CRC    │MUX  │→ PHY
│AXI     │ TSO/UFO Offload  │ Flow Ctrl PFC  │ VLAN 1588 FPE│     │
├────────┴──────────────────┴────────────────┴──────────────┴─────┤
│  Aux: MDIO/SMA | PCS 8b10b | 1588 TSU/PPS | EEE | PMT | Safety │
└─────────────────────────────────────────────────────────────────┘
```

### 四种配置模式

| 配置 | 缩写 | 特点 |
|------|------|------|
| EQOS-CORE | Native Core | 仅 MAC + FIFO 接口，无 DMA/MTL |
| EQOS-MTL | Native MTL | MAC + MTL FIFO 层，无 DMA |
| EQOS-DMA | Native DMA | 完整子系统，native DMA 接口 |
| EQOS-AHB / EQOS-AXI | 总线型 | 完整子系统 + AHB 或 AXI 总线主接口 |

---

## 二、详细工作流程

### 2.1 TX 数据发送路径

```
Step 1: 软件准备描述符
  CPU 在系统内存中构建 TX 描述符环 (TDES0-3)
  - TDES2: 数据缓冲区地址
  - TDES3[31]: Own bit = 1 (交给 DMA)
  - TDES3: FD(First)/LD(Last) 标记、CRC/PAD 控制、VLAN 控制、TSO 控制

Step 2: 软件通知 DMA
  CPU 写 DMA_CH[n]_Tx_Desc_Tail_Pointer 寄存器，递增尾指针
  DMA 检测到 Own bit=1 的描述符，启动传输

Step 3: DMA 通道仲裁
  DMA Arbiter 在 up to 8 个 Tx 通道间进行仲裁
  仲裁策略: Round-Robin 或 Fixed-Priority (可编程)

Step 4: DMA 读取描述符和数据
  DMA 通过 AHB/AXI Master 接口:
  a) 从系统内存读取 Tx 描述符 (16 字节)
  b) 解析描述符获取缓冲区地址和长度
  c) 从系统内存读取以太网帧数据 (突发传输，最大 PBL 个 beat)
  d) 更新描述符状态 (TDES0 写入)

Step 5: ATI 接口传输到 MTL
  DMA 通过 ATI (Application Transmit Interface) 将数据推入 MTL:
  a) 先发 Tx Control Word (包控制 + 包长度)
     - CRC/PAD 控制: 2'b00=CRC+PAD, 2'b01=仅PAD, 2'b10=仅CRC, 2'b11=都不加
     - SA 插入/替换控制: 2'b00=不改, 2'b01=插入, 2'b10=替换
     - VLAN 插入/替换/删除控制 (VTIR)
     - TCP/UDP Checksum 插入使能 (CIC)
     - One-step Timestamp 控制 (OSTC)
     - IEEE 1588 Timestamp 使能 (TSE)
  b) 然后按数据流发送: SOP → Data → EOP + Byte Enables
  c) 多队列时需带 ati_qnum_i 指示目标队列号

Step 6: MTL Tx 队列缓冲
  数据写入共享 SRAM 中的 Tx 队列:
  - 单队列模式: 2KB ~ 128KB
  - 多队列模式: 每队列可编程大小 (256B 粒度)
  - 支持 Store-and-Forward (完整帧) 和 Threshold/Cut-through 模式
  - PBL/Watermark 握手避免队列溢出

Step 7: Tx 队列调度仲裁
  从非空 Tx 队列中选择下一个发送的队列:
  调度算法 (可编程):
  ├── SP (Strict Priority): 高优先级队列绝对优先
  ├── WRR (Weighted Round Robin): 按权重轮询
  ├── DWRR (Deficit WRR): DCB 模式，更精确的带宽分配
  ├── WFQ (Weighted Fair Queuing): DCB 模式
  ├── CBS (Credit-Based Shaper): AVB 模式, IEEE 802.1Qav
  ├── EST (Enhancements to Scheduled Traffic): TSN, IEEE 802.1Qbv
  └── TBS (Time-Based Scheduling): TSN 模式
  需预取每个队列的第一个位置 (包控制+包长度)

Step 8: MTI 接口传输到 MAC
  MTL Tx Queue Read Controller 通过 MTI (MAC Transmit Interface):
  a) 从 SRAM 读取数据
  b) 将数据发送到 MAC (mti_data + mti_val)
  c) 带 SOP (mti_sop) 和 EOP (mti_eop) 边带信号
  d) CRC/PAD 控制通过 mti_crc_pad_ctrl 传递给 MAC
  e) MAC 可通过 de-assert mti_rdy 进行反压

Step 9: MAC 发送处理
  MAC 内部 Tx 路径 6 个模块流水处理:

  TBU (Transmit Bus Interface):
  - 32/64/128-bit → 8-bit 数据宽度转换
  - 字节序转换 (Endian swap)
  - 输出 Tx Status 和 Timestamp Snapshot

  TPC (Transmit Packet Controller):
  - 8 级寄存器缓冲
  - 自动追加 PAD (帧 < 60 字节时)
  - 接收 CRC 计算结果并追加到帧尾
  - 控制 CRC/PAD 追加策略

  TPE (Transmit Protocol Engine):
  - 管理 Tx 状态机
  - 处理半双工 CSMA/CD
  - 碰撞检测和重传控制

  Tx MAC:
  - 插入 Preamble (7 字节 0x55) + SFD (1 字节 0xD5)
  - 插入/替换/删除 VLAN Tag (最多 2 层)
  - 插入/替换 Source Address
  - 帧间隔 IFG 控制 (40~96 bit times, 8 步可编程)
  - Jabber 超时保护
  - 半双工: 载波侦听、退避算法

  CRC Generator (CTX):
  - IEEE 802.3 CRC-32: 多项式 0x04C11DB7
  - 在帧的 DA+SA+LT+DATA+PAD 上计算
  - 计算完成后追加 FCS 4 字节

  Flow Control Module:
  - 全双工: 自动发送 IEEE 802.3x Pause 帧
  - DCB: 基于优先级的 PFC (Priority Flow Control)
  - 检测到 flow_ctrl 输入跳变时自动发送零量子 Pause 帧

Step 10: PHY 接口输出
  通过配置的 PHY 接口将数据发送到外部 PHY:
  - GMII/MII: 8-bit TXD + TX_EN + TX_ER + GTX_CLK (125/25/2.5 MHz)
  - RGMII: 4-bit TXD, DDR (上升沿 TXD[3:0], 下降沿 TXD[7:4])
  - SGMII: 串行 1.25 Gbps, 8b10b 编码
  - RMII: 2-bit, 50 MHz 参考时钟

Step 11: Tx Status 回传
  MAC → MTL → DMA/Application:
  a) MAC 发送完成后返回 mti_txstatus (18 或 82 位)
     - 正常完成 / 碰撞重传 / 各种错误码
     - 可选 64-bit IEEE 1588 Timestamp
  b) MTL 通过 ATI 接口的 ati_txstatus 返回给应用
  c) 应用/DMA 读取状态，更新描述符
  d) DMA 可配置为不等待 Tx Status (DTXSTS=1) 以提高吞吐
```

### 2.2 RX 数据接收路径

```
Step 1: PHY 接口接收
  从外部 PHY 接收数据:
  - GMII: RXD[7:0] + RX_DV + RX_ER + RX_CLK (125 MHz)
  - 检测 RX_DV=1 表示帧开始

Step 2: MAC 接收处理
  内部 Rx 路径模块流水:

  Rx MAC:
  - 移除 Preamble + SFD
  - 检测 RX_ER 错误条件:
    * RX_ER=1, RX_DV=1 → 接收错误 (False Carrier / Bad SFD)
    * RX_ER=1, RX_DV=0 → 载波扩展 (1000M 半双工)
  - 地址过滤 (DA Filter):
    * 31 个额外 48-bit 精确匹配 DA 过滤器
    * 96 个可选额外 DA 过滤器 (分 32/64 块)
    * 31 个 SA 比较过滤器
    * 256-bit Hash 过滤器 (组播/单播)
    * Promiscuous 模式 (不过滤)
    * 组播直通模式
  - VLAN Tag 检测: 可选剥离最多 2 层 VLAN Tag
  - 检测 Pause 帧 (01:80:C2:00:00:01)
  - 检测 Wake-up / Magic Packet

  CRC Checker:
  - 对收到的帧计算 CRC-32
  - 与收到的 FCS 比较
  - 错误: 标记 CRC Error (可配置丢弃或转发)
  - 可选禁用自动 CRC 检查

  Rx Packet Controller:
  - 字节对齐处理
  - Watchdog 超时 (可编程, 默认 2048 字节)
  - PAD 剥离 (可选)
  - CRC 剥离 (可选)
  - 组装 Rx Status Word (112 或 128 位)

  RBI (Receive Bus Interface):
  - 8-bit → 32/64/128-bit 数据宽度转换
  - 字节序转换
  - 与 MTL 的 MRI 接口通信

Step 3: MRI 接口写入 MTL
  MAC 通过 MRI (MAC Receive Interface) 发送到 MTL:
  a) mri_val + mri_sop → 帧开始
  b) mri_val + mri_data → 数据
  c) mri_val + mri_eop → 帧结束
  d) mri_rxstatus → Rx Status Word
  e) MTL 可通过 de-assert mri_rdy 反压

Step 4: MTL Rx 队列缓冲
  数据写入共享 SRAM 中的 Rx 队列:
  - Threshold (Cut-through) 模式: 达到阈值即开始转发
  - Store-and-Forward 模式: 完整帧接收后再转发
  - 出错帧策略: SF 模式下可配置过滤所有错误帧
  - Rx Status 在 EOP 后存储 (Threshold) 或预留在 SOP 前 (SF)
  - IEEE 1588 使能时额外存储 64-bit Timestamp

Step 5: Rx 队列路由
  通过以下方式将帧路由到正确的 Rx 队列:
  - DA-based 路由: 根据目标 MAC 地址
  - VLAN Priority-based 路由: 根据 VLAN PCP 字段
  - Flexible Rx Parser: 可编程 LUT 表, 解析 L3/L4 过滤
  - 组播/广播帧可路由到指定队列
  - Untagged 帧可路由到指定队列
  - PTP over Ethernet 可路由到指定队列

Step 6: ARI 接口转发到 DMA
  Rx 队列间仲裁后, 通过 ARI (Application Receive Interface):
  仲裁策略: WRR / WSP (Weighted Strict Priority) / SP

  a) MTL 检测数据可用 (达到 threshold 或完整帧)
  b) 断言 ari_rxwatermark 通知 DMA
  c) DMA 通过 ari_ready 准备接收
  d) MTL: ari_val + ari_sop → 数据 + ari_eop → Rx Status
  e) ari_qnum_o 指示数据来源队列号

Step 7: DMA 写入系统内存
  DMA Rx Engine:
  a) 从描述符环获取 Rx 描述符
  b) 将帧数据通过 AHB/AXI 写入系统内存缓冲区
  c) 可选的 Header-Payload Split: 头和数据分离到不同缓冲区
  d) L3/L4 Checksum Offload 验证 (IPv4/IPv6 TCP/UDP)
  e) 更新 Rx 描述符状态 (RDES):
     - 包长度 (PL)
     - Frame Type (VLAN/ARP/PTP/TCP/UDP)
     - 错误标记 (CRC Error / Receive Error / Watchdog Timeout / Overflow)
     - VLAN Tag 值
     - IEEE 1588 Timestamp
     - L3/L4 Checksum 结果

Step 8: 中断通知
  DMA 完成接收后产生中断:
  - 每包完成中断
  - 描述符列表耗尽中断
  - 错误中断 (Overflow / Bus Error)
  - 可编程中断聚合 (Periodic Scheduling)
```

### 2.3 初始化流程

```
1. DMA 初始化
   - 配置 DMA_Mode 寄存器 (仲裁模式、Tx/Rx 优先级)
   - 设置 Tx/Rx 描述符列表基地址和环长度
   - 初始化描述符 (Own bit = 0, 分配数据缓冲区)
   - 写 Tx/Rx Descriptor Tail Pointer 启动

2. MTL 初始化
   - 配置 Queue Operation Mode (Threshold/Store-and-Forward, 阈值)
   - 配置 Queue Scheduler (WRR/SP/CBS 等及权重)
   - 使能发送/接收队列

3. MAC 初始化
   - 配置 MAC 地址 (MAC_Address0_High/Low)
   - 配置 PHY 接口类型选择 (GMII/RGMII/SGMII/...)
   - 配置速度 (10/100/1000 Mbps) 和双工模式
   - 配置 VLAN 处理、过滤规则
   - 使能 IEEE 1588 Timestamp (如需)
   - 配置 Flow Control (Pause/PFC)
   - 配置中断使能

4. 启动正常收发
   - 设置 DMA Tx/Rx Start (ST/SR bit)
   - 或通过 Sideband 信号启动
```

---

## 三、涉及的所有标准协议

### 3.1 IEEE 802.3 系列（以太网核心标准）

| 标准 | 内容 | 在本 IP 中的应用 |
|------|------|-----------------|
| **IEEE 802.3-2015** | 以太网完整标准（基础） | MAC 帧格式、GMII/MII/TBI 接口、CRC-32、Preamble/SFD、CSMA/CD、Flow Control |
| **IEEE 802.3x** | 全双工流控 | Pause 帧 (MAC Control Frame, opcode 0x0001) 发送和接收 |
| **IEEE 802.3z** | 1000BASE-X (光纤千兆) | TBI 接口、8b10b 编码、Auto-Negotiation |
| **IEEE 802.3az-2010** | Energy Efficient Ethernet (EEE) | LPI (Low Power Idle) 信令、EEE Tx/Rx 状态机 |
| **IEEE 802.3br-2016** | Interspersing Express Traffic | Frame Preemption (FPE) - MAC 合并子层 |
| **IEEE 802.3-2015 Clause 4** | MAC 服务规范 | MAC Control 帧格式、Pause 操作 (Annex 31B) |
| **IEEE 802.3-2015 Clause 22** | MDIO 管理接口 | MDIO Frame Format (Clause 22), STA/MDIO 读写 |
| **IEEE 802.3-2015 Clause 35** | GMII 接口 | 8-bit 并行, 125 MHz, TXD/RXD, TX_EN/RX_DV, TX_ER/RX_ER, GTX_CLK/RX_CLK |
| **IEEE 802.3-2015 Clause 45** | MDIO 扩展 | Clause 45 MDIO 帧格式 (间接寄存器访问) |

### 3.2 IEEE 1588 / 802.1 时间同步系列

| 标准 | 内容 | 在本 IP 中的应用 |
|------|------|-----------------|
| **IEEE 1588-2008 (PTPv2)** | 精确时钟同步协议 | 64-bit Timestamp, One-step/Two-step, PPS 输出, Auxiliary Snapshot |
| **IEEE 802.1AS-2011** | 时间敏感应用的时钟同步 (gPTP) | AVB 时钟同步, 与 IEEE 1588 互操作 |
| **IEEE 802.1AS-Rev/D4.0~D5.0** | gPTP 修订版 | TSN 时钟同步增强 |

### 3.3 IEEE 802.1 桥接/调度系列

| 标准 | 内容 | 在本 IP 中的应用 |
|------|------|-----------------|
| **IEEE 802.1Q-2014** | VLAN/桥接基础 | VLAN Tag (TPID 0x8100), 单层/双层 VLAN, PCP/DEI |
| **IEEE 802.1Qav-2009** | 音视频桥接转发和排队 | CBS (Credit-Based Shaper), SR Class A/B |
| **IEEE 802.1Qbv-2015** | 调度流量的增强 | EST (Enhancements to Scheduled Traffic), Gate Control List (GCL) |
| **IEEE 802.1Qbu-2016** | 帧抢占 | Frame Preemption (与 802.3br 配合) |
| **IEEE 802.1Qaz-2011** | 增强传输选择 | ETS (Enhanced Transmission Selection), DCB 带宽分配 |
| **IEEE 802.1Qbb-2011** | 基于优先级的流控 | PFC (Priority Flow Control) - 每优先级的 Pause |

### 3.4 AMBA 总线标准

| 标准 | 版本 | 用途 |
|------|------|------|
| **AMBA 2.0 AHB** | ARM Ltd | AHB Master (数据 DMA) + AHB Slave (CSR 寄存器访问) |
| **AMBA 2.0 APB** | ARM Ltd | APB Slave (CSR 寄存器访问, 替代方案) |
| **AMBA 3.0 AXI** | ARM Ltd | AXI3 Master (数据 DMA) + AXI3 Slave (CSR) |
| **AMBA 3.0 APB3** | ARM Ltd | APB3 Slave (带 pready) |
| **AMBA 4 AXI4** | ARM Ltd (2013) | AXI4 Master + AXI4-Lite Slave + APB4 (带 pstrb/pprot) |

### 3.5 行业 PHY 接口规范

| 标准/规范 | 版本 | 来源 | 速率 | 信号 |
|-----------|------|------|------|------|
| **RGMII** | v2.6 | HP/Marvell | 1000M | 4-bit DDR, 125 MHz, TXC/RXC, TXD/RXD, TX_CTL/RX_CTL |
| **SGMII** | v1.8 | Cisco/Marvell | 1000M/100M/10M | 串行 1.25 Gbps / 125 Mbps / 12.5 Mbps, 差分 |
| **RMII** | v1.2 | RMII Consortium | 100M/10M | 2-bit, 50 MHz REF_CLK, TXD/RXD, TX_EN/CRS_DV |
| **SMII** | v2.1 | Cisco | 100M/10M | 串行, 125 MHz CLK, SYNC, TXD/RXD |
| **RevMII** | - | Dmitriy Gusev | 100M/10M | 反向 MII (MAC 端为 PHY 角色) |

### 3.6 IETF RFC 标准

| RFC | 内容 | 在本 IP 中的应用 |
|-----|------|-----------------|
| **RFC 2819** | RMON MIB (远程监控) | RMON 统计计数器 (etherStats 组) |
| **RFC 2665** | Ethernet-like Interface MIB | MIB 计数器 (dot3Stats 组) |
| **RFC 791** | IPv4 协议 | IPv4 头校验和卸载、TSO/UFO |
| **RFC 2460** | IPv6 协议 | IPv6 L3/L4 过滤 |
| **RFC 793** | TCP 协议 | TCP Checksum Offload, TSO (TCP Segmentation Offload) |
| **RFC 768** | UDP 协议 | UDP Checksum Offload, UFO (UDP Fragmentation Offload) |
| **RFC 826** | ARP 协议 | IPv4 ARP Offload Engine |

### 3.7 其他规范

| 规范 | 内容 | 应用 |
|------|------|------|
| **ISO 26262** | 道路车辆功能安全 | Automotive Safety Features (ECC, Parity, FSM Timeout, Interface Timeout) |
| **IEEE 1149.1** | JTAG 边界扫描 | Test Mode Interface |
| **IEEE 802.1Q-2014 Annex G** | 数据中心桥接 | DCB 模式 (DWRR/WFQ 调度, PFC) |
| **UNH InterOperability Lab** | 以太网测试套件 | Clause 4 MAC Test Suite - Annex D (半双工 backpressure) |

---

## 四、关键时钟域与 CDC

| 时钟域 | 频率 | 来源 | 驱动模块 |
|--------|------|------|----------|
| `csr_clk` | 应用相关 | 系统 PLL | CSR Slave 接口、寄存器访问 |
| `app_clk` | 应用相关 | 系统 PLL | DMA 控制器、MTL 应用侧 (ATI/ARI) |
| `gmii_tx_clk` | 125 MHz | PHY 输出 | MAC TX 路径 (TBU/TPC/TPE)、CRC 生成器 |
| `gmii_rx_clk` | 125 MHz | PHY 输出 | MAC RX 路径、CRC 检查器 |
| `mdio_clk` | ≤ 2.5 MHz | core_clk 分频 | MDIO Master / SMA |

**关键 CDC 约束**：
- `gmii_tx_clk` 和 `gmii_rx_clk` 始终是异步关系，即使标称频率相同
- 所有 GMII ↔ core_clk 的跨域必须通过异步 FIFO (MTL 层提供双端口 RAM 控制器)
- 异步 FIFO 使用 Gray 码指针同步
- MTL 支持同步 (SPRAM, 单一时钟) 或异步 (DPRAM, 双时钟) FIFO

---

## 五、可配置参数范围

| 参数 | 范围/选项 |
|------|----------|
| 数据总线宽度 | 32 / 64 / 128 bit |
| Tx 队列数 | 1 ~ 8 |
| Rx 队列数 | 1 ~ 8 |
| Tx 队列大小 | 256B ~ 128KB |
| Rx 队列大小 | 256B ~ 256KB |
| DMA 通道数 | Tx 1~8, Rx 1~8 |
| 描述符缓冲区大小 | 最大 32KB/描述符 |
| AXI 地址宽度 | 32 / 40 / 48 bit |
| AXI 未完成事务 | 最大 32 个 (读写各) |
| DA 精确匹配过滤器 | 31 (基础) + 96 (可选) |
| SA 比较过滤器 | 31 |
| Hash 表大小 | 32 / 64 / 128 / 256 bit |
| VLAN Filter | 4 / 8 / 16 / 32 (扩展) |
| Jumbo Frame | 最大 16KB |
| IFG 可编程范围 | 40 ~ 96 bit times (步长 8) |
| 中断聚合周期 | 1μs ~ 4096μs |
| TSN Gate Control List | 可配置 |
| GPIO | 最多 16 个 (可编程中断边沿) |
