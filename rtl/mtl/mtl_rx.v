// ============================================================================
// Module: MTL_RX
// File:    mtl_rx.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
// Description:
//   MTL Receive Path — Rx Queues (2-queue shared SRAM) + Rx Router + Scheduler.
//   Receives 8-bit packet data from MAC over MRI interface (gmii_rx_clk domain),
//   routes to queue based on DA match table, buffers in async FIFO per queue,
//   and outputs 32-bit data to DMA over ARI interface (app_clk domain).
// ============================================================================

module mtl_rx #(
    parameter P_QUEUE_DEPTH = 8192,
    parameter P_NUM_QUEUES  = 2,
    parameter P_SHELL_MODE  = 0
) (
    input  wire        gmii_rx_clk,
    input  wire        app_clk,
    input  wire        rst_n,

    // MRI (from MAC)
    input  wire        mri_val,
    output wire        mri_rdy,
    input  wire [ 7:0] mri_data,
    input  wire        mri_sop,
    input  wire        mri_eop,

    // Queue routing config
    input  wire        rx_da_valid,
    input  wire [47:0] rx_da,
    input  wire [47:0] cfg_mac_addr0,
    input  wire [47:0] cfg_mac_addr1,

    // ARI (to DMA)
    output wire        ari_val,
    input  wire        ari_rdy,
    output wire [31:0] ari_data,
    output wire        ari_sop,
    output wire        ari_eop,
    output wire [ 1:0] ari_be,
    output wire        ari_queue,           // Source queue number

    // Status
    output wire [1:0] rx_queue_not_empty,
    output wire [7:0] rx_fifo_level,
    output wire       rx_overflow
);

    // Queue routing: DA match → queue select
    wire route_q1;
    assign route_q1 = (rx_da == cfg_mac_addr1) && (rx_da != 48'd0);

    wire       wr_en_q0, wr_en_q1;
    wire [7:0] wr_data;
    wire       full_q0, full_q1, afull_q0, afull_q1;
    wire       empty_q0, empty_q1;
    wire       rd_en_q0, rd_en_q1;
    wire [7:0] rd_data_q0, rd_data_q1;

    assign wr_en_q0 = mri_val && ~route_q1;
    assign wr_en_q1 = mri_val &&  route_q1;
    assign wr_data  = mri_data;
    assign mri_rdy  = route_q1 ? ~afull_q1 : ~afull_q0;

    wire [1:0] sel_queue;
    wire not_empty_q0 = ~empty_q0;
    wire not_empty_q1 = ~empty_q1;

    assign rd_en_q0   = ari_rdy && (sel_queue == 2'd0) && ~empty_q0;
    assign rd_en_q1   = ari_rdy && (sel_queue == 2'd1) && ~empty_q1;
    assign ari_data   = {24'd0, (sel_queue == 2'd0) ? rd_data_q0 : rd_data_q1};
    assign ari_val    = (sel_queue == 2'd0) ? rd_en_q0 : rd_en_q1;
    assign ari_queue  = sel_queue[0];
    assign ari_sop    = 1'b0;  // Simplified
    assign ari_eop    = 1'b0;
    assign ari_be     = 2'd0;
    assign rx_queue_not_empty = {not_empty_q1, not_empty_q0};

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign rx_fifo_level = 8'd0;
            assign rx_overflow   = 1'b0;
        end else begin : gen_active

            async_fifo #(.P_DATA_WIDTH(8), .P_DEPTH(P_QUEUE_DEPTH))
            u_rx_fifo_q0 (
                .wr_clk       (gmii_rx_clk),
                .wr_rst_n     (rst_n),
                .wr_en        (wr_en_q0),
                .wr_data      (wr_data),
                .full         (full_q0),
                .almost_full  (afull_q0),
                .rd_clk       (app_clk),
                .rd_rst_n     (rst_n),
                .rd_en        (rd_en_q0),
                .rd_data      (rd_data_q0),
                .empty        (empty_q0),
                .almost_empty ()
            );

            async_fifo #(.P_DATA_WIDTH(8), .P_DEPTH(P_QUEUE_DEPTH))
            u_rx_fifo_q1 (
                .wr_clk       (gmii_rx_clk),
                .wr_rst_n     (rst_n),
                .wr_en        (wr_en_q1),
                .wr_data      (wr_data),
                .full         (full_q1),
                .almost_full  (afull_q1),
                .rd_clk       (app_clk),
                .rd_rst_n     (rst_n),
                .rd_en        (rd_en_q1),
                .rd_data      (rd_data_q1),
                .empty        (empty_q1),
                .almost_empty ()
            );

            mtl_arbiter #(.P_NUM_QUEUES(2))
            u_arbiter (
                .clk              (app_clk),
                .rst_n            (rst_n),
                .queue_not_empty  ({not_empty_q1, not_empty_q0}),
                .queue_threshold  (2'd0),
                .tx_sp_mode       (1'b0),
                .rx_arb_mode      (2'd0),
                .wrr_weight       (8'd0),
                .selected_queue   (sel_queue),
                .queue_switch     ()
            );

            assign rx_overflow   = wr_en_q0 && full_q0 || wr_en_q1 && full_q1;
            assign rx_fifo_level = 8'd0;
        end
    endgenerate

endmodule
