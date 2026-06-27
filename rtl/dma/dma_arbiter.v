// ============================================================================
// Module: DMA_ARBITER
// File:    dma_arbiter.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
//
// Description:
//   DMA channel arbiter.
//   - Default: RX owns bus (bus_to_tx = 0)
//   - TX gets bus only when TX requesting AND RX NOT requesting
//   - RX higher priority: if TX+RX request simultaneously, RX wins
//   - Channel switch allowed only when ahb_idle = 1 (AHB bus free)
//   - Within TX/RX: Ch0 > Ch1 (Strict Priority)
// ============================================================================

module dma_arbiter #(
    parameter P_NUM_TX_CH = 2,
    parameter P_NUM_RX_CH = 2,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,
    input  wire        ahb_idle,               // 1 = AHB bus is free (safe to switch)
    input  wire [P_NUM_TX_CH-1:0] tx_req,     // TX channel requests
    input  wire [P_NUM_RX_CH-1:0] rx_req,     // RX channel requests
    output wire [ 1:0] tx_grant,               // Selected TX channel
    output wire [ 1:0] rx_grant,               // Selected RX channel
    output wire        bus_to_tx               // 1=TX owns bus, 0=RX owns bus
);

    reg [1:0] tx_grant_reg, rx_grant_reg;
    reg       bus_to_tx_reg;

    wire tx_any_req, rx_any_req;
    assign tx_any_req = |tx_req;
    assign rx_any_req = |rx_req;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign tx_grant  = 2'd0;
            assign rx_grant  = 2'd0;
            assign bus_to_tx = 1'b0;
        end else begin : gen_active

            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    tx_grant_reg  <= 2'd0;
                    rx_grant_reg  <= 2'd0;
                    bus_to_tx_reg <= 1'b0;     // Default: RX
                end else if (ahb_idle) begin
                    // Only switch when AHB is free

                    // TX direction grant: Ch0 > Ch1 (SP)
                    if (tx_req[0])
                        tx_grant_reg <= 2'd0;
                    else if (tx_req[1])
                        tx_grant_reg <= 2'd1;

                    // RX direction grant: Ch0 > Ch1 (SP)
                    if (rx_req[0])
                        rx_grant_reg <= 2'd0;
                    else if (rx_req[1])
                        rx_grant_reg <= 2'd1;

                    // TX vs RX: RX priority
                    // Default RX. Only give bus to TX when TX asks AND RX does NOT.
                    if (tx_any_req && ~rx_any_req)
                        bus_to_tx_reg <= 1'b1;
                    else
                        bus_to_tx_reg <= 1'b0;
                end
            end

            assign tx_grant  = tx_grant_reg;
            assign rx_grant  = rx_grant_reg;
            assign bus_to_tx = bus_to_tx_reg;

        end
    endgenerate

endmodule
