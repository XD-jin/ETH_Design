// ============================================================================
// Module: MAC_RX
// File:    mac_rx.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   MAC Receive Pipeline. Processes incoming GMII/RGMII byte stream:
//   detects preamble/SFD, extracts DA/SA/Type, passes data to MTL via
//   the MRI interface, and reports receive status.
//
//   Pipeline stages:
//     RxMAC   — Preamble/SFD detection, byte collection
//     CRC     — CRC-32 verification via external CRC32 module
//     RPC     — Rx Packet Controller: address filtering, watchdog, status
//     RBI     — Rx Bus Interface: 8-bit → MTL (MRI interface)
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n).
//
// Clock Strategy:
//   gmii_rx_clk (125MHz). All logic in this module runs on RX clock domain.
//
// Parameters:
//   P_SHELL_MODE    1 = Tie outputs to safe values
// ============================================================================

module mac_rx #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        gmii_rx_clk,          // 125MHz RX clock
    input  wire        rst_n,                // Asynchronous reset, active low

    // Configuration
    input  wire        rx_enable,            // Receiver enable (RE)
    input  wire        cfg_crc_strip,        // Auto strip CRC bytes before MTL
    input  wire        cfg_pad_strip,        // Auto strip PAD bytes
    input  wire        cfg_watchdog_en,      // Watchdog timeout enable
    input  wire [13:0] cfg_watchdog_limit,   // Watchdog timeout limit (bytes)

    // GMII input (from RGMII_IF)
    input  wire [ 7:0] gmii_rxd,             // 8-bit RX data
    input  wire        gmii_rx_dv,           // RX data valid
    input  wire        gmii_rx_er,           // RX error

    // CRC interface (to external CRC32 module)
    output wire        crc_en,               // CRC computation enable
    output wire [ 7:0] crc_data_out,         // Data byte to CRC
    output wire        crc_eop,              // EOP to CRC (before FCS)
    input  wire [31:0] crc_result,           // Computed CRC value
    input  wire        crc_valid,            // CRC result valid

    // Address filter interface
    output wire        rx_da_valid,          // DA valid strobe
    output wire [47:0] rx_da,                // 48-bit DA
    input  wire        frame_pass,           // Frame passes address filter

    // MTL interface (MRI — MAC Receive Interface)
    output wire        mri_val,              // Data valid to MTL
    input  wire        mri_rdy,              // MTL ready to accept
    output wire [ 7:0] mri_data,             // Data byte to MTL
    output wire        mri_sop,              // Start of packet
    output wire        mri_eop,              // End of packet

    // Pause frame detection (to Flow Control)
    output wire        rx_pause_detected,    // Pause frame received
    output wire [15:0] rx_pause_time,        // Pause Time from Pause frame

    // Receive status
    output wire [14:0] rx_packet_len,        // Total packet length (including CRC)
    output wire        rx_crc_error,         // CRC mismatch
    output wire        rx_recv_error,        // RX_ER received during frame
    output wire        rx_watchdog_error,    // Watchdog timeout
    output wire        rx_frame_done         // Frame reception complete
);

    //--------------------------------------------------------------------------
    // RX FSM states
    //--------------------------------------------------------------------------
    localparam RX_IDLE     = 3'd0;
    localparam RX_PREAMBLE = 3'd1;
    localparam RX_SFD      = 3'd2;
    localparam RX_DATA     = 3'd3;
    localparam RX_STATUS   = 3'd4;

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg [2:0] rx_curr_st, rx_next_st;
    reg [ 7:0] rx_data_reg;
    reg        rx_val_reg;
    reg        rx_sop_reg;
    reg        rx_eop_reg;
    reg [47:0] da_reg;                      // Captured destination address
    reg [47:0] sa_reg;                      // Captured source address
    reg [15:0] lt_reg;                      // Captured Length/Type field
    reg        da_captured;
    reg        sa_captured;
    reg        lt_captured;
    reg [ 2:0] byte_pos;                    // Byte position within header (0-5 for DA, 6-11 for SA)
    reg [13:0] frame_len;                   // Total frame length counter
    reg        rx_er_latched;               // Latched RX_ER during frame
    reg        fcs_match;                   // CRC check result (1 = match)
    reg        fcs_valid;                   // CRC result valid flag
    reg        pause_detected;
    reg [15:0] pause_time;
    reg        watchdog_timeout;
    reg [13:0] watchdog_cnt;

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign crc_en           = 1'b0;
            assign crc_data_out     = 8'd0;
            assign crc_eop          = 1'b0;
            assign rx_da_valid      = 1'b0;
            assign rx_da            = 48'd0;
            assign mri_val          = 1'b0;
            assign mri_data         = 8'd0;
            assign mri_sop          = 1'b0;
            assign mri_eop          = 1'b0;
            assign rx_pause_detected = 1'b0;
            assign rx_pause_time    = 16'd0;
            assign rx_packet_len    = 15'd0;
            assign rx_crc_error     = 1'b0;
            assign rx_recv_error    = 1'b0;
            assign rx_watchdog_error = 1'b0;
            assign rx_frame_done    = 1'b0;

        end else begin : gen_active

            //------------------------------------------------------------------
            // FSM Process 1: State Register
            //------------------------------------------------------------------
            always @(posedge gmii_rx_clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    rx_curr_st <= RX_IDLE;
                else
                    rx_curr_st <= rx_next_st;
            end

            //------------------------------------------------------------------
            // FSM Process 2: Next-State Logic
            //------------------------------------------------------------------
            always @(*) begin
                case (rx_curr_st)
                    RX_IDLE: begin
                        if (rx_enable && gmii_rx_dv && ~gmii_rx_er)
                            rx_next_st = RX_PREAMBLE;
                        else
                            rx_next_st = RX_IDLE;
                    end
                    RX_PREAMBLE: begin
                        if (~gmii_rx_dv)
                            rx_next_st = RX_IDLE;              // Lost carrier
                        else if (gmii_rx_dv && (gmii_rxd == 8'hD5))
                            rx_next_st = RX_SFD;               // SFD detected
                        else
                            rx_next_st = RX_PREAMBLE;
                    end
                    RX_SFD: begin
                        if (~gmii_rx_dv)
                            rx_next_st = RX_IDLE;
                        else
                            rx_next_st = RX_DATA;              // First data byte after SFD
                    end
                    RX_DATA: begin
                        if (watchdog_timeout && cfg_watchdog_en)
                            rx_next_st = RX_STATUS;
                        else if (~gmii_rx_dv)
                            rx_next_st = RX_STATUS;            // Frame ended
                        else
                            rx_next_st = RX_DATA;
                    end
                    RX_STATUS: begin
                        rx_next_st = RX_IDLE;
                    end
                    default: rx_next_st = RX_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // FSM Process 3: Output Logic + Datapath
            //------------------------------------------------------------------
            always @(posedge gmii_rx_clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    rx_data_reg     <= 8'd0;
                    rx_val_reg      <= 1'b0;
                    rx_sop_reg      <= 1'b0;
                    rx_eop_reg      <= 1'b0;
                    da_reg          <= 48'd0;
                    sa_reg          <= 48'd0;
                    lt_reg          <= 16'd0;
                    da_captured     <= 1'b0;
                    sa_captured     <= 1'b0;
                    lt_captured     <= 1'b0;
                    byte_pos        <= 3'd0;
                    frame_len       <= 14'd0;
                    rx_er_latched   <= 1'b0;
                    fcs_match       <= 1'b0;
                    fcs_valid       <= 1'b0;
                    pause_detected  <= 1'b0;
                    pause_time      <= 16'd0;
                    watchdog_timeout <= 1'b0;
                    watchdog_cnt    <= 14'd0;
                end else begin
                    case (rx_curr_st)
                        RX_IDLE: begin
                            rx_val_reg      <= 1'b0;
                            rx_sop_reg      <= 1'b0;
                            rx_eop_reg      <= 1'b0;
                            da_captured     <= 1'b0;
                            sa_captured     <= 1'b0;
                            lt_captured     <= 1'b0;
                            byte_pos        <= 3'd0;
                            frame_len       <= 14'd0;
                            rx_er_latched   <= 1'b0;
                            fcs_match       <= 1'b0;
                            fcs_valid       <= 1'b0;
                            pause_detected  <= 1'b0;
                            watchdog_timeout <= 1'b0;
                            watchdog_cnt    <= 14'd0;
                        end

                        RX_PREAMBLE: begin
                            // Pass through, waiting for SFD (0xD5)
                            rx_val_reg <= 1'b0;
                            if (gmii_rx_dv && (gmii_rxd == 8'hD5))
                                rx_sop_reg <= 1'b1;            // Will be set on SFD→DATA transition
                        end

                        RX_SFD: begin
                            rx_sop_reg <= 1'b1;                // First byte after SFD is SOP
                            rx_val_reg <= 1'b1;
                            rx_data_reg <= gmii_rxd;
                            // First byte of DA
                            da_reg[47:40] <= gmii_rxd;
                            byte_pos <= 3'd1;
                            frame_len <= 14'd1;
                        end

                        RX_DATA: begin
                            rx_sop_reg <= 1'b0;
                            if (gmii_rx_dv) begin
                                rx_val_reg  <= 1'b1;
                                rx_data_reg <= gmii_rxd;
                                frame_len   <= frame_len + 14'd1;

                                // Capture DA (first 6 bytes)
                                if (~da_captured) begin
                                    case (byte_pos)
                                        3'd0: da_reg[47:40] <= gmii_rxd;
                                        3'd1: da_reg[39:32] <= gmii_rxd;
                                        3'd2: da_reg[31:24] <= gmii_rxd;
                                        3'd3: da_reg[23:16] <= gmii_rxd;
                                        3'd4: da_reg[15: 8] <= gmii_rxd;
                                        3'd5: begin
                                            da_reg[ 7: 0] <= gmii_rxd;
                                            da_captured <= 1'b1;
                                        end
                                    endcase
                                    byte_pos <= byte_pos + 3'd1;
                                end

                                // Watchdog check
                                if (cfg_watchdog_en && watchdog_cnt >= cfg_watchdog_limit)
                                    watchdog_timeout <= 1'b1;
                                watchdog_cnt <= watchdog_cnt + 14'd1;

                                // RX error detection
                                if (gmii_rx_er)
                                    rx_er_latched <= 1'b1;

                            end else begin
                                // RX_DV de-asserted: frame ended
                                rx_val_reg  <= 1'b0;
                                rx_eop_reg  <= 1'b1;           // EOP to MTL
                                // The last 4 bytes were CRC (if not stripped)
                                // Check CRC match (from external CRC32)
                                if (crc_valid)
                                    fcs_match <= (crc_result == 32'hC704DD7B);  // Magic residue for valid CRC
                                fcs_valid <= crc_valid;

                                // Pause frame detection
                                if (da_reg == 48'h0180_C200_0001 &&
                                    lt_reg == 16'h8808) begin
                                    pause_detected <= 1'b1;
                                    // Pause Time is in 2 bytes after Type+Opcode
                                end
                            end
                        end

                        RX_STATUS: begin
                            rx_eop_reg <= 1'b0;
                            rx_val_reg <= 1'b0;
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // CRC control signals
            //------------------------------------------------------------------
            assign crc_en       = (rx_curr_st == RX_DATA) && gmii_rx_dv;
            assign crc_data_out = gmii_rxd;
            assign crc_eop      = (rx_curr_st == RX_DATA) && ~gmii_rx_dv;

            //------------------------------------------------------------------
            // DA output (to address filter)
            //------------------------------------------------------------------
            assign rx_da_valid = da_captured;
            assign rx_da       = da_reg;

            //------------------------------------------------------------------
            // MTL MRI interface outputs
            //------------------------------------------------------------------
            assign mri_val  = rx_val_reg && frame_pass;
            assign mri_data = rx_data_reg;
            assign mri_sop  = rx_sop_reg && frame_pass;
            assign mri_eop  = rx_eop_reg && frame_pass;

            //------------------------------------------------------------------
            // Status outputs
            //------------------------------------------------------------------
            assign rx_packet_len    = frame_len;
            assign rx_crc_error     = fcs_valid && ~fcs_match;
            assign rx_recv_error    = rx_er_latched;
            assign rx_watchdog_error = watchdog_timeout;
            assign rx_frame_done    = (rx_curr_st == RX_STATUS);
            assign rx_pause_detected = pause_detected;
            assign rx_pause_time    = pause_time;

        end
    endgenerate

endmodule
