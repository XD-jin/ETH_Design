// ============================================================================
// Module: DMA_ARBITER
// File:    dma_arbiter.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: DMA channel arbiter — selects which Tx/Rx channel gets AHB bus access.
// ============================================================================

module dma_arbiter #(
    parameter P_NUM_TX_CH = 2,
    parameter P_NUM_RX_CH = 2,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,
    input  wire [P_NUM_TX_CH-1:0] tx_req,     // TX channel requests
    input  wire [P_NUM_RX_CH-1:0] rx_req,     // RX channel requests
    input  wire        tx_priority,            // 1=TX priority over RX
    input  wire [ 2:0] tx_pri_ratio,           // TX:RX ratio (for RR mode)
    output wire [ 1:0] tx_grant,               // Selected TX channel
    output wire [ 1:0] rx_grant,               // Selected RX channel
    output wire        bus_to_tx               // 1=Bus assigned to TX, 0=RX
);

    reg [1:0] tx_grant_reg, rx_grant_reg;
    reg       bus_to_tx_reg;
    reg [2:0] tx_cnt, rx_cnt;                  // Ratio counters

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign tx_grant = 2'd0;
            assign rx_grant = 2'd0;
            assign bus_to_tx = 1'b0;
        end else begin : gen_active
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    tx_grant_reg <= 2'd0;
                    rx_grant_reg <= 2'd0;
                    bus_to_tx_reg <= 1'b0;
                    tx_cnt <= 3'd0;
                    rx_cnt <= 3'd0;
                end else begin
                    // TX channel arbitration: Ch0 > Ch1 (SP)
                    if (tx_req[0])      tx_grant_reg <= 2'd0;
                    else if (tx_req[1]) tx_grant_reg <= 2'd1;
                    else                tx_grant_reg <= tx_grant_reg;

                    // RX channel arbitration: RR
                    if (rx_req[0] && (rx_grant_reg != 2'd0 || ~rx_req[1]))
                        rx_grant_reg <= 2'd0;
                    else if (rx_req[1])
                        rx_grant_reg <= 2'd1;

                    // TX vs RX bus arbitration
                    if (tx_priority) begin
                        bus_to_tx_reg <= |tx_req;
                    end else begin
                        if (bus_to_tx_reg && tx_req != 0 && tx_cnt < tx_pri_ratio) begin
                            tx_cnt <= tx_cnt + 3'd1;
                            bus_to_tx_reg <= 1'b1;
                        end else if (rx_req != 0) begin
                            bus_to_tx_reg <= 1'b0;
                            tx_cnt <= 3'd0;
                            rx_cnt <= rx_cnt + 3'd1;
                        end else begin
                            bus_to_tx_reg <= |tx_req;
                        end
                    end
                end
            end
            assign tx_grant = tx_grant_reg;
            assign rx_grant = rx_grant_reg;
            assign bus_to_tx = bus_to_tx_reg;
        end
    endgenerate

endmodule
