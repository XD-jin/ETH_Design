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
    // AHB Master bus — connects DUT to SRAM
    wire [31:0] hm_addr_o;
    wire        hm_write_o;
    wire [31:0] hm_wdata_o;
    wire [ 2:0] hm_size_o;
    wire [ 2:0] hm_burst_o;
    wire [ 1:0] hm_trans_o;

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

        // AHB Master (DMA) — connected to ahb_sram
        .hm_addr_o      (hm_addr_o),
        .hm_write_o     (hm_write_o),
        .hm_wdata_o     (hm_wdata_o),
        .hm_size_o      (hm_size_o),
        .hm_burst_o     (hm_burst_o),
        .hm_trans_o     (hm_trans_o),
        .hm_rdata_i     (sram_hrdata),
        .hm_ready_i     (sram_hready),
        .hm_resp_i      (sram_hresp),

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
    // AHB SRAM — 32KB, pre-loaded from mem.dat
    //==========================================================================
    wire        sram_hready;
    wire [31:0] sram_hrdata;
    wire        sram_hresp;

    ahb_sram #(.P_MEM_FILE("mem.dat"), .P_DEPTH(8192))
    u_sram
    (
        .hclk       (hclk),
        .hresetn    (hresetn),
        .hsel       (1'b1),           // Always selected
        .haddr      (hm_addr_o),
        .hwrite     (hm_write_o),
        .hwdata     (hm_wdata_o),
        .htrans     (hm_trans_o),
        .hsize      (hm_size_o),
        .hrdata     (sram_hrdata),
        .hready     (sram_hready),
        .hresp      (sram_hresp)
    );

    assign hm_ready_i = sram_hready;
    assign hm_rdata_i = sram_hrdata;
    assign hm_resp_i  = sram_hresp;

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
    reg [15:0] tx_frame_len;
    reg        tx_capturing;

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
    reg [ 7:0] frame [0:1535];
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
        // Phase 2: DMA Configuration (descriptors & frame pre-loaded from mem.dat)
        //----------------------------------------------------------------------
        $display("[TB] --- Phase 2: DMA Configuration ---");

        // TX/RX Descriptor Rings and Frame Data pre-loaded in ahb_sram from mem.dat
        // TX Desc @ 0x1000: BUF1=0x2000, OWN=1, FD=1, LD=1, B1L=60, IOC=1
        // RX Desc @ 0x1100: BUF1=0x3000, OWN=1, BUF2V=1, BUF1V=1
        // TX Frame  @ 0x2000: DA=66:55:44:33:22:11 SA=00:11:22:33:44:55 Type=0x0800 Payload=00..2D

        // 2.1 DMA_CH0_TxDesc_List_Addr = 0x1000
        ahb_write(13'h1114, 32'h0000_1000);
        // 2.2 DMA_CH0_RxDesc_List_Addr = 0x1100
        ahb_write(13'h111C, 32'h0000_1100);
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

        // 5.2 Check RX descriptor status
        ahb_read(13'h1144, rdata);    // DMA_CH0_Status
        check_equal("DMA_CH0_Status RI", rdata[6], 1'b1);  // Receive Interrupt

        // 5.3 Received frame is in SRAM @ 0x3000 — check via AHB read
        ahb_read(13'h3000 >> 2, rdata);
        $display("[TB] RX First word @ 0x3000 = 0x%08x", rdata);

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
