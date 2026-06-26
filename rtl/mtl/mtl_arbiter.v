// ============================================================================
// Module: MTL_ARBITER
// File:    mtl_arbiter.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   MTL Queue Scheduler. Selects which Tx Queue to service next and which
//   Rx Queue to forward to DMA. Supports Strict Priority (SP) and Weighted
//   Round Robin (WRR) algorithms.
//
//   TX: SP mode — Queue 0 > Queue 1. Anti-starvation: force switch every 8 frames.
//   RX: RR mode — Round Robin between Queue 0 and Queue 1.
// ============================================================================

module mtl_arbiter #(
    parameter P_NUM_QUEUES = 2,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk,                  // gmii_clk (TX side) or hclk (RX side)
    input  wire        rst_n,

    // Queue status
    input  wire [P_NUM_QUEUES-1:0] queue_not_empty,    // Each queue has data
    input  wire [P_NUM_QUEUES-1:0] queue_threshold,    // Each queue above threshold

    // Scheduling config
    input  wire        tx_sp_mode,           // 1=Strict Priority, 0=WRR
    input  wire [ 1:0] rx_arb_mode,          // 00=RR, 01=SP Q0, 10=SP Q1
    input  wire [P_NUM_QUEUES*4-1:0] wrr_weight, // Per-queue WRR weights

    // Selected queue
    output wire [1:0] selected_queue,
    output wire       queue_switch           // Pulse: queue selection changed
);

    reg [1:0] sel_queue_reg;
    reg [2:0] frame_cnt;            // TX: count frames per burst for anti-starvation
    reg       last_sel;             // RX: 0=last was Q0, 1=last was Q1
    reg       switch_reg;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign selected_queue = 2'd0;
            assign queue_switch   = 1'b0;
        end else begin : gen_active

            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    sel_queue_reg <= 2'd0;
                    frame_cnt     <= 3'd0;
                    last_sel      <= 1'b0;
                    switch_reg    <= 1'b0;
                end else begin
                    switch_reg <= 1'b0;

                    if (tx_sp_mode) begin
                        // TX Strict Priority: Q0 has absolute priority
                        if (queue_not_empty[0]) begin
                            if (sel_queue_reg != 2'd0)
                                switch_reg <= 1'b1;
                            sel_queue_reg <= 2'd0;
                            frame_cnt <= frame_cnt + 3'd1;
                            // Anti-starvation: force Q1 every 8 frames
                            if (frame_cnt == 3'd7 && queue_not_empty[1]) begin
                                sel_queue_reg <= 2'd1;
                                frame_cnt <= 3'd0;
                                switch_reg <= 1'b1;
                            end
                        end else if (queue_not_empty[1]) begin
                            if (sel_queue_reg != 2'd1)
                                switch_reg <= 1'b1;
                            sel_queue_reg <= 2'd1;
                            frame_cnt <= 3'd0;
                        end else begin
                            sel_queue_reg <= sel_queue_reg;  // hold
                            frame_cnt <= 3'd0;
                        end
                    end else begin
                        // RX Round Robin
                        if (rx_arb_mode == 2'd0) begin
                            if (last_sel == 1'b0 && queue_not_empty[1]) begin
                                sel_queue_reg <= 2'd1;
                                last_sel <= 1'b1;
                                switch_reg <= 1'b1;
                            end else if (last_sel == 1'b1 && queue_not_empty[0]) begin
                                sel_queue_reg <= 2'd0;
                                last_sel <= 1'b0;
                                switch_reg <= 1'b1;
                            end else if (queue_not_empty[0]) begin
                                sel_queue_reg <= 2'd0;
                            end else if (queue_not_empty[1]) begin
                                sel_queue_reg <= 2'd1;
                            end
                        end
                    end
                end
            end

            assign selected_queue = sel_queue_reg;
            assign queue_switch   = switch_reg;
        end
    endgenerate

endmodule
