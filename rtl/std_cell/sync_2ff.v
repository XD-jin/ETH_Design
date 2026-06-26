// ============================================================================
// Module: SYNC_2FF
// File:    sync_2ff.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   Dual flip-flop synchronizer for single-bit control signals crossing
//   between asynchronous clock domains. Provides metastability protection
//   with a 2-stage synchronizer chain placed in the destination clock domain.
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n). Both flip-flops reset to 1'b0.
//
// Clock Strategy:
//   Single clock (clk_dst) — the destination domain clock. The synchronizer
//   must be instantiated in the destination clock domain of the CDC path.
//
// CDC Notes:
//   - Suitable for single-bit static or slowly-changing control signals
//   - MTBF improves with higher destination clock frequency
//   - For multi-bit buses, use async FIFO with Gray-code pointers instead
//   - For pulsed signals, consider edge-detect synchronizer or handshake
//
// Parameters:
//   P_SHELL_MODE    1 = Tie outputs to safe values for fast system sim
//   P_RESET_VALUE   1 = Sync chain resets to 1 (for active-high idle signals)
// ============================================================================

module sync_2ff #(
    parameter P_SHELL_MODE  = 0,
    parameter P_RESET_VALUE = 0
) (
    input  wire clk_dst,        // Destination domain clock
    input  wire rst_n,          // Asynchronous reset, active low
    input  wire data_in,        // Input signal (from source clock domain)
    output wire data_out        // Synchronized output (in destination domain)
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg sync_ff1;               // First synchronizer flip-flop
    reg sync_ff2;               // Second synchronizer flip-flop (output stage)

    //--------------------------------------------------------------------------
    // Shell Mode: bypass synchronization, tie output to safe value
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign data_out = P_RESET_VALUE;

        //--------------------------------------------------------------------------
        // Active Mode: 2-stage synchronizer chain
        //--------------------------------------------------------------------------
        end else begin : gen_active

            //----------------------------------------------------------------------
            // Stage 1: Sample input signal into destination domain
            // This FF may go metastable — acceptable, Stage 2 resolves it.
            //----------------------------------------------------------------------
            always @(posedge clk_dst or negedge rst_n) begin
                if (rst_n == 1'b0)
                    sync_ff1 <= P_RESET_VALUE;
                else
                    sync_ff1 <= data_in;
            end

            //----------------------------------------------------------------------
            // Stage 2: Resolve metastability from Stage 1
            // Output is clean and safe to use in destination domain.
            //----------------------------------------------------------------------
            always @(posedge clk_dst or negedge rst_n) begin
                if (rst_n == 1'b0)
                    sync_ff2 <= P_RESET_VALUE;
                else
                    sync_ff2 <= sync_ff1;
            end

            assign data_out = sync_ff2;

        end
    endgenerate

endmodule
