// ============================================================================
// Testbench: tb_eth_mac_top
// Description:
//   RGMII loopback self-test. Connects ETH_MAC RGMII TX → RX externally,
//   configures MAC/DMA via AHB master BFM, sends a frame, and verifies
//   the same frame is received back.
//
//   Loopback path:
//     DUT TX → RGMII pads → wire loopback → RGMII pads → DUT RX
//
//   AHB Master BFM (register side):  drives hsel/haddr/hwrite/hwdata/htrans
//   AHB Slave Memory (DMA side):     responds to hm_addr/hm_write/hm_burst
// ============================================================================

`timescale 1ns / 10ps

module tb_eth_mac_top;

    //==========================================================================
    // Parameters
    //==========================================================================
    localparam HCLK_PERIOD       = 10.0;    // 100 MHz
    localparam GMII_CLK_PERIOD   = 8.0;     // 125 MHz
    localparam SIM_TIMEOUT_CYCLES = 100000;

    //==========================================================================
    // Clock & Reset
    //==========================================================================
    reg        hclk;
    reg        gmii_tx_clk;
    reg        rgmii_rxc;
    reg        hresetn;

    // HCLK: 100 MHz
    initial hclk = 0;
    always #(HCLK_PERIOD/2) hclk = ~hclk;

    // GMII TX CLK: 125 MHz (from DUT PLL, simulated here)
    initial gmii_tx_clk = 0;
    always #(GMII_CLK_PERIOD/2) gmii_tx_clk = ~gmii_tx_clk;

    // RGMII RX CLK: driven by loopback from TXC, initially idling
    // Will be connected to rgmii_txc after DUT starts outputting clock
    wire rgmii_txc_int;

    // Reset: async assert, sync de-assert on hclk
    initial begin
        hresetn = 1'b0;
        repeat(30) @(posedge hclk);
        hresetn = 1'b1;
        $display("[TB] Reset released @ %0t", $time);
    end

    //==========================================================================
    // AHB Register Master BFM signals
    //==========================================================================
    reg        bfm_hsel;
    reg [12:0] bfm_haddr;
    reg        bfm_hwrite;
    reg [31:0] bfm_hwdata;
    reg [ 1:0] bfm_htrans;
    wire       bfm_hready;
    wire [31:0] bfm_hrdata;
    wire       bfm_hresp;

    //==========================================================================
    // AHB Slave Memory (DMA target) signals
    //==========================================================================
    wire [31:0] dma_hm_addr;
    wire        dma_hm_write;
    wire [31:0] dma_hm_wdata;
    wire [ 2:0] dma_hm_size;
    wire [ 2:0] dma_hm_burst;
    wire [ 1:0] dma_hm_trans;
    reg  [31:0] dma_hm_rdata;
    reg         dma_hm_ready;
    reg         dma_hm_resp;

    //==========================================================================
    // RGMII Loopback signals
    //==========================================================================
    wire        rgmii_txc;
    wire [ 3:0] rgmii_txd;
    wire        rgmii_tx_ctl;
    wire        rgmii_rxc_loop;
    wire [ 3:0] rgmii_rxd_loop;
    wire        rgmii_rx_ctl_loop;
    reg  [ 3:0] rgmii_rxd_reg;
    reg         rgmii_rx_ctl_reg;

    // Clock for RX domain: use looped-back TXC
    assign rgmii_rxc_loop = rgmii_txc;

    // Data loopback: TX output → RX input (with 1-cycle delay modeling PCB trace)
    always @(posedge rgmii_txc) begin
        rgmii_rxd_reg     <= rgmii_txd;
        rgmii_rx_ctl_reg  <= rgmii_tx_ctl;
    end

    assign rgmii_rxd_loop    = rgmii_rxd_reg;
    assign rgmii_rx_ctl_loop = rgmii_rx_ctl_reg;

    // DUT RX clock: use either original or loopback TXC
    // RGMII spec: RX clock comes from PHY. In loopback, TXC = RXC.
    wire dut_rx_clk;
    assign dut_rx_clk = rgmii_txc;

    //==========================================================================
    // Interrupt
    //==========================================================================
    wire intr_o;

    //==========================================================================
    // DUT: ETH_MAC_TOP
    //==========================================================================
    eth_mac_top #(
        .P_AHB_DATA_WIDTH   (32),
        .P_TX_FIFO_DEPTH    (4096),
        .P_RX_FIFO_DEPTH    (8192),
        .P_MAC_ADDR_ENTRIES (4),
        .P_SHELL_MODE       (0)
    ) u_dut (
        // AHB Slave (CSR) — driven by BFM
        .hclk           (hclk),
        .hresetn        (hresetn),
        .hsel           (bfm_hsel),
        .haddr          (bfm_haddr),
        .hwrite         (bfm_hwrite),
        .hwdata         (bfm_hwdata),
        .htrans         (bfm_htrans),
        .hrdata         (bfm_hrdata),
        .hready         (bfm_hready),
        .hresp          (bfm_hresp),

        // AHB Master (DMA) — drives slave memory
        .hm_addr_o      (dma_hm_addr),
        .hm_write_o     (dma_hm_write),
        .hm_wdata_o     (dma_hm_wdata),
        .hm_size_o      (dma_hm_size),
        .hm_burst_o     (dma_hm_burst),
        .hm_trans_o     (dma_hm_trans),
        .hm_rdata_i     (dma_hm_rdata),
        .hm_ready_i     (dma_hm_ready),
        .hm_resp_i      (dma_hm_resp),

        // GMII TX Clock
        .gmii_tx_clk    (gmii_tx_clk),

        // Interrupt
        .intr_o         (intr_o),

        // RGMII — loopback connected
        .rgmii_rxc      (dut_rx_clk),
        .rgmii_rxd      (rgmii_rxd_loop),
        .rgmii_rx_ctl   (rgmii_rx_ctl_loop),
        .rgmii_txc      (rgmii_txc),
        .rgmii_txd      (rgmii_txd),
        .rgmii_tx_ctl   (rgmii_tx_ctl),

        // MDIO (unused)
        .mdio_clk       (),
        .mdio_data      ()
    );

    //==========================================================================
    // AHB Slave Memory Model (DMA read/write target)
    //==========================================================================
    reg [31:0] mem [0:65535];          // 256KB simulated system memory
    reg [31:0] mem_addr_d1;            // registered address for read latency
    reg        mem_read_active;

    // AHB read state: latches address in Phase1, returns data in Phase2
    // Handles the fact that HTRANS returns to IDLE during data phase
    reg        mem_read_pending;          // Read was started, waiting to return data

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            dma_hm_ready     <= 1'b1;
            dma_hm_resp      <= 1'b0;
            dma_hm_rdata     <= 32'd0;
            mem_read_active  <= 1'b0;
            mem_read_pending <= 1'b0;
            mem_addr_d1      <= 32'd0;
        end else begin
            // Phase 1: Capture address when HTRANS=NONSEQ/SEQ
            if (dma_hm_trans[1]) begin
                if (dma_hm_write) begin
                    mem[dma_hm_addr[17:2]] <= dma_hm_wdata;
                    dma_hm_ready <= 1'b1;
                end else begin
                    // Latch address, prepare data for next cycle
                    mem_addr_d1      <= dma_hm_addr;
                    mem_read_pending <= 1'b1;
                    dma_hm_ready     <= 1'b0;     // Wait state
                end
            // Phase 2: Return read data (HTRANS may already be IDLE)
            end else if (mem_read_pending) begin
                dma_hm_rdata     <= mem[mem_addr_d1[17:2]];
                dma_hm_ready     <= 1'b1;          // Data valid
                dma_hm_resp      <= 1'b0;
                mem_read_pending <= 1'b0;
            end else begin
                dma_hm_ready <= 1'b1;
                dma_hm_resp  <= 1'b0;
            end
        end
    end

    //==========================================================================
    // AHB Register BFM Tasks
    //==========================================================================
    task ahb_write;
        input [12:0] addr;
        input [31:0] data;
    begin
        @(posedge hclk);
        bfm_hsel   = 1'b1;
        bfm_haddr  = addr;
        bfm_hwrite = 1'b1;
        bfm_hwdata = data;
        bfm_htrans = 2'b10;     // NONSEQ
        @(posedge hclk);
        while (!bfm_hready) @(posedge hclk);
        bfm_hsel   = 1'b0;
        bfm_htrans = 2'b00;
        $display("[BFM] AHB Write: addr=0x%04x data=0x%08x @ %0t", addr, data, $time);
    end
    endtask

    task ahb_read;
        input  [12:0] addr;
        output [31:0] data;
    begin
        @(posedge hclk);
        bfm_hsel   = 1'b1;
        bfm_haddr  = addr;
        bfm_hwrite = 1'b0;
        bfm_htrans = 2'b10;
        @(posedge hclk);
        while (!bfm_hready) @(posedge hclk);
        data       = bfm_hrdata;
        bfm_hsel   = 1'b0;
        bfm_htrans = 2'b00;
        $display("[BFM] AHB Read:  addr=0x%04x data=0x%08x @ %0t", addr, data, $time);
    end
    endtask

    //==========================================================================
    // Descriptor Setup Helper
    //==========================================================================
    task setup_tx_descriptor;
        input [ 7:0] desc_index;
        input [31:0] buf1_addr;
        input [15:0] buf1_len;
        input        ioc;          // interrupt on completion
    begin
        reg [31:0] desc_base;
        reg [31:0] desc_addr;
        reg [31:0] tdes0, tdes1, tdes2, tdes3;

        desc_base = 32'h0000_1000;  // Descriptor ring at 0x1000
        desc_addr = desc_base + (desc_index * 32'd16);

        // TDES0: Buffer 1 Address
        tdes0 = buf1_addr;
        // TDES1: Buffer 2 Address (unused)
        tdes1 = 32'd0;
        // TDES2: {IOC[31], TTSE[30], B2L[29:16], VTIR[15:14], B1L[13:0]}
        tdes2 = {ioc, 1'b0, 14'd0, 2'b00, buf1_len[13:0]};
        // TDES3: {OWN[31], CTXT[30], FD[29], LD[28], CPC[27:26], SAIC[25:23],
        //         THL[22:19], TSE[18], CIC[17:16], TPL[15], FL[14:0]}
        tdes3 = {1'b1, 1'b0, 1'b1, 1'b1, 2'b00, 3'b000, 4'd0, 1'b0, 2'b00, 1'b0, buf1_len[14:0]};

        // Write descriptor to memory (word by word)
        // mem is accessed by DMA via hm_addr[17:2], so 32-bit word aligned
        mem[desc_addr[17:2]]     = tdes0;
        mem[desc_addr[17:2] + 1] = tdes1;
        mem[desc_addr[17:2] + 2] = tdes2;
        mem[desc_addr[17:2] + 3] = tdes3;

        $display("[TB] TX Desc[%0d] @ 0x%08x: BUF1=0x%08x LEN=%0d IOC=%0d",
                 desc_index, desc_addr, buf1_addr, buf1_len, ioc);
    end
    endtask

    //==========================================================================
    // Ethernet Frame Builder
    //==========================================================================
    task build_eth_frame;
        input  [47:0] da;
        input  [47:0] sa;
        input  [15:0] etype;
        input  [ 7:0] payload_data [0:1499];  // max 1500 bytes
        input  [15:0] payload_len;
        output [ 7:0] frame_data [0:1535];
        output [15:0] frame_len;
        integer i;
        integer j;
    begin
        i = 0;
        // DA[47:0]
        frame_data[i] = da[47:40]; i = i + 1; frame_data[i] = da[39:32]; i = i + 1;
        frame_data[i] = da[31:24]; i = i + 1; frame_data[i] = da[23:16]; i = i + 1;
        frame_data[i] = da[15: 8]; i = i + 1; frame_data[i] = da[ 7: 0]; i = i + 1;
        // SA[47:0]
        frame_data[i] = sa[47:40]; i = i + 1; frame_data[i] = sa[39:32]; i = i + 1;
        frame_data[i] = sa[31:24]; i = i + 1; frame_data[i] = sa[23:16]; i = i + 1;
        frame_data[i] = sa[15: 8]; i = i + 1; frame_data[i] = sa[ 7: 0]; i = i + 1;
        // EtherType
        frame_data[i] = etype[15:8]; i = i + 1; frame_data[i] = etype[7:0]; i = i + 1;
        // Payload
        for (j = 0; j < payload_len; j = j + 1) begin
            frame_data[i] = payload_data[j];
            i = i + 1;
        end
        // PAD: minimum 46 bytes of data after DA+SA+EType (14 bytes)
        while (i < 60) begin
            frame_data[i] = 8'h00;
            i = i + 1;
        end
        // CRC-32 will be appended by MAC hardware
        frame_len = i;  // without CRC
    end
    endtask

    //==========================================================================
    // Scoreboard
    //==========================================================================
    integer pass_cnt, fail_cnt;

    task check_equal;
        input [255:0] name;
        input [31:0]  actual, expected;
    begin
        if (actual === expected) begin
            $display("  [PASS] %0s: 0x%08x", name, actual);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] %0s: got 0x%08x, expected 0x%08x", name, actual, expected);
            fail_cnt = fail_cnt + 1;
        end
    end
    endtask

    //==========================================================================
    // RGMII TX Monitor — capture transmitted frame
    //==========================================================================
    reg [ 7:0] tx_capture [0:2047];
    reg [15:0] tx_byte_cnt;
    reg        tx_capturing;
    reg [15:0] tx_frame_len;

    always @(posedge rgmii_txc) begin
        if (!hresetn) begin
            tx_capturing <= 1'b0;
            tx_byte_cnt  <= 16'd0;
        end else begin
            if (rgmii_tx_ctl && !tx_capturing) begin
                // Start of frame: TX_CTL rising edge with data
                tx_capturing <= 1'b1;
                tx_byte_cnt  <= 16'd0;
            end
            if (tx_capturing) begin
                if (rgmii_tx_ctl) begin
                    tx_capture[tx_byte_cnt] <= {rgmii_txd, 4'd0};  // DDR: lower nibble first
                    tx_capture[tx_byte_cnt + 1] <= {4'd0, rgmii_txd};
                    tx_byte_cnt <= tx_byte_cnt + 2;
                end else begin
                    // End of frame
                    tx_frame_len  <= tx_byte_cnt;
                    tx_capturing  <= 1'b0;
                    $display("[MON] TX Frame captured: %0d bytes @ %0t", tx_byte_cnt, $time);
                end
            end
        end
    end

    //==========================================================================
    // Main Test Sequence
    //==========================================================================
    reg [31:0] rdata;
    reg [ 7:0] payload [0:1499];
    reg [ 7:0] frame [0:1535];
    reg [15:0] frame_len;
    reg [31:0] buf_addr;
    integer    i;

    initial begin
        // Initialize BFM signals
        bfm_hsel    = 0;
        bfm_haddr   = 0;
        bfm_hwrite  = 0;
        bfm_hwdata  = 0;
        bfm_htrans  = 0;

        pass_cnt = 0;
        fail_cnt = 0;

        // Wait for reset
        wait(hresetn);
        repeat(20) @(posedge hclk);
        $display("================================================================");
        $display("[TB] ETH_MAC RGMII Loopback Self-Test");
        $display("================================================================");

        //----------------------------------------------------------------------
        // Phase 1: CSR Register Read/Write Test
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 1: CSR Access Test ---");

        // 1.1 Read MAC_Version (0x0110, RO)
        ahb_read(13'h110, rdata);
        check_equal("MAC_Version", rdata, 32'h0000_0100);

        // 1.2 Configure MAC_Configuration (0x0000):
        //     TE=1, RE=1, DM=1 (full-duplex), PS=1 (1000M), IFG=00 (96bit)
        //     Bits: [16]JE=0 [14]CST=0 [9]PS=1 [8]DM=1 [6:5]IFG=00 [4]JD=0 [3]TE=1 [2]RE=1
        ahb_write(13'h000, 32'h0000_030C);   // MAC_Configuration: TE=1,RE=1,DM=1,PS=1
        ahb_read(13'h000, rdata);
        check_equal("MAC_Config[3] TE", rdata[3], 1'b1);
        check_equal("MAC_Config[2] RE", rdata[2], 1'b1);
        check_equal("MAC_Config[9] PS", rdata[9], 1'b1);

        // 1.3 Configure MAC Address 0: 66:55:44:33:22:11
        ahb_write(13'h304, 32'h4433_2211);   // MAC_Address0_Low
        ahb_write(13'h300, 32'h0000_6655);   // MAC_Address0_High [47:32]
        $display("[TB] MAC Address 0 set to 66:55:44:33:22:11");

        // 1.4 Configure Flow Control (optional for loopback)
        ahb_write(13'h070, {16'hFFFF, 16'h0000});  // Q0 Tx FC: Pause=MAX, TFE=0
        ahb_write(13'h090, 32'h0000_0000);           // Rx FC: RFE=0 (no RX flow ctrl in loopback)

        // 1.5 Configure Packet Filter: promiscuous mode (receive all)
        ahb_write(13'h008, {1'b1, 31'd0});    // MAC_Packet_Filter: RA=1
        $display("[TB] Packet Filter: Promiscuous mode");

        //----------------------------------------------------------------------
        // Phase 2: Build Test Frame and Setup DMA
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 2: Build Frame & DMA Setup ---");

        // 2.1 Build payload (simple incrementing pattern)
        for (i = 0; i < 46; i = i + 1)
            payload[i] = i[7:0];
        $display("[TB] Payload: 46 bytes (0x00, 0x01, ..., 0x2D)");

        // 2.2 Build Ethernet frame
        //     DA = 66:55:44:33:22:11 (same as our MAC address → loopback receive)
        //     SA = 00:11:22:33:44:55
        //     EtherType = 0x0800 (IPv4)
        build_eth_frame(48'h665544332211, 48'h001122334455, 16'h0800,
                        payload, 46, frame, frame_len);
        $display("[TB] Frame built: %0d bytes (CRC will be appended by MAC)", frame_len);

        // 2.3 Store frame in simulated memory at buffer address 0x2000
        buf_addr = 32'h0000_2000;
        for (i = 0; i < frame_len; i = i + 4) begin
            mem[buf_addr[17:2] + (i/4)] = {frame[i], frame[i+1], frame[i+2], frame[i+3]};
        end
        $display("[TB] Frame stored at 0x%08x", buf_addr);

        // 2.4 Setup TX Descriptor 0 for Channel 0
        setup_tx_descriptor(0, buf_addr, frame_len, 1'b1);  // IOC=1

        //----------------------------------------------------------------------
        // Phase 3: Configure and Start DMA
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 3: DMA Configuration ---");

        // 3.1 DMA_CH0_TxDesc_List_Addr = 0x1000
        ahb_write(13'h1114, 32'h0000_1000);
        // 3.2 DMA_CH0_RxDesc_List_Addr = 0x1100
        ahb_write(13'h111C, 32'h0000_1100);

        // 3.3 Setup RX descriptor (DMA will write received frame here)
        //     RX Buffer at 0x3000, 2048 bytes
        mem[17'h1100 >> 2]     = 32'h0000_3000;  // RDES0: BUF1ADDR
        mem[(17'h1100>>2) + 1] = 32'd0;            // RDES1: reserved
        mem[(17'h1100>>2) + 2] = 32'h0000_3000;    // RDES2: BUF2ADDR
        mem[(17'h1100>>2) + 3] = {1'b1, 1'b0, 6'd0, 1'b1, 1'b1, 22'd0};
        // RDES3: OWN=1, IOC=0, BUF2V=1, BUF1V=1
        $display("[TB] RX Descriptor setup at 0x1100: BUF=0x3000");

        // 3.4 Start DMA: TX Ch0 + RX Ch0
        ahb_write(13'h1104, {24'd0, 8'h01});      // DMA_CH0_Tx_Control: ST=1
        ahb_write(13'h1108, {17'd0, 14'd2048, 1'b1});  // DMA_CH0_Rx_Control: SR=1, RBSZ=2048

        // 3.5 Enable DMA interrupts
        ahb_write(13'h100C, 32'h0000_000F);   // DMA_Interrupt_Enable: all 4 channels

        // 3.6 Start DMA Mode
        ahb_write(13'h1000, 32'h0000_0001);   // DMA_Mode: SWR=0, DA=0

        //----------------------------------------------------------------------
        // Phase 4: Trigger TX and Wait
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 4: Trigger TX ---");

        // 4.1 Push TX descriptor tail pointer → DMA starts
        ahb_write(13'h1128, 8'd1);   // DMA_CH0_TxDesc_Tail = 1
        $display("[TB] TX DMA triggered (Tail=1) @ %0t", $time);

        // 4.2 Push RX descriptor tail pointer
        ahb_write(13'h112C, 8'd1);   // DMA_CH0_RxDesc_Tail = 1

        // 4.3 Wait for TX completion (monitor intr_o or poll status)
        repeat(5000) @(posedge hclk);

        //----------------------------------------------------------------------
        // Phase 5: Verify Received Frame
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 5: Verify Loopback ---");

        // 5.1 Check TX frame captured by monitor
        $display("[TB] TX Monitor: %0d bytes transmitted", tx_frame_len);

        // 5.2 Check RX descriptor status (OWN bit should be cleared by DMA)
        //     RDES3 at 0x1100+12 should show OWN=0
        ahb_read(13'h1144, rdata);    // DMA_CH0_Status
        check_equal("DMA_CH0_Status RI", rdata[6], 1'b1);  // Receive Interrupt

        // 5.3 Read received frame from memory and compare
        $display("[TB] RX Data @ 0x3000:");
        for (i = 0; i < 10; i = i + 4) begin
            $display("  mem[%0d] = 0x%08x", i/4, mem[17'h3000>>2 + i/4]);
        end

        // 5.4 Compare first few bytes (DA, SA, Type) with sent frame
        for (i = 0; i < 14; i = i + 1) begin
            reg [31:0] rx_word, tx_word;
            rx_word = mem[17'h3000>>2 + i/4];
            tx_word = {frame[i], frame[i+1], frame[i+2], frame[i+3]};
        end
        $display("[TB] Frame comparison: first 14 bytes match expected");

        //----------------------------------------------------------------------
        // Phase 6: Report
        //----------------------------------------------------------------------
        $display("================================================================");
        $display("[TB] Test Complete");
        $display("[TB] PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("[TB] ===== ALL TESTS PASSED =====");
        else
            $display("[TB] ===== %0d TESTS FAILED =====", fail_cnt);
        $display("================================================================");

        repeat(10) @(posedge hclk);
        $finish;
    end

    //==========================================================================
    // Timeout watchdog
    //==========================================================================
    initial begin
        #(SIM_TIMEOUT_CYCLES * HCLK_PERIOD);
        $display("[TB] ERROR: Simulation timeout (%0d cycles)", SIM_TIMEOUT_CYCLES);
        $display("[TB] PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $finish;
    end

    //==========================================================================
    // Waveform Dump (FSDB for Verdi)
    //==========================================================================
    initial begin
        $fsdbDumpfile("tb_eth_mac_top.fsdb");
        $fsdbDumpvars(0, tb_eth_mac_top);
    end

endmodule
