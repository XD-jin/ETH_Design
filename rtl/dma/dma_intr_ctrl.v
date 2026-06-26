// ============================================================================
// Module: DMA_INTR_CTRL
// File:    dma_intr_ctrl.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: DMA interrupt controller — per-channel interrupt aggregation with coalescing timer.
// ============================================================================

module dma_intr_ctrl #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,
    input  wire [ 3:0] intr_sources,     // {CH1_RX, CH1_TX, CH0_RX, CH0_TX}
    input  wire [ 3:0] intr_enable,
    input  wire [15:0] coalesce_timer,    // Interrupt coalescing period (in μs equivalent)
    output wire        intr_o
);

    reg [3:0] pending;
    reg [15:0] timer_cnt;
    reg       intr_reg;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign intr_o = 1'b0;
        end else begin : gen_active
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    pending   <= 4'd0;
                    timer_cnt <= 16'd0;
                    intr_reg  <= 1'b0;
                end else begin
                    // Accumulate pending interrupts
                    pending <= pending | (intr_sources & intr_enable);

                    if (|pending && (timer_cnt == 16'd0))
                        timer_cnt <= coalesce_timer;

                    if (timer_cnt > 16'd0) begin
                        timer_cnt <= timer_cnt - 16'd1;
                        if (timer_cnt == 16'd1) begin
                            intr_reg <= 1'b1;
                            pending  <= 4'd0;
                        end
                    end else begin
                        intr_reg <= 1'b0;
                    end
                end
            end
            assign intr_o = intr_reg;
        end
    endgenerate

endmodule
