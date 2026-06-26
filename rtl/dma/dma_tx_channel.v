// ============================================================================
// Module: DMA_TX_CHANNEL
// File:    dma_tx_channel.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: Single TX DMA channel — descriptor fetch, data read from system
//   memory via AHB master, push to MTL via ATI interface. Supports ring descriptor.
// ============================================================================

module dma_tx_channel #(
    parameter P_RING_LEN   = 64,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,

    // CSR registers
    input  wire        ch_start,              // Start TX DMA
    input  wire [31:0] desc_base,             // Descriptor ring base address
    input  wire [ 7:0] desc_tail,             // Descriptor tail pointer (index)
    input  wire [ 7:0] desc_len,              // Ring length
    input  wire [ 4:0] tx_pbl,                // Programmable burst length

    // AHB Master interface
    output wire        ahb_req,               // Request AHB bus
    input  wire        ahb_grant,             // Bus granted
    output wire [31:0] ahb_addr,              // Read address
    output wire [ 3:0] ahb_burst,             // Burst length
    input  wire [31:0] ahb_rdata,             // Read data
    input  wire        ahb_ready,             // Data valid
    input  wire        ahb_error,             // Bus error

    // ATI interface (to MTL)
    output wire        ati_val,
    input  wire        ati_rdy,
    output wire [31:0] ati_data,
    output wire        ati_sop,
    output wire        ati_eop,
    output wire [ 1:0] ati_be,

    // Status
    output wire        ch_done,               // Channel transfer complete
    output wire        ch_error,              // Bus error
    output wire        ch_suspended           // OWN=0, waiting for tail update
);

    localparam ST_IDLE    = 3'd0;
    localparam ST_FETCH   = 3'd1;
    localparam ST_DATA    = 3'd2;
    localparam ST_WAIT    = 3'd3;

    reg [ 2:0] curr_st, next_st;
    reg [ 7:0] current_desc;                  // Current descriptor index
    reg [31:0] desc_addr;                     // Current descriptor address
    reg [31:0] buf1_addr, buf2_addr;          // Buffer addresses
    reg [15:0] buf1_len, buf2_len;            // Buffer lengths
    reg        fd, ld;                        // First/Last descriptor flags
    reg        ioc;                           // Interrupt on completion
    reg [ 1:0] cpc;                           // CRC pad control
    reg        own_bit;                       // Descriptor own bit
    reg [15:0] byte_cnt;                      // Bytes transferred in current buffer
    reg        active_buf;                    // 0=buf1, 1=buf2

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req   = 1'b0;
            assign ahb_addr  = 32'd0;
            assign ahb_burst = 4'd0;
            assign ati_val   = 1'b0;
            assign ati_data  = 32'd0;
            assign ati_sop   = 1'b0;
            assign ati_eop   = 1'b0;
            assign ati_be    = 2'd0;
            assign ch_done   = 1'b0;
            assign ch_error  = 1'b0;
            assign ch_suspended = 1'b0;
        end else begin : gen_active
            // State register
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    curr_st <= ST_IDLE;
                else
                    curr_st <= next_st;
            end

            // Next-state logic
            always @(*) begin
                case (curr_st)
                    ST_IDLE:  next_st = ch_start ? ST_FETCH : ST_IDLE;
                    ST_FETCH: next_st = ahb_ready ? ST_DATA : ST_FETCH;
                    ST_DATA: begin
                        if (ahb_error)          next_st = ST_IDLE;
                        else if (ati_rdy && ati_eop) next_st = ST_WAIT;
                        else                     next_st = ST_DATA;
                    end
                    ST_WAIT:  next_st = (current_desc + 1 < desc_tail) ? ST_FETCH : ST_IDLE;
                    default:  next_st = ST_IDLE;
                endcase
            end

            // Datapath
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    current_desc <= 8'd0;
                    desc_addr    <= 32'd0;
                    byte_cnt     <= 16'd0;
                    own_bit      <= 1'b0;
                    active_buf   <= 1'b0;
                end else begin
                    case (curr_st)
                        ST_IDLE: begin
                            current_desc <= 8'd0;
                            byte_cnt <= 16'd0;
                        end
                        ST_FETCH: begin
                            desc_addr <= desc_base + (current_desc * 32'd16);
                        end
                        ST_DATA: begin
                            if (ati_rdy) begin
                                byte_cnt <= byte_cnt + 16'd4;  // 32-bit words
                                // Switch to buffer 2 if buffer 1 exhausted
                                if (byte_cnt >= buf1_len && ~active_buf) begin
                                    active_buf <= 1'b1;
                                    byte_cnt   <= 16'd0;
                                end
                            end
                        end
                        ST_WAIT: begin
                            current_desc <= (current_desc == desc_len - 1) ? 8'd0 : current_desc + 8'd1;
                            byte_cnt     <= 16'd0;
                            active_buf   <= 1'b0;
                        end
                    endcase
                end
            end

            assign ahb_req   = (curr_st == ST_FETCH) || (curr_st == ST_DATA);
            assign ahb_addr  = (curr_st == ST_FETCH) ? desc_addr : (active_buf ? buf2_addr + byte_cnt : buf1_addr + byte_cnt);
            assign ahb_burst = 4'd1;  // INCR burst
            assign ati_val   = (curr_st == ST_DATA) && ahb_ready;
            assign ati_data  = ahb_rdata;
            assign ati_sop   = (curr_st == ST_DATA) && (byte_cnt == 16'd0) && ~active_buf;
            assign ati_eop   = (curr_st == ST_DATA) && ld && active_buf && (byte_cnt + 4 >= buf2_len);
            assign ati_be    = 2'b11;
            assign ch_done   = (curr_st == ST_WAIT);
            assign ch_error  = ahb_error;
            assign ch_suspended = (curr_st == ST_IDLE) && ch_start;
        end
    endgenerate

endmodule
