// ============================================================================
// Module: DMA_RX_CHANNEL
// File:    dma_rx_channel.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
// Description: Single RX DMA channel — fetches empty descriptor from ring,
//   receives packet data from MTL via ARI, writes to system memory via AHB
//   master, and writes back descriptor status.
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
    input  wire [ 3:0] rx_pbl,
    input  wire [13:0] rx_buf_size,

    // AHB Master interface
    output wire        ahb_req,
    input  wire        ahb_grant,
    output wire [31:0] ahb_addr,
    output wire [31:0] ahb_wdata,
    output wire [ 2:0] ahb_burst,
    input  wire        ahb_ready,
    input  wire [31:0] ahb_rdata,   // Read data from AHB
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

    localparam ST_IDLE      = 4'd0;
    localparam ST_FETCH_DESC = 4'd1;       // Read 16B descriptor from memory
    localparam ST_WAIT_DATA = 4'd2;        // Wait for ARI data from MTL
    localparam ST_WRITE_BUF = 4'd3;        // Write packet data to memory
    localparam ST_WRITEBACK  = 4'd4;        // Write descriptor status back
    localparam ST_NEXT_DESC  = 4'd5;        // Advance to next descriptor

    reg [3:0] curr_st, next_st;

    reg [ 7:0] current_desc;               // Current descriptor index
    reg [31:0] desc_addr;                  // Current descriptor physical address
    reg [31:0] buf1_addr;                  // Buffer 1 address (from RDES0)
    reg [31:0] buf2_addr;                  // Buffer 2 address (from RDES2)
    reg        own_bit;                    // Descriptor OWN bit
    reg        ioc_bit;                    // Interrupt on completion
    reg        buf1_valid;                 // Buffer 1 address valid (BUF1V)
    reg        buf2_valid;                 // Buffer 2 address valid (BUF2V)
    reg [14:0] packet_len;                 // Accumulated packet byte count
    reg [14:0] byte_in_buf;                // Byte offset within current buffer
    reg        active_buf;                 // 0=buf1, 1=buf2
    reg        eop_received;               // EOP seen from ARI
    reg        overflow;                   // Buffer overflow flag
    reg        crc_error;                  // CRC error flag (from EOP status)
    reg        desc_writeback_done;        // Descriptor status written back

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req    = 1'b0;
            assign ahb_addr   = 32'd0;
            assign ahb_wdata  = 32'd0;
            assign ahb_burst  = 4'd0;
            assign ari_rdy    = 1'b1;
            assign ch_done    = 1'b0;
            assign ch_error   = 1'b0;
            assign ch_overflow = 1'b0;
        end else begin : gen_active

            //------------------------------------------------------------------
            // State Register
            //------------------------------------------------------------------
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0)
                    curr_st <= ST_IDLE;
                else
                    curr_st <= next_st;
            end

            //------------------------------------------------------------------
            // Next-State Logic
            //------------------------------------------------------------------
            always @(*) begin
                case (curr_st)
                    ST_IDLE: begin
                        if (ch_start && (current_desc != desc_tail))
                            next_st = ST_FETCH_DESC;
                        else
                            next_st = ST_IDLE;
                    end
                    ST_FETCH_DESC: begin
                        if (ahb_ready)
                            next_st = ST_WAIT_DATA;       // Descriptor fetched
                        else
                            next_st = ST_FETCH_DESC;
                    end
                    ST_WAIT_DATA: begin
                        if (ari_val && ari_sop)
                            next_st = ST_WRITE_BUF;       // Start of packet arrived
                        else if (current_desc == desc_tail)
                            next_st = ST_IDLE;             // No descriptors available
                        else
                            next_st = ST_WAIT_DATA;
                    end
                    ST_WRITE_BUF: begin
                        if (ahb_error)
                            next_st = ST_WRITEBACK;
                        else if (eop_received && (active_buf || byte_in_buf >= rx_buf_size))
                            next_st = ST_WRITEBACK;
                        else
                            next_st = ST_WRITE_BUF;
                    end
                    ST_WRITEBACK: begin
                        if (desc_writeback_done)
                            next_st = ST_NEXT_DESC;
                        else
                            next_st = ST_WRITEBACK;
                    end
                    ST_NEXT_DESC: begin
                        next_st = ST_IDLE;
                    end
                    default: next_st = ST_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // Datapath
            //------------------------------------------------------------------
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    current_desc  <= 8'd0;
                    desc_addr     <= 32'd0;
                    buf1_addr     <= 32'd0;
                    buf2_addr     <= 32'd0;
                    own_bit       <= 1'b0;
                    ioc_bit       <= 1'b0;
                    buf1_valid    <= 1'b0;
                    buf2_valid    <= 1'b0;
                    packet_len    <= 15'd0;
                    byte_in_buf   <= 15'd0;
                    active_buf    <= 1'b0;
                    eop_received  <= 1'b0;
                    overflow      <= 1'b0;
                    crc_error     <= 1'b0;
                    desc_writeback_done <= 1'b0;
                end else begin
                    case (curr_st)
                        ST_IDLE: begin
                            packet_len    <= 15'd0;
                            byte_in_buf   <= 15'd0;
                            active_buf    <= 1'b0;
                            eop_received  <= 1'b0;
                            overflow      <= 1'b0;
                            desc_writeback_done <= 1'b0;
                            desc_addr <= desc_base + (current_desc * 32'd16);
                        end

                        ST_FETCH_DESC: begin
                            if (ahb_ready) begin
                                // Parse descriptor read from memory
                                // RDES0[31:0] = buf1_addr (simplified: stored in buf1_addr)
                                buf1_addr  <= ahb_rdata;
                                buf1_valid <= 1'b1;
                                // RDES3[25] = BUF2V, RDES3[24] = BUF1V
                                // Simplified: both valid
                                buf2_valid <= 1'b1;
                                buf2_addr  <= ari_data + rx_buf_size;  // Simplified
                                ioc_bit    <= 1'b0;  // Simplified
                            end
                        end

                        ST_WRITE_BUF: begin
                            if (ari_val && ahb_ready) begin
                                packet_len  <= packet_len + 15'd4;
                                byte_in_buf <= byte_in_buf + 15'd4;
                                if (ari_eop)
                                    eop_received <= 1'b1;
                                // Switch to buffer 2 when buffer 1 is full
                                if (byte_in_buf >= rx_buf_size && ~active_buf && buf2_valid) begin
                                    active_buf  <= 1'b1;
                                    byte_in_buf <= 15'd0;
                                end
                                if (byte_in_buf >= rx_buf_size && active_buf)
                                    overflow <= 1'b1;
                            end
                        end

                        ST_WRITEBACK: begin
                            // Write descriptor status back to memory
                            // RDES3[31]=0 (OWN cleared), RDES3[15]=ES, RDES3[24]=CE
                            // Simplified: single write at current_desc address + 12
                            desc_writeback_done <= 1'b1;
                        end

                        ST_NEXT_DESC: begin
                            current_desc <= (current_desc == desc_len - 1) ? 8'd0 : current_desc + 8'd1;
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // AHB request and address
            //------------------------------------------------------------------
            assign ahb_req   = (curr_st == ST_FETCH_DESC) || (curr_st == ST_WRITE_BUF) || (curr_st == ST_WRITEBACK);
            assign ahb_addr  = (curr_st == ST_FETCH_DESC) ? desc_addr :
                               (curr_st == ST_WRITEBACK)  ? (desc_addr + 32'd12) :
                               (active_buf ? buf2_addr + byte_in_buf : buf1_addr + byte_in_buf);
            assign ahb_wdata = (curr_st == ST_WRITEBACK) ?
                               {1'b0, 15'd0, packet_len} :   // Status word (OWN=0, PL=packet_len)
                               ari_data;                       // Packet data
            assign ahb_burst = 4'd1;

            //------------------------------------------------------------------
            // ARI ready: accept data when writing to buffer and AHB is not busy
            //------------------------------------------------------------------
            assign ari_rdy   = (curr_st == ST_WRITE_BUF) && ahb_ready;
            assign ch_done   = (curr_st == ST_NEXT_DESC);
            assign ch_error  = ahb_error;
            assign ch_overflow = overflow;

        end
    endgenerate

endmodule
