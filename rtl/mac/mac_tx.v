// ============================================================================
// Module: MAC_TX
// File:    mac_tx.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   MAC Transmit Pipeline. Converts 8-bit byte stream from MTL (MTI interface)
//   into a complete Ethernet frame with Preamble, SFD, CRC, and IFG.
//
//   Pipeline stages:
//     TBU (Tx Bus Interface) — 8-bit data reception, byte counting
//     TPC (Tx Packet Controller) — PAD insertion, CRC pass-through control
//     TPE (Tx Protocol Engine) — FSM: Preamble→SFD→Data→CRC→IFG→Idle
//
//   CRC-32 is computed by the external CRC32 module and appended after EOP.
//   Frame under 60 bytes are automatically padded with zeros.
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n).
//
// Clock Strategy:
//   gmii_tx_clk (125MHz). All logic in this module runs on the TX clock.
//
// Parameters:
//   P_SHELL_MODE    1 = Tie outputs to safe values
// ============================================================================

module mac_tx #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        gmii_tx_clk,          // 125MHz TX clock
    input  wire        rst_n,                // Asynchronous reset, active low

    // Configuration
    input  wire        tx_enable,            // Transmitter enable (TE)
    input  wire [ 1:0] cfg_ifg,              // IFG control: 00=96 01=88 10=80 11=72 bt
    input  wire        cfg_jabber_disable,   // Disable jabber timeout
    input  wire        cfg_crc_pad_ctl,      // CRC/PAD control from descriptor
    input  wire        cfg_preamble_short,   // Shortened preamble (5B vs 7B)

    // MTL interface (MTI — MAC Transmit Interface)
    input  wire        mti_val,              // Data valid from MTL
    output wire        mti_rdy,              // Ready to accept data
    input  wire [ 7:0] mti_data,             // Data byte from MTL
    input  wire        mti_sop,              // Start of packet
    input  wire        mti_eop,              // End of packet

    // CRC interface (to external CRC32 module)
    output wire        crc_en,               // CRC computation enable
    output wire [ 7:0] crc_data_out,         // Data byte to CRC
    output wire        crc_eop,              // EOP to CRC
    input  wire [31:0] crc_result,           // Computed CRC value
    input  wire        crc_valid,            // CRC valid

    // GMII output (to RGMII_IF)
    output wire [ 7:0] gmii_txd,             // 8-bit TX data
    output wire        gmii_tx_en,           // TX enable
    output wire        gmii_tx_er,           // TX error (always 0 in full-duplex)

    // Status
    output wire        tx_frame_done,        // Frame transmission complete
    output wire        tx_underflow,         // Underflow error
    output wire        tx_jabber             // Jabber timeout
);

    //--------------------------------------------------------------------------
    // TX Protocol Engine FSM states
    //--------------------------------------------------------------------------
    localparam TX_IDLE     = 3'd0;
    localparam TX_PREAMBLE = 3'd1;
    localparam TX_SFD      = 3'd2;
    localparam TX_DATA     = 3'd3;
    localparam TX_CRC      = 3'd4;
    localparam TX_IFG      = 3'd5;

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg [2:0] tx_curr_st, tx_next_st;       // FSM state
    reg [ 7:0] tx_data_reg;                 // Output data register
    reg        tx_en_reg;                    // Output enable register
    reg [15:0] byte_cnt;                    // Byte counter
    reg [ 7:0] ifg_cnt;                     // IFG counter
    reg [ 4:0] preamble_cnt;                // Preamble byte counter (7 or 5)
    reg [ 2:0] crc_byte_cnt;                // CRC byte counter (0-3)
    reg [31:0] crc_latch;                   // Latched CRC result
    reg [13:0] frame_len;                   // Frame data length counter
    reg        eop_received;                // EOP flag from MTL
    reg        pad_active;                  // PAD insertion active
    reg [ 5:0] pad_cnt;                     // PAD byte counter
    reg        jabber_timeout;              // Jabber timeout flag

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign gmii_txd     = 8'd0;
            assign gmii_tx_en   = 1'b0;
            assign gmii_tx_er   = 1'b0;
            assign mti_rdy      = 1'b1;
            assign crc_en       = 1'b0;
            assign crc_data_out = 8'd0;
            assign crc_eop      = 1'b0;
            assign tx_frame_done = 1'b0;
            assign tx_underflow  = 1'b0;
            assign tx_jabber     = 1'b0;

        end else begin : gen_active

            //------------------------------------------------------------------
            // FSM Process 1: State Register
            //------------------------------------------------------------------
            always @(posedge gmii_tx_clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    tx_curr_st <= TX_IDLE;
                else
                    tx_curr_st <= tx_next_st;
            end

            //------------------------------------------------------------------
            // FSM Process 2: Next-State Logic
            //------------------------------------------------------------------
            always @(*) begin
                case (tx_curr_st)
                    TX_IDLE: begin
                        if (tx_enable && mti_val && mti_sop)
                            tx_next_st = TX_PREAMBLE;
                        else
                            tx_next_st = TX_IDLE;
                    end
                    TX_PREAMBLE: begin
                        if (preamble_cnt == (cfg_preamble_short ? 5'd4 : 5'd6))
                            tx_next_st = TX_SFD;
                        else
                            tx_next_st = TX_PREAMBLE;
                    end
                    TX_SFD: begin
                        tx_next_st = TX_DATA;
                    end
                    TX_DATA: begin
                        if (jabber_timeout && ~cfg_jabber_disable)
                            tx_next_st = TX_IFG;
                        else if (eop_received && pad_active && pad_cnt > 0)
                            tx_next_st = TX_DATA;   // Keep padding
                        else if (eop_received && (~pad_active || pad_cnt == 0))
                            tx_next_st = TX_CRC;
                        else
                            tx_next_st = TX_DATA;
                    end
                    TX_CRC: begin
                        if (crc_byte_cnt == 3'd4)
                            tx_next_st = TX_IFG;
                        else
                            tx_next_st = TX_CRC;
                    end
                    TX_IFG: begin
                        if (ifg_cnt >= 8'd11)      // 12 bytes = 96 bit times min
                            tx_next_st = TX_IDLE;
                        else
                            tx_next_st = TX_IFG;
                    end
                    default: tx_next_st = TX_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // FSM Process 3: Output Logic + Datapath
            //------------------------------------------------------------------
            always @(posedge gmii_tx_clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    tx_data_reg    <= 8'd0;
                    tx_en_reg      <= 1'b0;
                    preamble_cnt   <= 5'd0;
                    crc_byte_cnt   <= 3'd0;
                    crc_latch      <= 32'd0;
                    ifg_cnt        <= 8'd0;
                    frame_len      <= 14'd0;
                    eop_received   <= 1'b0;
                    pad_active     <= 1'b0;
                    pad_cnt        <= 6'd0;
                    jabber_timeout <= 1'b0;
                    byte_cnt       <= 16'd0;
                end else begin
                    case (tx_curr_st)
                        TX_IDLE: begin
                            tx_data_reg    <= 8'd0;
                            tx_en_reg      <= 1'b0;
                            preamble_cnt   <= 5'd0;
                            crc_byte_cnt   <= 3'd0;
                            ifg_cnt        <= 8'd0;
                            frame_len      <= 14'd0;
                            eop_received   <= 1'b0;
                            pad_active     <= 1'b0;
                            pad_cnt        <= 6'd0;
                            jabber_timeout <= 1'b0;
                            byte_cnt       <= 16'd0;
                            if (mti_val && mti_sop) begin
                                tx_en_reg <= 1'b1;
                            end
                        end

                        TX_PREAMBLE: begin
                            tx_data_reg  <= 8'h55;              // Preamble byte
                            tx_en_reg    <= 1'b1;
                            preamble_cnt <= preamble_cnt + 5'd1;
                        end

                        TX_SFD: begin
                            tx_data_reg  <= 8'hD5;              // SFD byte
                            tx_en_reg    <= 1'b1;
                            preamble_cnt <= 5'd0;
                        end

                        TX_DATA: begin
                            tx_en_reg <= 1'b1;
                            if (~eop_received && mti_val) begin
                                // Normal data from MTL
                                tx_data_reg <= mti_data;
                                frame_len   <= frame_len + 14'd1;
                                if (mti_eop) begin
                                    eop_received <= 1'b1;
                                    // Check minimum frame length (60B including DA+SA+Type)
                                    if (frame_len < 14'd46)
                                        pad_active <= 1'b1;
                                    pad_cnt <= 6'd46 - frame_len[5:0];
                                end
                            end else if (pad_active && pad_cnt > 0) begin
                                // Insert PAD bytes (0x00)
                                tx_data_reg <= 8'h00;
                                pad_cnt     <= pad_cnt - 6'd1;
                                frame_len   <= frame_len + 14'd1;
                            end else if (eop_received) begin
                                tx_data_reg <= mti_data;        // Last data byte
                            end
                            if (byte_cnt > 16'd16383)            // Jabber: ~16KB
                                jabber_timeout <= 1'b1;
                            byte_cnt <= byte_cnt + 16'd1;
                        end

                        TX_CRC: begin
                            tx_en_reg <= 1'b1;
                            if (crc_byte_cnt == 3'd0)
                                crc_latch <= crc_result;       // Latch final CRC
                            // Send CRC LSB first (IEEE 802.3 requirement)
                            case (crc_byte_cnt)
                                3'd0: tx_data_reg <= crc_latch[ 7: 0];
                                3'd1: tx_data_reg <= crc_latch[15: 8];
                                3'd2: tx_data_reg <= crc_latch[23:16];
                                3'd3: tx_data_reg <= crc_latch[31:24];
                            endcase
                            crc_byte_cnt <= crc_byte_cnt + 3'd1;
                        end

                        TX_IFG: begin
                            tx_data_reg <= 8'd0;
                            tx_en_reg   <= 1'b0;               // De-assert TX_EN during IFG
                            ifg_cnt     <= ifg_cnt + 8'd1;
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // CRC control signals
            //------------------------------------------------------------------
            assign crc_en       = (tx_curr_st == TX_DATA) && mti_val;
            assign crc_data_out = mti_data;
            assign crc_eop      = (tx_curr_st == TX_DATA) && mti_val && mti_eop;

            //------------------------------------------------------------------
            // MTL back-pressure: ready when in DATA state and not done
            //------------------------------------------------------------------
            assign mti_rdy = (tx_curr_st == TX_DATA) && ~eop_received;

            //------------------------------------------------------------------
            // GMII outputs
            //------------------------------------------------------------------
            assign gmii_txd   = tx_data_reg;
            assign gmii_tx_en = tx_en_reg;
            assign gmii_tx_er = 1'b0;                          // No errors in full-duplex

            //------------------------------------------------------------------
            // Status outputs
            //------------------------------------------------------------------
            assign tx_frame_done = (tx_curr_st == TX_IFG) && (ifg_cnt == 8'd0);
            assign tx_underflow  = (tx_curr_st == TX_DATA) && mti_val && ~mti_eop && ~mti_rdy;
            assign tx_jabber     = jabber_timeout;

        end
    endgenerate

endmodule
