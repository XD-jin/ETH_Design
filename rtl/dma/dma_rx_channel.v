// ============================================================================
// Module: DMA_RX_CHANNEL
// File:    dma_rx_channel.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: Single RX DMA channel — receives data from MTL via ARI interface,
//   writes to system memory via AHB master. Ring descriptor based.
// ============================================================================

module dma_rx_channel #(
    parameter P_RING_LEN   = 64,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,
    input  wire        ch_start,
    input  wire [31:0] desc_base,
    input  wire [ 7:0] desc_tail,
    input  wire [ 7:0] desc_len,
    input  wire [ 4:0] rx_pbl,
    input  wire [13:0] rx_buf_size,

    // AHB Master interface
    output wire        ahb_req,
    input  wire        ahb_grant,
    output wire [31:0] ahb_addr,
    output wire [31:0] ahb_wdata,
    output wire [ 3:0] ahb_burst,
    input  wire        ahb_ready,
    input  wire        ahb_error,

    // ARI interface (from MTL)
    input  wire        ari_val,
    output wire        ari_rdy,
    input  wire [31:0] ari_data,
    input  wire        ari_sop,
    input  wire        ari_eop,

    // Status
    output wire        ch_done,
    output wire        ch_error,
    output wire        ch_overflow
);

    localparam ST_IDLE  = 2'd0;
    localparam ST_DATA  = 2'd1;
    localparam ST_FLUSH = 2'd2;

    reg [1:0] curr_st, next_st;
    reg [7:0] current_desc;
    reg [31:0] buf_addr;
    reg [14:0] packet_len;
    reg        crc_error, recv_error, overflow_error;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req   = 1'b0;
            assign ahb_addr  = 32'd0;
            assign ahb_wdata = 32'd0;
            assign ahb_burst = 4'd0;
            assign ari_rdy   = 1'b1;
            assign ch_done   = 1'b0;
            assign ch_error  = 1'b0;
            assign ch_overflow = 1'b0;
        end else begin : gen_active
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    curr_st <= ST_IDLE;
                else
                    curr_st <= next_st;
            end

            always @(*) begin
                case (curr_st)
                    ST_IDLE:  next_st = (ch_start && ari_val) ? ST_DATA : ST_IDLE;
                    ST_DATA:  next_st = (ahb_error || ari_eop) ? ST_FLUSH : ST_DATA;
                    ST_FLUSH: next_st = ST_IDLE;
                    default:  next_st = ST_IDLE;
                endcase
            end

            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    current_desc  <= 8'd0;
                    buf_addr      <= 32'd0;
                    packet_len    <= 15'd0;
                    crc_error     <= 1'b0;
                    recv_error    <= 1'b0;
                    overflow_error <= 1'b0;
                end else begin
                    if (curr_st == ST_IDLE) begin
                        packet_len <= 15'd0;
                    end
                    if (curr_st == ST_DATA && ari_val) begin
                        packet_len <= packet_len + 15'd4;
                    end
                    if (curr_st == ST_FLUSH) begin
                        current_desc <= (current_desc == desc_len - 1) ? 8'd0 : current_desc + 8'd1;
                    end
                end
            end

            assign ahb_req   = (curr_st == ST_DATA);
            assign ahb_addr  = buf_addr + packet_len;
            assign ahb_wdata = ari_data;
            assign ahb_burst = 4'd1;
            assign ari_rdy   = (curr_st == ST_DATA) && ahb_ready;
            assign ch_done   = (curr_st == ST_FLUSH);
            assign ch_error  = ahb_error;
            assign ch_overflow = overflow_error;
        end
    endgenerate

endmodule
