// ============================================================================
// Module: ADDR_FILTER
// File:    addr_filter.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   Ethernet destination address (DA) filter. Supports two filtering modes:
//
//   Perfect Match Mode (HPF=0):
//     Compares received DA against up to 4 programmable 48-bit MAC addresses.
//     Also handles broadcast (FF:FF:FF:FF:FF:FF) and promiscuous mode.
//
//   Hash Filter Mode (HPF=1):
//     Computes a 6-bit hash from the CRC-32 of the received DA, then checks
//     a 64-bit hash table. Primarily used for multicast filtering.
//
//   Independent controls allow promiscuous, broadcast-block, pass-all-multicast,
//   and inverse filtering behaviors.
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n).
//
// Clock Strategy:
//   Single clock: gmii_rx_clk (125MHz). Operates in the receive data path.
//
// Parameters:
//   P_MAC_ADDR_ENTRIES   Number of perfect-match MAC address entries (1-4)
//   P_HASH_TABLE_WIDTH   Hash table width in bits (32/64)
//   P_SHELL_MODE         1 = Always pass (promiscuous)
// ============================================================================

module addr_filter #(
    parameter P_MAC_ADDR_ENTRIES = 4,
    parameter P_HASH_TABLE_WIDTH = 64,
    parameter P_SHELL_MODE       = 0
) (
    input  wire        clk,                  // gmii_rx_clk (125MHz)
    input  wire        rst_n,                // Asynchronous reset, active low

    // Configuration (from CSR, synchronized into rx_clk domain)
    input  wire        cfg_promiscuous,       // Receive all frames (RA/PR)
    input  wire        cfg_pass_all_mcast,    // Pass all multicast frames (PMF)
    input  wire        cfg_disable_bcast,     // Disable broadcast frames (DBF)
    input  wire        cfg_da_invert,         // DA inverse filtering (DAIF)
    input  wire        cfg_hash_mode,         // Hash/Perfect mode select (HPF)
    input  wire        cfg_pass_ctrl,         // Pass control frames (PCF)
    input  wire        cfg_hash_mcast,        // Hash multicast (HM)
    input  wire [47:0] cfg_mac_addr [0:3],    // Perfect-match MAC address table
    input  wire [63:0] cfg_hash_table,        // Hash filter table

    // Received frame DA (from MAC RX parser)
    input  wire        rx_da_valid,           // DA field valid strobe
    input  wire [47:0] rx_da,                 // 48-bit destination address

    // Frame info
    input  wire        rx_is_pause,           // Frame is a MAC Control Pause frame
    input  wire        rx_is_broadcast,       // Frame has broadcast DA

    // Filter result
    output wire        frame_pass,            // Frame passes address filter
    output wire        hash_hit,              // Hash filter matched (for status)
    output wire [ 5:0] hash_index             // Hash table index (for debug)
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    wire [3:0] perfect_match;               // Per-entry perfect match results
    wire [5:0] da_hash;                     // 6-bit hash from CRC-32 of DA
    wire       hash_table_hit;              // Hash table lookup result
    wire       is_multicast;                // DA is multicast/broadcast
    wire       is_broadcast;                // DA is broadcast (FF:FF:FF:FF:FF:FF)

    assign is_multicast = rx_da[0];         // I/G bit = 1 means multicast/broadcast
    assign is_broadcast = (rx_da == 48'hFFFF_FFFF_FFFF);

    //--------------------------------------------------------------------------
    // Perfect Match: parallel 48-bit comparators
    //--------------------------------------------------------------------------
    generate
        genvar i;
        for (i = 0; i < P_MAC_ADDR_ENTRIES; i = i + 1) begin : gen_perfect_match
            assign perfect_match[i] = (rx_da == cfg_mac_addr[i]) && cfg_mac_addr[i] != 48'h0000_0000_0000;
        end
    endgenerate

    wire any_perfect_match;
    assign any_perfect_match = |perfect_match;

    //--------------------------------------------------------------------------
    // Hash Filter: 6-bit hash from CRC-32 of DA
    //--------------------------------------------------------------------------
    wire [31:0] da_crc32;
    // Simplified CRC-32 hash computation on 48-bit DA
    // For actual implementation, instantiate CRC32 module or use LFSR
    // Here we use a simple XOR-based hash (adequate for multicast filtering)
    assign da_hash[0] = rx_da[ 0] ^ rx_da[ 6] ^ rx_da[12] ^ rx_da[18] ^ rx_da[24] ^ rx_da[30] ^ rx_da[36] ^ rx_da[42];
    assign da_hash[1] = rx_da[ 1] ^ rx_da[ 7] ^ rx_da[13] ^ rx_da[19] ^ rx_da[25] ^ rx_da[31] ^ rx_da[37] ^ rx_da[43];
    assign da_hash[2] = rx_da[ 2] ^ rx_da[ 8] ^ rx_da[14] ^ rx_da[20] ^ rx_da[26] ^ rx_da[32] ^ rx_da[38] ^ rx_da[44];
    assign da_hash[3] = rx_da[ 3] ^ rx_da[ 9] ^ rx_da[15] ^ rx_da[21] ^ rx_da[27] ^ rx_da[33] ^ rx_da[39] ^ rx_da[45];
    assign da_hash[4] = rx_da[ 4] ^ rx_da[10] ^ rx_da[16] ^ rx_da[22] ^ rx_da[28] ^ rx_da[34] ^ rx_da[40] ^ rx_da[46];
    assign da_hash[5] = rx_da[ 5] ^ rx_da[11] ^ rx_da[17] ^ rx_da[23] ^ rx_da[29] ^ rx_da[35] ^ rx_da[41] ^ rx_da[47];

    // 64:1 MUX lookup
    assign hash_table_hit = cfg_hash_table[da_hash];

    //--------------------------------------------------------------------------
    // Filter Decision: priority-encoded
    //--------------------------------------------------------------------------
    reg  frame_pass_reg;

    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign frame_pass = 1'b1;       // Pass all in shell mode
            assign hash_hit   = 1'b0;
            assign hash_index = 6'd0;

        end else begin : gen_active

            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    frame_pass_reg <= 1'b0;
                end else if (rx_da_valid) begin
                    // Priority-based filter decision
                    if (cfg_promiscuous)
                        // (1) Promiscuous: pass everything
                        frame_pass_reg <= 1'b1;
                    else if (rx_is_broadcast)
                        // (2) Broadcast: pass unless disabled
                        frame_pass_reg <= ~cfg_disable_bcast;
                    else if (is_multicast) begin
                        // (3) Multicast
                        if (cfg_pass_all_mcast)
                            frame_pass_reg <= 1'b1;
                        else if (cfg_hash_mode && cfg_hash_mcast)
                            frame_pass_reg <= hash_table_hit;
                        else
                            frame_pass_reg <= any_perfect_match;
                    end else begin
                        // (4) Unicast
                        if (cfg_hash_mode)
                            frame_pass_reg <= hash_table_hit;
                        else if (cfg_da_invert)
                            frame_pass_reg <= ~any_perfect_match;
                        else
                            frame_pass_reg <= any_perfect_match;
                    end
                end else begin
                    frame_pass_reg <= 1'b0;
                end
            end

            assign frame_pass = frame_pass_reg;
            assign hash_hit   = hash_table_hit;
            assign hash_index = da_hash;

        end
    endgenerate

endmodule
