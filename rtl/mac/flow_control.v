// ============================================================================
// Module: FLOW_CONTROL
// File:    flow_control.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   IEEE 802.3x Flow Control module. Handles both TX and RX sides of
//   full-duplex Pause frame generation and response.
//
//   TX Side:
//     Monitors Rx FIFO fill level from MTL. When watermark reaches RFA
//     threshold, triggers MAC to send a Pause frame with programmable
//     Pause Time. When level drops below PLT, sends Zero-Quanta Pause.
//
//   RX Side:
//     Detects incoming Pause frames (DA=01:80:C2:00:00:01, Type=0x8808,
//     Opcode=0x0001). Extracts Pause Time and asserts pause_tx_stop to
//     halt the MAC TX data path.
//
// Reset Strategy:
//   Asynchronous reset, active low (rst_n).
//
// Clock Strategy:
//   gmii_clk domain — operates alongside the MAC core.
//
// Parameters:
//   P_SHELL_MODE    1 = Flow control disabled, never pause
// ============================================================================

module flow_control #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk,                  // gmii_clk
    input  wire        rst_n,                // Asynchronous reset, active low

    // Configuration (from CSR, synchronized)
    input  wire        tx_fc_enable,         // TX Flow Control enable (TFE)
    input  wire        rx_fc_enable,         // RX Flow Control enable (RFE)
    input  wire [ 1:0] tx_fc_rfa,            // Rx FIFO activate threshold: 00=50% 01=62.5% 10=75% 11=87.5%
    input  wire [ 3:0] tx_fc_plt,            // Pause low threshold (unit: 512B blocks)
    input  wire [15:0] tx_fc_pause_time,     // Pause Time value (512 bit times)
    input  wire        tx_fc_dzpq,           // Disable Zero-Quanta Pause

    // MTL Rx FIFO status (from MTL)
    input  wire [ 7:0] mtl_rx_fifo_level,    // Current Rx FIFO fill level (8-bit, ~= percentage*255)
    input  wire        mtl_rx_watermark_hi,  // FIFO fill >= RFA threshold
    input  wire        mtl_rx_watermark_lo,  // FIFO fill <= PLT threshold

    // Received frame Pause detection (from MAC RX parser)
    input  wire        rx_pause_detected,    // Incoming Pause frame detected
    input  wire [15:0] rx_pause_time,        // Pause Time from received Pause frame

    // Flow Control outputs
    output wire        tx_pause_request,     // Request MAC to send Pause frame
    output wire [15:0] tx_pause_time_out,    // Pause Time value to send
    output wire        tx_zero_quanta,       // Send Zero-Quanta Pause (cancel)
    output wire        pause_tx_stop,        // Halt MAC TX data path (RX Pause active)
    output wire        pause_active,         // Pause state indicator (for CSR)
    output wire [15:0] rx_pause_time_out     // Received Pause Time (for CSR status)
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    reg [15:0] pause_timer;                 // Countdown timer for RX Pause (unit: 512 bt)
    reg        pause_active_reg;            // Pause is active (timer > 0)
    reg        tx_pause_req_reg;            // TX Pause request (from watermarks)
    reg        tx_zq_reg;                   // Zero-Quanta request

    //--------------------------------------------------------------------------
    // TX Flow Control: Watermark → Pause request
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign tx_pause_request  = 1'b0;
            assign tx_pause_time_out = 16'd0;
            assign tx_zero_quanta    = 1'b0;
            assign pause_tx_stop     = 1'b0;
            assign pause_active      = 1'b0;
            assign rx_pause_time_out = 16'd0;

        end else begin : gen_active

            //------------------------------------------------------------------
            // TX Pause Request FSM
            // States: IDLE → PAUSE_SENT → ZERO_QUANTA → IDLE
            //------------------------------------------------------------------
            localparam FC_IDLE        = 2'd0;
            localparam FC_PAUSE_SENT  = 2'd1;
            localparam FC_ZERO_QUANTA = 2'd2;

            reg [1:0] fc_curr_st, fc_next_st;

            // State register
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    fc_curr_st <= FC_IDLE;
                else
                    fc_curr_st <= fc_next_st;
            end

            // Next-state logic
            always @(*) begin
                case (fc_curr_st)
                    FC_IDLE: begin
                        if (tx_fc_enable && mtl_rx_watermark_hi)
                            fc_next_st = FC_PAUSE_SENT;
                        else
                            fc_next_st = FC_IDLE;
                    end
                    FC_PAUSE_SENT: begin
                        if (mtl_rx_watermark_lo && ~tx_fc_dzpq)
                            fc_next_st = FC_ZERO_QUANTA;
                        else if (~mtl_rx_watermark_hi)
                            fc_next_st = FC_IDLE;
                        else
                            fc_next_st = FC_PAUSE_SENT;
                    end
                    FC_ZERO_QUANTA: begin
                        fc_next_st = FC_IDLE;
                    end
                    default: fc_next_st = FC_IDLE;
                endcase
            end

            // Output logic
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    tx_pause_req_reg <= 1'b0;
                    tx_zq_reg        <= 1'b0;
                end else begin
                    case (fc_curr_st)
                        FC_IDLE: begin
                            tx_pause_req_reg <= 1'b0;
                            tx_zq_reg        <= 1'b0;
                        end
                        FC_PAUSE_SENT: begin
                            tx_pause_req_reg <= (fc_curr_st != fc_next_st) ? 1'b0 : 1'b1;
                            tx_zq_reg        <= 1'b0;
                        end
                        FC_ZERO_QUANTA: begin
                            tx_pause_req_reg <= 1'b0;
                            tx_zq_reg        <= 1'b1;
                        end
                        default: begin
                            tx_pause_req_reg <= 1'b0;
                            tx_zq_reg        <= 1'b0;
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // RX Flow Control: Pause timer
            //------------------------------------------------------------------
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    pause_timer      <= 16'd0;
                    pause_active_reg <= 1'b0;
                end else begin
                    if (rx_fc_enable && rx_pause_detected) begin
                        // Load received Pause Time
                        pause_timer      <= rx_pause_time;
                        pause_active_reg <= (rx_pause_time != 16'd0);
                    end else if (pause_timer > 16'd0 && |pause_timer) begin
                        // Decrement timer every 512 bit times (every 64 bytes @ 1Gbps)
                        // Simplified: decrement once per clock, real impl uses prescaler
                        pause_timer      <= pause_timer - 16'd1;
                        pause_active_reg <= 1'b1;
                    end else begin
                        pause_timer      <= 16'd0;
                        pause_active_reg <= 1'b0;
                    end
                end
            end

            assign tx_pause_request  = tx_pause_req_reg;
            assign tx_pause_time_out = tx_fc_pause_time;
            assign tx_zero_quanta    = tx_zq_reg;
            assign pause_tx_stop     = pause_active_reg;
            assign pause_active      = pause_active_reg;
            assign rx_pause_time_out = rx_pause_time;

        end
    endgenerate

endmodule
