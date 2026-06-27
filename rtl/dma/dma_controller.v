// ============================================================================
// Module: DMA_CONTROLLER
// File:    dma_controller.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
// Description: DMA Controller top-level — 2 TX + 2 RX channels, bus arbiter,
//   interrupt controller. All 4 channels fully instantiated for full TX/RX datapath.
// ============================================================================

module dma_controller #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,           // hclk domain

    // CSR register inputs (global)
    input  wire [31:0] cfg_dma_mode,
    input  wire [31:0] cfg_dma_sysbus_mode,
    input  wire [ 3:0] cfg_dma_intr_enable,
    input  wire [15:0] cfg_coalesce_timer,

    // Channel 0 TX control
    input  wire        ch0_tx_start,          ch1_tx_start,
    input  wire [31:0] ch0_tx_desc_base,      ch1_tx_desc_base,
    input  wire [ 7:0] ch0_tx_desc_tail,      ch1_tx_desc_tail,
    input  wire [ 7:0] ch0_tx_desc_len,       ch1_tx_desc_len,

    // Channel 0 RX control
    input  wire        ch0_rx_start,          ch1_rx_start,
    input  wire [31:0] ch0_rx_desc_base,      ch1_rx_desc_base,
    input  wire [ 7:0] ch0_rx_desc_tail,      ch1_rx_desc_tail,
    input  wire [ 7:0] ch0_rx_desc_len,       ch1_rx_desc_len,
    input  wire [13:0] ch0_rx_buf_size,       ch1_rx_buf_size,

    // AHB Master interface (shared, muxed by arbiter)
    output wire        ahb_req,
    input  wire        ahb_grant,
    output wire [31:0] ahb_addr,
    output wire [31:0] ahb_wdata,
    input  wire [31:0] ahb_rdata,
    output wire [ 2:0] ahb_burst,
    output wire        ahb_write,
    input  wire        ahb_ready,
    input  wire        ahb_error,

    // ATI interface (to MTL TX) — muxed from both TX channels
    output wire        ati_val,
    input  wire        ati_rdy,
    output wire [31:0] ati_data,
    output wire        ati_sop,
    output wire        ati_eop,
    output wire [ 1:0] ati_be,
    output wire        ati_queue,            // Selected TX channel (0 or 1)

    // ARI interface (from MTL RX) — demux to both RX channels
    input  wire        ari_val,
    output wire        ari_rdy,
    input  wire [31:0] ari_data,
    input  wire        ari_sop,
    input  wire        ari_eop,
    input  wire        ari_queue,            // Source RX queue (0 or 1)

    // Interrupt
    output wire        intr_o,
    output wire [ 3:0] intr_status           // {CH1_RX, CH1_TX, CH0_RX, CH0_TX}
);

    //--------------------------------------------------------------------------
    // Per-channel AHB request/grant
    //--------------------------------------------------------------------------
    wire [1:0] tx_ch_req, rx_ch_req;
    wire [1:0] tx_arb_grant, rx_arb_grant;
    wire       bus_to_tx;

    wire [31:0] tx0_ahb_addr, tx1_ahb_addr;
    wire [31:0] rx0_ahb_addr, rx1_ahb_addr;
    wire [31:0] rx0_ahb_wdata, rx1_ahb_wdata;
    wire [ 2:0] tx0_ahb_burst, tx1_ahb_burst;
    wire [ 2:0] rx0_ahb_burst, rx1_ahb_burst;
    wire        tx0_ahb_req, tx1_ahb_req;
    wire        rx0_ahb_req, rx1_ahb_req;
    wire        tx0_ahb_write, tx1_ahb_write;
    wire        rx0_ahb_write, rx1_ahb_write;

    // TX channel ATI signals (muxed to one ATI port)
    wire        tx0_ati_val, tx1_ati_val;
    wire [31:0] tx0_ati_data, tx1_ati_data;
    wire        tx0_ati_sop, tx1_ati_sop;
    wire        tx0_ati_eop, tx1_ati_eop;
    wire [ 1:0] tx0_ati_be, tx1_ati_be;

    // Per-channel completion/error signals
    wire [1:0] ch_tx_done, ch_rx_done;
    wire [1:0] ch_tx_error, ch_rx_error;

    //--------------------------------------------------------------------------
    // Channel 0 TX
    //--------------------------------------------------------------------------
    dma_tx_channel #(.P_RING_LEN(64))
    u_tx_ch0 (
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
        .ati_val      (tx0_ati_val),
        .ati_rdy      (ati_rdy && (tx_arb_grant == 2'd0)),
        .ati_data     (tx0_ati_data),
        .ati_sop      (tx0_ati_sop),
        .ati_eop      (tx0_ati_eop),
        .ati_be       (tx0_ati_be),
        .ch_done      (ch_tx_done[0]),
        .ch_error     (ch_tx_error[0]),
        .ch_suspended ()
    );
    assign tx0_ahb_write = 1'b0;     // TX always reads from memory

    //--------------------------------------------------------------------------
    // Channel 1 TX
    //--------------------------------------------------------------------------
    dma_tx_channel #(.P_RING_LEN(64))
    u_tx_ch1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .ch_start     (ch1_tx_start),
        .desc_base    (ch1_tx_desc_base),
        .desc_tail    (ch1_tx_desc_tail),
        .desc_len     (ch1_tx_desc_len),
        .tx_pbl       (cfg_dma_mode[7:3]),
        .ahb_req      (tx1_ahb_req),
        .ahb_grant    (bus_to_tx && (tx_arb_grant == 2'd1)),
        .ahb_addr     (tx1_ahb_addr),
        .ahb_burst    (tx1_ahb_burst),
.ahb_rdata    (ahb_rdata),
        .ahb_ready    (ahb_ready),
        .ahb_error    (ahb_error),
        .ati_val      (tx1_ati_val),
        .ati_rdy      (ati_rdy && (tx_arb_grant == 2'd1)),
        .ati_data     (tx1_ati_data),
        .ati_sop      (tx1_ati_sop),
        .ati_eop      (tx1_ati_eop),
        .ati_be       (tx1_ati_be),
        .ch_done      (ch_tx_done[1]),
        .ch_error     (ch_tx_error[1]),
        .ch_suspended ()
    );
    assign tx1_ahb_write = 1'b0;

    //--------------------------------------------------------------------------
    // Channel 0 RX
    //--------------------------------------------------------------------------
    dma_rx_channel #(.P_RING_LEN(64))
    u_rx_ch0 (
        .clk          (clk),
        .rst_n        (rst_n),
        .ch_start     (ch0_rx_start),
        .desc_base    (ch0_rx_desc_base),
        .desc_tail    (ch0_rx_desc_tail),
        .desc_len     (ch0_rx_desc_len),
        .rx_pbl       (cfg_dma_mode[11:8]),
        .rx_buf_size  (ch0_rx_buf_size),
        .ahb_req      (rx0_ahb_req),
        .ahb_grant    (~bus_to_tx && (rx_arb_grant == 2'd0)),
        .ahb_addr     (rx0_ahb_addr),
        .ahb_wdata    (rx0_ahb_wdata),
        .ahb_burst    (rx0_ahb_burst),
        .ahb_rdata    (ahb_rdata),
        .ahb_ready    (ahb_ready),
        .ahb_error    (ahb_error),
        .ari_val      (ari_val && (ari_queue == 1'b0)),
        .ari_rdy      (),
        .ari_data     (ari_data),
        .ari_sop      (ari_sop),
        .ari_eop      (ari_eop),
        .ch_done      (ch_rx_done[0]),
        .ch_error     (ch_rx_error[0]),
        .ch_overflow  ()
    );
    assign rx0_ahb_write = 1'b1;     // RX always writes to memory

    //--------------------------------------------------------------------------
    // Channel 1 RX
    //--------------------------------------------------------------------------
    dma_rx_channel #(.P_RING_LEN(64))
    u_rx_ch1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .ch_start     (ch1_rx_start),
        .desc_base    (ch1_rx_desc_base),
        .desc_tail    (ch1_rx_desc_tail),
        .desc_len     (ch1_rx_desc_len),
        .rx_pbl       (cfg_dma_mode[11:8]),
        .rx_buf_size  (ch1_rx_buf_size),
        .ahb_req      (rx1_ahb_req),
        .ahb_grant    (~bus_to_tx && (rx_arb_grant == 2'd1)),
        .ahb_addr     (rx1_ahb_addr),
        .ahb_wdata    (rx1_ahb_wdata),
        .ahb_burst    (rx1_ahb_burst),
        .ahb_rdata    (ahb_rdata),
        .ahb_ready    (ahb_ready),
        .ahb_error    (ahb_error),
        .ari_val      (ari_val && (ari_queue == 1'b1)),
        .ari_rdy      (),
        .ari_data     (ari_data),
        .ari_sop      (ari_sop),
        .ari_eop      (ari_eop),
        .ch_done      (ch_rx_done[1]),
        .ch_error     (ch_rx_error[1]),
        .ch_overflow  ()
    );
    assign rx1_ahb_write = 1'b1;

    //--------------------------------------------------------------------------
    // Channel Arbiter
    //--------------------------------------------------------------------------
    generate
        if (!P_SHELL_MODE) begin : gen_arbiter
            dma_arbiter #(.P_NUM_TX_CH(2), .P_NUM_RX_CH(2))
            u_arbiter (
                .clk          (clk),
                .rst_n        (rst_n),
                .tx_req       ({tx1_ahb_req, tx0_ahb_req}),
                .rx_req       ({rx1_ahb_req, rx0_ahb_req}),
                .tx_priority  (cfg_dma_mode[1]),
                .tx_pri_ratio (cfg_dma_mode[14:12]),
                .tx_grant     (tx_arb_grant),
                .rx_grant     (rx_arb_grant),
                .bus_to_tx    (bus_to_tx)
            );
        end
    endgenerate

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req    = 1'b0;
            assign ahb_addr   = 32'd0;
            assign ahb_wdata  = 32'd0;
            assign ahb_burst  = 3'd0;
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

            //------------------------------------------------------------------
            // AHB signal mux: select from granted channel
            //------------------------------------------------------------------
            // TX channels (reads)
            wire tx_sel_ch0 = bus_to_tx && (tx_arb_grant == 2'd0);
            wire tx_sel_ch1 = bus_to_tx && (tx_arb_grant == 2'd1);
            // RX channels (writes)
            wire rx_sel_ch0 = ~bus_to_tx && (rx_arb_grant == 2'd0);
            wire rx_sel_ch1 = ~bus_to_tx && (rx_arb_grant == 2'd1);

            assign ahb_addr  = tx_sel_ch0 ? tx0_ahb_addr :
                               tx_sel_ch1 ? tx1_ahb_addr :
                               rx_sel_ch0 ? rx0_ahb_addr :
                               rx_sel_ch1 ? rx1_ahb_addr : 32'd0;

            assign ahb_wdata = rx_sel_ch0 ? rx0_ahb_wdata :
                               rx_sel_ch1 ? rx1_ahb_wdata : 32'd0;

            assign ahb_burst = tx_sel_ch0 ? tx0_ahb_burst :
                               tx_sel_ch1 ? tx1_ahb_burst :
                               rx_sel_ch0 ? rx0_ahb_burst :
                               rx_sel_ch1 ? rx1_ahb_burst : 4'd0;

            assign ahb_write = ~bus_to_tx;     // TX=Read (0), RX=Write (1)
            assign ahb_req   = tx0_ahb_req || tx1_ahb_req || rx0_ahb_req || rx1_ahb_req;

            //------------------------------------------------------------------
            // ATI mux: TX channel 0 or 1 → single ATI port
            //------------------------------------------------------------------
            assign ati_val   = tx_sel_ch0 ? tx0_ati_val : tx_sel_ch1 ? tx1_ati_val : 1'b0;
            assign ati_data  = tx_sel_ch0 ? tx0_ati_data : tx1_ati_data;
            assign ati_sop   = tx_sel_ch0 ? tx0_ati_sop   : tx1_ati_sop;
            assign ati_eop   = tx_sel_ch0 ? tx0_ati_eop   : tx1_ati_eop;
            assign ati_be    = tx_sel_ch0 ? tx0_ati_be    : tx1_ati_be;
            assign ati_queue = tx_sel_ch0 ? 1'b0          : 1'b1;

            //------------------------------------------------------------------
            // ARI demux: single ARI port → RX channel 0 or 1
            // Both channels see ari_val, but only the target one processes it.
            // ari_rdy is asserted when the target channel is ready.
            //------------------------------------------------------------------
            assign ari_rdy = 1'b1;  // Both channels always ready to accept

            //------------------------------------------------------------------
            // Interrupt
            //------------------------------------------------------------------
            dma_intr_ctrl u_intr (
                .clk            (clk),
                .rst_n          (rst_n),
                .intr_sources   ({ch_rx_done[1], ch_tx_done[1], ch_rx_done[0], ch_tx_done[0]}),
                .intr_enable    (cfg_dma_intr_enable[3:0]),
                .coalesce_timer (cfg_coalesce_timer),
                .intr_o         (intr_o)
            );

            assign intr_status = {ch_rx_done[1], ch_tx_done[1], ch_rx_done[0], ch_tx_done[0]};
        end
    endgenerate

endmodule
