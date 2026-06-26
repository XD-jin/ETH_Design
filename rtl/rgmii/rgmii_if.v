// ============================================================================
// Module: RGMII_IF
// File:    rgmii_if.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   RGMII v2.6 Interface Adapter. Converts internal 8-bit SDR MAC data path
//   to external 4-bit DDR RGMII signals, and vice versa.
//
//   TX: 8-bit SDR @ 125MHz → 4-bit DDR @ 125MHz
//       Rising edge:  txd[3:0], tx_ctl (TX_EN)
//       Falling edge: txd[7:4], tx_ctl (TX_EN XOR TX_ER)
//
//   RX: 4-bit DDR @ 125MHz → 8-bit SDR @ 125MHz
//       Rising edge:  rxd[3:0], rx_ctl (RX_DV)
//       Falling edge: rxd[7:4], rx_ctl (RX_DV XOR RX_ER)
//
//   Clock Notes:
//     - TXC is generated internally from gtx_clk with optional delay (~2ns)
//     - RXC is received from PHY; both edges used for DDR sampling
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n).
// ============================================================================

module rgmii_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        gtx_clk,              // 125MHz TX clock (from MAC/PLL)
    input  wire        rx_clk,               // 125MHz RX clock (from PHY)
    input  wire        rst_n,                // Asynchronous reset, active low

    // Internal MAC TX interface (8-bit SDR)
    input  wire [ 7:0] mac_txd,              // TX data from MAC
    input  wire        mac_tx_en,            // TX enable from MAC
    input  wire        mac_tx_er,            // TX error from MAC

    // Internal MAC RX interface (8-bit SDR, to MAC)
    output wire [ 7:0] mac_rxd,              // RX data to MAC
    output wire        mac_rx_dv,            // RX data valid to MAC
    output wire        mac_rx_er,            // RX error to MAC

    // RGMII external pads
    output wire        rgmii_txc,            // TX clock (125MHz, MAC→PHY)
    output wire [ 3:0] rgmii_txd,            // TX data (4-bit DDR)
    output wire        rgmii_tx_ctl,         // TX control (DDR)
    input  wire        rgmii_rxc,            // RX clock (125MHz, PHY→MAC)
    input  wire [ 3:0] rgmii_rxd,            // RX data (4-bit DDR)
    input  wire        rgmii_rx_ctl          // RX control (DDR)
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg [3:0] txd_lo;                       // TX data low nibble (rising edge)
    reg [3:0] txd_hi;                       // TX data high nibble (falling edge)
    reg       tx_ctl_lo;                     // TX_CTL rising edge = TX_EN
    reg       tx_ctl_hi;                     // TX_CTL falling edge = TX_EN ^ TX_ER

    // RX sampling (IDDR-like behavior)
    reg [3:0] rxd_lo;                       // RX data captured on RXC rising edge
    reg [3:0] rxd_hi;                       // RX data captured on RXC falling edge
    reg       rx_ctl_lo;                     // RX_CTL rising edge = RX_DV
    reg       rx_ctl_hi;                     // RX_CTL falling edge = RX_DV ^ RX_ER

    // Output registers (SDR)
    reg [7:0] mac_rxd_reg;
    reg       mac_rx_dv_reg;
    reg       mac_rx_er_reg;

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign rgmii_txc   = 1'b0;
            assign rgmii_txd   = 4'd0;
            assign rgmii_tx_ctl = 1'b0;
            assign mac_rxd     = 8'd0;
            assign mac_rx_dv   = 1'b0;
            assign mac_rx_er   = 1'b0;

        end else begin : gen_active

            //------------------------------------------------------------------
            // TX Path: 8-bit SDR → 4-bit DDR
            //------------------------------------------------------------------
            always @(posedge gtx_clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    txd_lo    <= 4'd0;
                    txd_hi    <= 4'd0;
                    tx_ctl_lo <= 1'b0;
                    tx_ctl_hi <= 1'b0;
                end else begin
                    // Lower nibble on rising edge
                    txd_lo    <= mac_txd[3:0];
                    tx_ctl_lo <= mac_tx_en;
                    // Upper nibble on falling edge
                    txd_hi    <= mac_txd[7:4];
                    tx_ctl_hi <= mac_tx_en ^ mac_tx_er;
                end
            end

            // RGMII TX Clock: gtx_clk itself (with optional programmable delay in FPGA)
            assign rgmii_txc = gtx_clk;

            // DDR outputs: use DDR registers in FPGA (ODDR primitive)
            // For ASIC: instantiate a DDR output cell
            // For FPGA simulation: assign directly — synthesis will map to ODDR
            assign rgmii_txd    = gtx_clk ? txd_lo    : txd_hi;
            assign rgmii_tx_ctl = gtx_clk ? tx_ctl_lo : tx_ctl_hi;

            //------------------------------------------------------------------
            // RX Path: 4-bit DDR → 8-bit SDR
            //------------------------------------------------------------------
            // Sample on both edges of RXC (IDDR behavior)
            always @(posedge rgmii_rxc or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    rxd_lo    <= 4'd0;
                    rx_ctl_lo <= 1'b0;
                end else begin
                    rxd_lo    <= rgmii_rxd;
                    rx_ctl_lo <= rgmii_rx_ctl;
                end
            end

            always @(negedge rgmii_rxc or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    rxd_hi    <= 4'd0;
                    rx_ctl_hi <= 1'b0;
                end else begin
                    rxd_hi    <= rgmii_rxd;
                    rx_ctl_hi <= rgmii_rx_ctl;
                end
            end

            // Assemble SDR outputs (registered on RXC rising edge)
            always @(posedge rgmii_rxc or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    mac_rxd_reg  <= 8'd0;
                    mac_rx_dv_reg <= 1'b0;
                    mac_rx_er_reg <= 1'b0;
                end else begin
                    // Combine: rising edge[3:0] + falling edge[7:4]
                    mac_rxd_reg   <= {rxd_hi, rxd_lo};
                    // Decode: rising = RX_DV, falling = RX_DV ^ RX_ER
                    mac_rx_dv_reg <= rx_ctl_lo;
                    mac_rx_er_reg <= rx_ctl_lo ^ rx_ctl_hi;
                end
            end

            assign mac_rxd   = mac_rxd_reg;
            assign mac_rx_dv = mac_rx_dv_reg;
            assign mac_rx_er = mac_rx_er_reg;

        end
    endgenerate

endmodule
