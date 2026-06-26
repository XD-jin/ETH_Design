// ============================================================================
// Module: CRC32
// File:    crc32.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   IEEE 802.3 CRC-32 generator and checker. Computes 32-bit Frame Check
//   Sequence over Ethernet frame bytes (DA through DATA/PAD).
//
//   Polynomial: 0x04C11DB7
//   x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10
//   + x^8 + x^7 + x^5 + x^4 + x^2 + x + 1
//
//   Initial value: 0xFFFFFFFF
//   Output: bitwise-inverted, transmitted LSB first
//
//   Operates on 8-bit parallel input (byte-serial). Feed one byte per clock
//   during crc_en assertion. After crc_eop, crc_result is valid for 1 cycle.
//
// Reset Strategy:
//   Asynchronous reset, active low. CRC register resets to 0xFFFFFFFF.
//
// Clock Strategy:
//   TX: gmii_tx_clk (125MHz), RX: gmii_rx_clk (125MHz)
//   Requires minimum 8 clocks per frame — pipeline if needed.
//
// Parameters:
//   P_SHELL_MODE    1 = Bypass, output zero
// ============================================================================

module crc32 #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk,          // Clock
    input  wire        rst_n,        // Asynchronous reset, active low

    input  wire        crc_en,       // CRC computation enable (data valid)
    input  wire [ 7:0] crc_data,     // Input byte
    input  wire        crc_eop,      // End-of-packet: latch final CRC, reset for next

    output wire [31:0] crc_result,   // Final CRC-32 (~crc_reg, registered)
    output wire        crc_valid     // CRC result valid (1 cycle after crc_eop)
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg  [31:0] crc_reg;            // CRC shift register
    wire [31:0] crc_next;           // Next CRC (combinational LFSR feedback)
    reg         crc_valid_reg;      // Valid flag

    //--------------------------------------------------------------------------
    // Byte-serial CRC-32 LFSR: next = f(current_crc, input_byte)
    // Equations derived from polynomial 0x04C11DB7 with MSB-first processing.
    //--------------------------------------------------------------------------
    wire [7:0] din;
    assign din = crc_data;

    wire [31:0] fb;  // feedback wire array
    assign crc_next = fb;

    assign fb[ 0] = din[6] ^ din[0] ^ crc_reg[24] ^ crc_reg[30];
    assign fb[ 1] = din[7] ^ din[6] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[ 2] = din[7] ^ din[6] ^ din[2] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[ 3] = din[7] ^ din[3] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[31];
    assign fb[ 4] = din[6] ^ din[4] ^ din[3] ^ din[2] ^ din[0] ^ crc_reg[24] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30];
    assign fb[ 5] = din[7] ^ din[6] ^ din[5] ^ din[4] ^ din[3] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[ 6] = din[7] ^ din[6] ^ din[5] ^ din[4] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[ 7] = din[7] ^ din[6] ^ din[5] ^ din[3] ^ din[2] ^ din[0] ^ crc_reg[24] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[ 8] = din[7] ^ din[6] ^ din[4] ^ din[3] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[ 9] = din[7] ^ din[5] ^ din[4] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[10] = din[5] ^ din[4] ^ din[3] ^ din[2] ^ din[0] ^ crc_reg[24] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[29];
    assign fb[11] = din[4] ^ din[3] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[12] = din[6] ^ din[5] ^ din[4] ^ din[2] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[13] = din[7] ^ din[6] ^ din[5] ^ din[3] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[29] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[14] = din[7] ^ din[6] ^ din[4] ^ din[3] ^ din[2] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[15] = din[7] ^ din[5] ^ din[4] ^ din[3] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[16] = din[5] ^ din[0] ^ crc_reg[24] ^ crc_reg[28] ^ crc_reg[29];
    assign fb[17] = din[6] ^ din[1] ^ crc_reg[25] ^ crc_reg[29] ^ crc_reg[30];
    assign fb[18] = din[7] ^ din[2] ^ crc_reg[26] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[19] = din[6] ^ din[3] ^ din[0] ^ crc_reg[24] ^ crc_reg[27] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[20] = din[7] ^ din[4] ^ din[1] ^ crc_reg[25] ^ crc_reg[28] ^ crc_reg[31];
    assign fb[21] = din[5] ^ din[2] ^ crc_reg[26] ^ crc_reg[29];
    assign fb[22] = din[6] ^ din[3] ^ din[0] ^ crc_reg[24] ^ crc_reg[27] ^ crc_reg[30];
    assign fb[23] = din[7] ^ din[6] ^ din[4] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[24] = din[7] ^ din[5] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[25] = din[6] ^ din[3] ^ din[2] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[30];
    assign fb[26] = din[7] ^ din[6] ^ din[4] ^ din[3] ^ din[1] ^ din[0] ^ crc_reg[24] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[27] = din[7] ^ din[5] ^ din[4] ^ din[2] ^ din[1] ^ crc_reg[25] ^ crc_reg[26] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[28] = din[6] ^ din[5] ^ din[3] ^ din[2] ^ din[0] ^ crc_reg[24] ^ crc_reg[26] ^ crc_reg[27] ^ crc_reg[29] ^ crc_reg[30];
    assign fb[29] = din[7] ^ din[6] ^ din[4] ^ din[3] ^ din[1] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[28] ^ crc_reg[30] ^ crc_reg[31];
    assign fb[30] = din[7] ^ din[5] ^ din[4] ^ din[2] ^ din[0] ^ crc_reg[24] ^ crc_reg[26] ^ crc_reg[28] ^ crc_reg[29] ^ crc_reg[31];
    assign fb[31] = din[6] ^ din[5] ^ din[3] ^ din[1] ^ crc_reg[25] ^ crc_reg[27] ^ crc_reg[29] ^ crc_reg[30];

    //--------------------------------------------------------------------------
    // CRC Register: sequential update
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign crc_result = 32'h00000000;
            assign crc_valid  = 1'b0;

        end else begin : gen_active

            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    crc_reg       <= 32'hFFFFFFFF;
                    crc_valid_reg <= 1'b0;
                end else begin
                    if (crc_en)
                        crc_reg <= crc_next;
                    else if (crc_eop)
                        crc_reg <= 32'hFFFFFFFF;        // Reset for next frame
                    else
                        crc_reg <= crc_reg;

                    crc_valid_reg <= crc_eop;           // Valid 1 cycle after EOP
                end
            end

            // IEEE 802.3: invert all bits for final FCS
            assign crc_result = ~crc_reg;
            assign crc_valid  = crc_valid_reg;

        end
    endgenerate

endmodule
