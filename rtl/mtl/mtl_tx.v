// ============================================================================
// Module: MTL_TX
// File:    mtl_tx.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   MTL Transmit Path — Tx Queues (2-queue shared SRAM) + Tx Scheduler.
//   Receives 32-bit packet data from DMA over ATI interface (app_clk domain),
//   buffers in async FIFO per queue, and outputs 8-bit data to MAC over
//   MTI interface (gmii_tx_clk domain).
// ============================================================================

module mtl_tx #(
    parameter P_QUEUE_DEPTH  = 4096,
    parameter P_NUM_QUEUES   = 2,
    parameter P_DATA_WIDTH   = 32,
    parameter P_SHELL_MODE   = 0
) (
    input  wire        app_clk,
    input  wire        gmii_tx_clk,
    input  wire        rst_n,

    // ATI (from DMA)
    input  wire        ati_val,
    output wire        ati_rdy,
    input  wire [31:0] ati_data,
    input  wire        ati_sop,
    input  wire        ati_eop,
    input  wire [ 1:0] ati_be,
    input  wire        ati_queue,

    // MTI (to MAC)
    output wire        mti_val,
    input  wire        mti_rdy,
    output wire [ 7:0] mti_data,
    output wire        mti_sop,
    output wire        mti_eop,

    // Status
    output wire [1:0] tx_queue_not_empty,
    output wire [7:0] tx_fifo_level,
    output wire       tx_underflow
);

    // Write-side signals per queue
    wire       wr_en_q0, wr_en_q1;
    wire [31:0] wr_data_q0, wr_data_q1;
    wire       wr_sop_q0, wr_sop_q1;
    wire       wr_eop_q0, wr_eop_q1;
    wire       full_q0, full_q1;
    wire       afull_q0, afull_q1;

    // Read-side signals per queue
    wire       rd_en_q0, rd_en_q1;
    wire [31:0] rd_data_q0, rd_data_q1;
    wire       empty_q0, empty_q1;
    wire       rd_sop_q0, rd_sop_q1;
    wire       rd_eop_q0, rd_eop_q1;

    // Demux ATI to target queue
    assign wr_en_q0  = ati_val && (ati_queue == 1'b0);
    assign wr_en_q1  = ati_val && (ati_queue == 1'b1);
    assign wr_data_q0 = ati_data;
    assign wr_data_q1 = ati_data;
    assign wr_sop_q0  = ati_sop && (ati_queue == 1'b0);
    assign wr_sop_q1  = ati_sop && (ati_queue == 1'b1);
    assign wr_eop_q0  = ati_eop && (ati_queue == 1'b0);
    assign wr_eop_q1  = ati_eop && (ati_queue == 1'b1);
    assign ati_rdy    = (ati_queue == 1'b0) ? ~afull_q0 : ~afull_q1;

    // Scheduler selects which queue to read
    wire [1:0] sel_queue;
    wire       not_empty_q0 = ~empty_q0;
    wire       not_empty_q1 = ~empty_q1;

    assign rd_en_q0 = mti_rdy && (sel_queue == 2'd0) && ~empty_q0;
    assign rd_en_q1 = mti_rdy && (sel_queue == 2'd1) && ~empty_q1;

    // Mux read data from selected queue
    assign mti_data = (sel_queue == 2'd0) ? rd_data_q0 : rd_data_q1;
    assign mti_val  = (sel_queue == 2'd0) ? (rd_en_q0 && ~empty_q0) : (rd_en_q1 && ~empty_q1);
    assign mti_sop  = (sel_queue == 2'd0) ? rd_sop_q0 : rd_sop_q1;
    assign mti_eop  = (sel_queue == 2'd0) ? rd_eop_q0 : rd_eop_q1;

    assign tx_queue_not_empty = {not_empty_q1, not_empty_q0};

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign tx_fifo_level = 8'd0;
            assign tx_underflow  = 1'b0;
        end else begin : gen_active
            // Queue 0 async FIFO (32-bit write, 8-bit read)
            async_fifo #(.P_DATA_WIDTH(32), .P_DEPTH(P_QUEUE_DEPTH/4))
            u_tx_fifo_q0 (
                .wr_clk       (app_clk),
                .wr_rst_n     (rst_n),
                .wr_en        (wr_en_q0),
                .wr_data      (wr_data_q0),
                .full         (full_q0),
                .almost_full  (afull_q0),
                .rd_clk       (gmii_tx_clk),
                .rd_rst_n     (rst_n),
                .rd_en        (rd_en_q0),
                .rd_data      (rd_data_q0),
                .empty        (empty_q0),
                .almost_empty ()
            );

            // Queue 1 async FIFO
            async_fifo #(.P_DATA_WIDTH(32), .P_DEPTH(P_QUEUE_DEPTH/4))
            u_tx_fifo_q1 (
                .wr_clk       (app_clk),
                .wr_rst_n     (rst_n),
                .wr_en        (wr_en_q1),
                .wr_data      (wr_data_q1),
                .full         (full_q1),
                .almost_full  (afull_q1),
                .rd_clk       (gmii_tx_clk),
                .rd_rst_n     (rst_n),
                .rd_en        (rd_en_q1),
                .rd_data      (rd_data_q1),
                .empty        (empty_q1),
                .almost_empty ()
            );

            mtl_arbiter #(.P_NUM_QUEUES(2))
            u_arbiter (
                .clk              (gmii_tx_clk),
                .rst_n            (rst_n),
                .queue_not_empty  ({not_empty_q1, not_empty_q0}),
                .queue_threshold  (2'd0),
                .tx_sp_mode       (1'b1),
                .rx_arb_mode      (2'd0),
                .wrr_weight       (8'd0),
                .selected_queue   (sel_queue),
                .queue_switch     ()
            );

            assign tx_underflow = mti_rdy && mti_val && (sel_queue == 2'd0) && empty_q0 ||
                                  mti_rdy && mti_val && (sel_queue == 2'd1) && empty_q1;
            assign tx_fifo_level = 8'd0;  // Simplified
        end
    endgenerate

endmodule
