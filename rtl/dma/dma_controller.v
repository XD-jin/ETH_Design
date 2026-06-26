// ============================================================================
// Module: DMA_CONTROLLER
// File:    dma_controller.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: DMA Controller top-level — 2 TX channels + 2 RX channels,
//   bus arbiter, and interrupt controller.
// ============================================================================

module dma_controller #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,           // hclk

    // CSR register inputs
    input  wire [31:0] cfg_dma_mode,
    input  wire [31:0] cfg_dma_sysbus_mode,
    input  wire [31:0] cfg_dma_intr_enable,
    input  wire [15:0] cfg_coalesce_timer,
    // Channel 0 TX
    input  wire        ch0_tx_start,
    input  wire [31:0] ch0_tx_desc_base,
    input  wire [ 7:0] ch0_tx_desc_tail,
    input  wire [ 7:0] ch0_tx_desc_len,
    // Channel 0 RX
    input  wire        ch0_rx_start,
    input  wire [31:0] ch0_rx_desc_base,
    input  wire [ 7:0] ch0_rx_desc_tail,
    input  wire [ 7:0] ch0_rx_desc_len,
    // Channel 1 TX/RX (same structure, omitted for brevity)

    // AHB Master interface (shared)
    output wire        ahb_req,
    input  wire        ahb_grant,
    output wire [31:0] ahb_addr,
    output wire [31:0] ahb_wdata,
    input  wire [31:0] ahb_rdata,
    output wire [ 3:0] ahb_burst,
    output wire        ahb_write,
    input  wire        ahb_ready,
    input  wire        ahb_error,

    // ATI interface (to MTL TX)
    output wire        ati_val,
    input  wire        ati_rdy,
    output wire [31:0] ati_data,
    output wire        ati_sop,
    output wire        ati_eop,
    output wire [ 1:0] ati_be,
    output wire        ati_queue,

    // ARI interface (from MTL RX)
    input  wire        ari_val,
    output wire        ari_rdy,
    input  wire [31:0] ari_data,
    input  wire        ari_sop,
    input  wire        ari_eop,

    // Interrupt
    output wire        intr_o,
    output wire [ 3:0] intr_status
);

    // Channel request/grant wires
    wire [1:0] tx_ch_req, rx_ch_req;
    wire [1:0] tx_arb_grant, rx_arb_grant;
    wire       bus_to_tx;

    // Per-channel signals
    wire [1:0] ch_tx_done, ch_rx_done;
    wire [1:0] ch_tx_error, ch_rx_error;
    wire [1:0] ch_tx_suspend, ch_rx_suspend;

    // Per-channel AHB interfaces (muxed)
    wire [31:0] tx0_ahb_addr, tx1_ahb_addr;
    wire [31:0] tx0_ahb_data, tx1_ahb_data;
    wire [ 3:0] tx0_ahb_burst, tx1_ahb_burst;
    wire        tx0_ahb_req, tx1_ahb_req;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req    = 1'b0;
            assign ahb_addr   = 32'd0;
            assign ahb_wdata  = 32'd0;
            assign ahb_burst  = 4'd0;
            assign ahb_write  = 1'b0;
            assign ati_val    = 1'b0;
            assign ati_data   = 32'd0;
            assign ati_sop    = 1'b0;
            assign ati_eop    = 1'b0;
            assign ati_be     = 2'd0;
            assign ati_queue  = 1'b0;
            assign ari_rdy    = 1'b1;
            assign intr_o     = 1'b0;
            assign intr_status = 4'd0;
        end else begin : gen_active

            // TX Channel 0
            dma_tx_channel #(.P_RING_LEN(64)) u_tx_ch0 (
                .clk          (clk),
                .rst_n        (rst_n),
                .ch_start     (ch0_tx_start),
                .desc_base    (ch0_tx_desc_base),
                .desc_tail    (ch0_tx_desc_tail),
                .desc_len     (ch0_tx_desc_len),
                .tx_pbl       (cfg_dma_mode[7:3]),
                .ahb_req      (tx0_ahb_req),
                .ahb_grant    (bus_to_tx && (tx_arb_grant == 2'd0)),
                .ahb_addr     (tx0_ahb_addr),
                .ahb_burst    (tx0_ahb_burst),
                .ahb_rdata    (ahb_rdata),
                .ahb_ready    (ahb_ready),
                .ahb_error    (ahb_error),
                .ati_val      (ati_val),
                .ati_rdy      (ati_rdy),
                .ati_data     (ati_data),
                .ati_sop      (ati_sop),
                .ati_eop      (ati_eop),
                .ati_be       (ati_be),
                .ch_done      (ch_tx_done[0]),
                .ch_error     (ch_tx_error[0]),
                .ch_suspended (ch_tx_suspend[0])
            );

            // Simplified: TX Ch1 not fully shown, RX channels connect to ARI
            // In production code, all 4 channels are instantiated

            dma_arbiter #(.P_NUM_TX_CH(2), .P_NUM_RX_CH(2)) u_arbiter (
                .clk          (clk),
                .rst_n        (rst_n),
                .tx_req       (tx_ch_req),
                .rx_req       (rx_ch_req),
                .tx_priority  (cfg_dma_mode[1]),
                .tx_pri_ratio (cfg_dma_mode[14:12]),
                .tx_grant     (tx_arb_grant),
                .rx_grant     (rx_arb_grant),
                .bus_to_tx    (bus_to_tx)
            );

            dma_intr_ctrl u_intr (
                .clk            (clk),
                .rst_n          (rst_n),
                .intr_sources   ({ch_rx_done[1], ch_tx_done[1], ch_rx_done[0], ch_tx_done[0]}),
                .intr_enable    (cfg_dma_intr_enable[3:0]),
                .coalesce_timer (cfg_coalesce_timer),
                .intr_o         (intr_o)
            );

            // Mux AHB signals from selected channel
            assign ahb_addr  = bus_to_tx ? (tx_arb_grant == 2'd0 ? tx0_ahb_addr : 32'd0) : 32'd0;
            assign ahb_wdata = 32'd0;  // TX reads, RX writes — mux per channel
            assign ahb_burst = bus_to_tx ? tx0_ahb_burst : 4'd0;
            assign ahb_write = ~bus_to_tx;  // TX=Read, RX=Write
            assign ahb_req   = tx0_ahb_req;

            assign tx_ch_req = {1'b0, tx0_ahb_req};  // Ch0 only in V1.0 skeleton
            assign rx_ch_req = 2'd0;
            assign ati_queue = 1'b0;
            assign ari_rdy   = 1'b1;

            assign intr_status = {ch_rx_done[1], ch_tx_done[1], ch_rx_done[0], ch_tx_done[0]};
        end
    endgenerate

endmodule
