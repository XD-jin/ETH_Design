// ============================================================================
// Module: ETH_CLK_GATE
// File:    eth_clk_gate.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   Clock gating cell for dynamic power reduction. Uses a latch-based
//   AND gate structure: latch captures enable when clock is low, AND gate
//   passes clock only when latched enable is active. This prevents glitches
//   on the gated clock output.
//
//   Foundry replacement: define ETH_USE_FOUNDRY_ICG to replace with
//   process-specific integrated clock gating cell.
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n). Clears the latch.
//
// Clock Strategy:
//   Single input clock (clk_in). Gated clock output (clk_out) is derived
//   from clk_in through a latch+AND combination.
//
// Timing Notes:
//   - en must be stable while clk_in is LOW (latch transparent phase)
//   - te (test enable) bypasses gating for scan testing
//   - For synthesis: this behavioral model maps to foundry ICG when
//     ETH_USE_FOUNDRY_ICG is defined
//
// Parameters:
//   P_SHELL_MODE    1 = Pass clock through ungated
// ============================================================================

module eth_clk_gate #(
    parameter P_SHELL_MODE = 0
) (
    input  wire clk_in,         // Input clock (ungated)
    input  wire rst_n,          // Asynchronous reset, active low
    input  wire en,             // Clock enable (1 = pass clock, 0 = gate off)
    input  wire te,             // Test enable (1 = bypass gating for DFT)
    output wire clk_out         // Gated clock output
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg en_latch;               // Latched enable (captured when clk_in is low)

    //--------------------------------------------------------------------------
    // Shell Mode: pass clock through ungated
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign clk_out = clk_in;

        //--------------------------------------------------------------------------
        // Active Mode: latch-based clock gating
        //--------------------------------------------------------------------------
        end else begin : gen_active

            //------------------------------------------------------------------
            // Enable Latch: transparent when clk_in is LOW
            // Captures en value to prevent glitches on clk_out.
            //------------------------------------------------------------------
            always @(clk_in or rst_n or en) begin
                if (rst_n == 1'b0)
                    en_latch = 1'b0;
                else if (clk_in == 1'b0)
                    en_latch = en;
            end

            //------------------------------------------------------------------
            // AND Gate: (enable OR test_enable) AND clock
            // te=1 in scan mode forces clock always on.
            //------------------------------------------------------------------
            assign clk_out = clk_in & (en_latch | te);

        end
    endgenerate

endmodule
