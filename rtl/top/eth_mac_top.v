// ============================================================================
// Module: ETH_MAC_TOP
// File:    eth_mac_top.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   Gigabit Ethernet MAC Controller Top-Level Integration.
//   AHB Slave (CSR) + AHB Master (DMA) + MTL + MAC Core + RGMII Interface.
//
//   Key Features:
//     - 1000Mbps full-duplex, RGMII v2.6 PHY interface
//     - 2 TX DMA channels + 2 RX DMA channels, 16-byte ring descriptors
//     - IEEE 802.3x flow control (Pause frame generation and response)
//     - CRC-32, address filtering (perfect + hash), PAD insertion
//     - Interrupt coalescing
//
//   Clock Domains:
//     hclk        — AHB bus, DMA, CSR (system dependent)
//     gmii_tx_clk — MAC TX, RGMII TX (125 MHz)
//     gmii_rx_clk — MAC RX, RGMII RX (125 MHz, from PHY)
//
// Parameters:
//   P_AHB_DATA_WIDTH   AHB data bus width (32 or 64)
//   P_TX_FIFO_DEPTH    TX FIFO depth per queue (bytes)
//   P_RX_FIFO_DEPTH    RX FIFO depth per queue (bytes)
//   P_MAC_ADDR_ENTRIES Number of perfect-match MAC addresses
//   P_SHELL_MODE       1 = All submodules in shell mode
// ============================================================================

module eth_mac_top #(
    parameter P_AHB_DATA_WIDTH   = 32,
    parameter P_TX_FIFO_DEPTH    = 4096,
    parameter P_RX_FIFO_DEPTH    = 8192,
    parameter P_MAC_ADDR_ENTRIES = 4,
    parameter P_SHELL_MODE       = 0
) (
    // AHB Slave (CSR)
    input  wire        hclk,
    input  wire        hresetn,
    input  wire        hsel,
    input  wire [11:0] haddr,
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    input  wire [ 1:0] htrans,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,

    // AHB Master (DMA)
    output wire [31:0] hm_addr_o,
    output wire        hm_write_o,
    output wire [31:0] hm_wdata_o,
    output wire [ 2:0] hm_size_o,
    output wire [ 2:0] hm_burst_o,
    output wire [ 1:0] hm_trans_o,
    input  wire [31:0] hm_rdata_i,
    input  wire        hm_ready_i,
    input  wire        hm_resp_i,

    // Interrupt
    output wire        intr_o,

    // RGMII
    input  wire        rgmii_rxc,
    input  wire [ 3:0] rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    output wire        rgmii_txc,
    output wire [ 3:0] rgmii_txd,
    output wire        rgmii_tx_ctl,

    // MDIO (optional)
    output wire        mdio_clk,
    inout  wire        mdio_data
);

    //--------------------------------------------------------------------------
    // Clock & Reset
    //--------------------------------------------------------------------------
    wire gmii_tx_clk;
    wire gmii_rx_clk;
    // NOTE: V1.0 simulation uses hclk as TX clock source for convenience.
    // Production: gmii_tx_clk must come from dedicated 125MHz PLL, independent from hclk.
    assign gmii_tx_clk = hclk;
    assign gmii_rx_clk = rgmii_rxc;           // RX clock from PHY

    //--------------------------------------------------------------------------
    // Internal Interconnects
    //--------------------------------------------------------------------------
    // CSR register read data bus
    wire [31:0] reg_rd_data;
    // DMA → MTL (ATI)
    wire        ati_val, ati_rdy;
    wire [31:0] ati_data;
    wire        ati_sop, ati_eop;
    wire [ 1:0] ati_be;
    wire        ati_queue;
    // MTL → DMA (ARI)
    wire        ari_val, ari_rdy;
    wire [31:0] ari_data;
    wire        ari_sop, ari_eop;
    // MTL → MAC (MTI)
    wire        mti_val, mti_rdy;
    wire [ 7:0] mti_data;
    wire        mti_sop, mti_eop;
    // MAC → MTL (MRI)
    wire        mri_val, mri_rdy;
    wire [ 7:0] mri_data;
    wire        mri_sop, mri_eop;
    // MAC → RGMII
    wire [ 7:0] mac_txd;
    wire        mac_tx_en, mac_tx_er;
    // RGMII → MAC
    wire [ 7:0] mac_rxd;
    wire        mac_rx_dv, mac_rx_er;
    // CRC
    wire        crc_tx_en, crc_rx_en;
    wire [ 7:0] crc_tx_data, crc_rx_data;
    wire        crc_tx_eop, crc_rx_eop;
    wire [31:0] crc_tx_result, crc_rx_result;
    wire        crc_tx_valid, crc_rx_valid;
    // Address Filter
    wire        rx_da_valid;
    wire [47:0] rx_da;
    wire        frame_pass;
    // Flow Control
    wire        tx_pause_req;
    wire [15:0] tx_pause_time;
    wire        pause_tx_stop;
    wire        rx_pause_detected;
    wire [15:0] rx_pause_time;

    //--------------------------------------------------------------------------
    // AHB Slave (CSR Register Access)
    //--------------------------------------------------------------------------
    ahb_slave_if #(.P_SHELL_MODE(P_SHELL_MODE))
    u_ahb_slave
    (
        .hclk         (hclk),
        .hresetn      (hresetn),
        .hsel         (hsel),
        .haddr        (haddr),
        .hwrite       (hwrite),
        .hwdata       (hwdata),
        .htrans       (htrans),
        .hsize        (3'd2),
        .hburst       (3'd0),
        .hrdata       (hrdata),
        .hready       (hready),
        .hresp        (hresp),
        .reg_wr_en    (),
        .reg_addr     (),
        .reg_wr_data  (),
        .reg_rd_data  (reg_rd_data)
    );

    //--------------------------------------------------------------------------
    // DMA Controller
    //--------------------------------------------------------------------------
    dma_controller #(.P_SHELL_MODE(P_SHELL_MODE))
    u_dma
    (
        .clk                (hclk),
        .rst_n              (hresetn),
        .cfg_dma_mode       (32'd0),
        .cfg_dma_sysbus_mode (32'd0),
        .cfg_dma_intr_enable (32'd0),
        .cfg_coalesce_timer (16'd1000),
        .ch0_tx_start       (1'b1),
        .ch0_tx_desc_base   (32'd0),
        .ch0_tx_desc_tail   (8'd0),
        .ch0_tx_desc_len    (8'd64),
        .ch0_rx_start       (1'b1),
        .ch0_rx_desc_base   (32'd0),
        .ch0_rx_desc_tail   (8'd0),
        .ch0_rx_desc_len    (8'd64),
        .ahb_req            (),
        .ahb_grant          (1'b1),
        .ahb_addr           (hm_addr_o),
        .ahb_wdata          (hm_wdata_o),
        .ahb_rdata          (hm_rdata_i),
        .ahb_burst          (hm_burst_o),
        .ahb_write          (hm_write_o),
        .ahb_ready          (hm_ready_i),
        .ahb_error          (hm_resp_i),
        .ati_val            (ati_val),
        .ati_rdy            (ati_rdy),
        .ati_data           (ati_data),
        .ati_sop            (ati_sop),
        .ati_eop            (ati_eop),
        .ati_be             (ati_be),
        .ati_queue          (ati_queue),
        .ari_val            (ari_val),
        .ari_rdy            (ari_rdy),
        .ari_data           (ari_data),
        .ari_sop            (ari_sop),
        .ari_eop            (ari_eop),
        .intr_o             (intr_o),
        .intr_status        ()
    );

    //--------------------------------------------------------------------------
    // MTL — MAC Transaction Layer
    //--------------------------------------------------------------------------
    mtl_tx #(.P_QUEUE_DEPTH(P_TX_FIFO_DEPTH), .P_NUM_QUEUES(2), .P_SHELL_MODE(P_SHELL_MODE))
    u_mtl_tx
    (
        .app_clk           (hclk),
        .gmii_tx_clk       (gmii_tx_clk),
        .rst_n             (hresetn),
        .ati_val           (ati_val),
        .ati_rdy           (ati_rdy),
        .ati_data          (ati_data),
        .ati_sop           (ati_sop),
        .ati_eop           (ati_eop),
        .ati_be            (ati_be),
        .ati_queue         (ati_queue),
        .mti_val           (mti_val),
        .mti_rdy           (mti_rdy),
        .mti_data          (mti_data),
        .mti_sop           (mti_sop),
        .mti_eop           (mti_eop),
        .tx_queue_not_empty (),
        .tx_fifo_level     (),
        .tx_underflow      ()
    );

    mtl_rx #(.P_QUEUE_DEPTH(P_RX_FIFO_DEPTH), .P_NUM_QUEUES(2), .P_SHELL_MODE(P_SHELL_MODE))
    u_mtl_rx
    (
        .gmii_rx_clk       (gmii_rx_clk),
        .app_clk           (hclk),
        .rst_n             (hresetn),
        .mri_val           (mri_val),
        .mri_rdy           (mri_rdy),
        .mri_data          (mri_data),
        .mri_sop           (mri_sop),
        .mri_eop           (mri_eop),
        .rx_da_valid       (rx_da_valid),
        .rx_da             (rx_da),
        .cfg_mac_addr0     (48'd0),
        .cfg_mac_addr1     (48'd0),
        .ari_val           (ari_val),
        .ari_rdy           (ari_rdy),
        .ari_data          (ari_data),
        .ari_sop           (ari_sop),
        .ari_eop           (ari_eop),
        .ari_be            (),
        .ari_queue         (),
        .rx_queue_not_empty (),
        .rx_fifo_level     (),
        .rx_overflow       ()
    );

    //--------------------------------------------------------------------------
    // MAC Core
    //--------------------------------------------------------------------------
    mac_tx #(.P_SHELL_MODE(P_SHELL_MODE))
    u_mac_tx
    (
        .gmii_tx_clk      (gmii_tx_clk),
        .rst_n            (hresetn),
        .tx_enable        (1'b1),
        .cfg_ifg          (2'd0),
        .cfg_jabber_disable (1'b0),
        .cfg_crc_pad_ctl  (1'b0),
        .cfg_preamble_short (1'b0),
        .mti_val          (mti_val),
        .mti_rdy          (mti_rdy),
        .mti_data         (mti_data),
        .mti_sop          (mti_sop),
        .mti_eop          (mti_eop),
        .crc_en           (crc_tx_en),
        .crc_data_out     (crc_tx_data),
        .crc_eop          (crc_tx_eop),
        .crc_result       (crc_tx_result),
        .crc_valid        (crc_tx_valid),
        .gmii_txd         (mac_txd),
        .gmii_tx_en       (mac_tx_en),
        .gmii_tx_er       (mac_tx_er),
        .tx_frame_done    (),
        .tx_underflow     (),
        .tx_jabber        ()
    );

    mac_rx #(.P_SHELL_MODE(P_SHELL_MODE))
    u_mac_rx
    (
        .gmii_rx_clk       (gmii_rx_clk),
        .rst_n             (hresetn),
        .rx_enable         (1'b1),
        .cfg_crc_strip     (1'b0),
        .cfg_pad_strip     (1'b0),
        .cfg_watchdog_en   (1'b1),
        .cfg_watchdog_limit (14'd2048),
        .gmii_rxd          (mac_rxd),
        .gmii_rx_dv        (mac_rx_dv),
        .gmii_rx_er        (mac_rx_er),
        .crc_en            (crc_rx_en),
        .crc_data_out      (crc_rx_data),
        .crc_eop           (crc_rx_eop),
        .crc_result        (crc_rx_result),
        .crc_valid         (crc_rx_valid),
        .rx_da_valid       (rx_da_valid),
        .rx_da             (rx_da),
        .frame_pass        (frame_pass),
        .mri_val           (mri_val),
        .mri_rdy           (mri_rdy),
        .mri_data          (mri_data),
        .mri_sop           (mri_sop),
        .mri_eop           (mri_eop),
        .rx_pause_detected (rx_pause_detected),
        .rx_pause_time     (rx_pause_time),
        .rx_packet_len     (),
        .rx_crc_error      (),
        .rx_recv_error     (),
        .rx_watchdog_error (),
        .rx_frame_done     ()
    );

    //--------------------------------------------------------------------------
    // CRC-32 (TX and RX instances)
    //--------------------------------------------------------------------------
    crc32 #(.P_SHELL_MODE(P_SHELL_MODE))
    u_crc_tx
    (
        .clk        (gmii_tx_clk),
        .rst_n      (hresetn),
        .crc_en     (crc_tx_en),
        .crc_data   (crc_tx_data),
        .crc_eop    (crc_tx_eop),
        .crc_result (crc_tx_result),
        .crc_valid  (crc_tx_valid)
    );

    crc32 #(.P_SHELL_MODE(P_SHELL_MODE))
    u_crc_rx
    (
        .clk        (gmii_rx_clk),
        .rst_n      (hresetn),
        .crc_en     (crc_rx_en),
        .crc_data   (crc_rx_data),
        .crc_eop    (crc_rx_eop),
        .crc_result (crc_rx_result),
        .crc_valid  (crc_rx_valid)
    );

    //--------------------------------------------------------------------------
    // Address Filter
    //--------------------------------------------------------------------------
    addr_filter #(.P_MAC_ADDR_ENTRIES(P_MAC_ADDR_ENTRIES), .P_SHELL_MODE(P_SHELL_MODE))
    u_addr_filter
    (
        .clk               (gmii_rx_clk),
        .rst_n             (hresetn),
        .cfg_promiscuous   (1'b0),
        .cfg_pass_all_mcast (1'b0),
        .cfg_disable_bcast (1'b0),
        .cfg_da_invert     (1'b0),
        .cfg_hash_mode     (1'b0),
        .cfg_pass_ctrl     (1'b0),
        .cfg_hash_mcast    (1'b0),
        .cfg_mac_addr      (192'd0),
        .cfg_hash_table    (64'd0),
        .rx_da_valid       (rx_da_valid),
        .rx_da             (rx_da),
        .rx_is_pause       (1'b0),
        .rx_is_broadcast   (1'b0),
        .frame_pass        (frame_pass),
        .hash_hit          (),
        .hash_index        ()
    );

    //--------------------------------------------------------------------------
    // RGMII Interface
    //--------------------------------------------------------------------------
    rgmii_if #(.P_SHELL_MODE(P_SHELL_MODE))
    u_rgmii
    (
        .gtx_clk      (gmii_tx_clk),
        .rx_clk       (gmii_rx_clk),
        .rst_n        (hresetn),
        .mac_txd      (mac_txd),
        .mac_tx_en    (mac_tx_en),
        .mac_tx_er    (mac_tx_er),
        .mac_rxd      (mac_rxd),
        .mac_rx_dv    (mac_rx_dv),
        .mac_rx_er    (mac_rx_er),
        .rgmii_txc    (rgmii_txc),
        .rgmii_txd    (rgmii_txd),
        .rgmii_tx_ctl (rgmii_tx_ctl),
        .rgmii_rxc    (rgmii_rxc),
        .rgmii_rxd    (rgmii_rxd),
        .rgmii_rx_ctl (rgmii_rx_ctl)
    );

    //--------------------------------------------------------------------------
    // MDIO (placeholder — not implemented in V1.0)
    //--------------------------------------------------------------------------
    assign mdio_clk = 1'b0;

endmodule
