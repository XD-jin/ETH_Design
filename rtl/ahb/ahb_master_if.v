// ============================================================================
// Module: AHB_MASTER_IF
// File:    ahb_master_if.v
// Author:  ETH_Design Team
// Version: v2.1
// Date:    2026-06-27
//
// Description:
//   AMBA 2.0 AHB Master for DMA. Two-phase pipelined protocol.
//   - Phase 1 (Address): drives HADDR/HWRITE/HTRANS/HSIZE/HBURST/HPROT
//   - Phase 2 (Data):    samples HRDATA (read) or drives HWDATA (write)
//   - HPROT = 4'b0011 (data, unprivileged, non-bufferable, non-cacheable)
//   - 1KB boundary auto-splitting for INCR bursts
//   - Early burst termination on ERROR response
//   - SINGLE and INCR burst types only
// ============================================================================

module ahb_master_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk,
    input  wire        hresetn,

    // DMA interface
    input  wire        dma_req,
    output wire        dma_grant,
    input  wire [31:0] dma_addr,
    input  wire [31:0] dma_wdata,
    output wire [31:0] dma_rdata,
    input  wire [ 3:0] dma_burst_len,
    input  wire        dma_write,
    output wire        dma_ready,
    output wire        dma_error,

    // AHB Master bus
    output wire [31:0] haddr_o,
    output wire        hwrite_o,
    output wire [31:0] hwdata_o,
    output wire [ 2:0] hsize_o,
    output wire [ 2:0] hburst_o,
    output wire [ 3:0] hprot_o,        // AMBA 2.0 required
    output wire [ 1:0] htrans_o,
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i,
    output wire        rdata_valid
);

    localparam ST_IDLE = 2'd0;
    localparam ST_ADDR = 2'd1;
    localparam ST_DATA = 2'd2;

    reg [1:0] curr_st, next_st;

    reg [31:0] addr_reg;
    reg        write_reg;
    reg [31:0] wdata_reg;
    reg [ 3:0] burst_cnt_reg;
    reg        beat_first;
    reg [31:0] hrdata_reg;
    reg        ready_reg;
    reg        error_reg;
    reg        abort_reg;          // ERROR response → abort remaining burst

    // 1KB boundary = bits [9:0] of address cross 0x400 during increment
    wire addr_1kb_cross;
    assign addr_1kb_cross = (addr_reg[9:0] + 10'd4) > 10'h3FC;

    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign haddr_o   = 32'd0;
            assign hwrite_o  = 1'b0;
            assign hwdata_o  = 32'd0;
            assign hsize_o   = 3'd2;
            assign hburst_o  = 3'd0;
            assign hprot_o   = 4'h3;
            assign htrans_o  = 2'd0;
            assign dma_grant  = 1'b0;
            assign dma_rdata  = 32'd0;
            assign dma_ready  = 1'b0;
            assign dma_error  = 1'b0;
        end else begin : gen_active
    reg rdata_valid;

            //------------------------------------------------------------------
            // State Register
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0)
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
                        if (dma_req)            next_st = ST_ADDR;
                        else                    next_st = ST_IDLE;
                    end
                    ST_ADDR:                    next_st = ST_DATA;
                    ST_DATA: begin
                        if (hready_i) begin
                            if (abort_reg || burst_cnt_reg <= 4'd1)
                                                next_st = ST_IDLE;
                            else                next_st = ST_ADDR;
                        end else                next_st = ST_DATA;
                    end
                    default:                    next_st = ST_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // Datapath
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    addr_reg      <= 32'd0;
                    write_reg     <= 1'b0;
                    wdata_reg     <= 32'd0;
                    burst_cnt_reg <= 4'd0;
                    beat_first    <= 1'b0;
                    hrdata_reg    <= 32'd0;
                    ready_reg     <= 1'b0;
                    error_reg     <= 1'b0;
                    abort_reg     <= 1'b0;
                    rdata_valid   <= 1'b0;
                end else begin
                    ready_reg <= 1'b0;
                    error_reg <= 1'b0;

                    case (curr_st)
                        ST_IDLE: begin
                            if (dma_req) begin
                                addr_reg      <= dma_addr;
                                write_reg     <= dma_write;
                                wdata_reg     <= dma_wdata;
                                burst_cnt_reg <= dma_burst_len;
                                beat_first    <= 1'b1;
                                abort_reg     <= 1'b0;
                                rdata_valid   <= 1'b0;
                            end
                        end

                        ST_ADDR: begin
                            beat_first <= 1'b0;
                            rdata_valid <= 1'b0;
                            // Pre-update wdata for next beat (combinational from DMA)
                            if (write_reg)
                                wdata_reg <= dma_wdata;
                        end

                        ST_DATA: begin
                            if (hready_i) begin
                                if (~write_reg)
                                    hrdata_reg <= hrdata_i;
                                    rdata_valid <= 1'b1;
                                ready_reg <= 1'b1;
                                error_reg <= hresp_i;
                                if (hresp_i)
                                    abort_reg <= 1'b1;     // Abort on ERROR

                                // Prepare next beat
                                // 1KB boundary: auto-split by ending current burst
                                if (addr_1kb_cross)
                                    burst_cnt_reg <= 4'd0;  // Terminate at boundary
                                else
                                    burst_cnt_reg <= burst_cnt_reg - 4'd1;

                                addr_reg <= addr_reg + 32'd4;
                            end
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // AHB Outputs
            //------------------------------------------------------------------
            assign haddr_o   = addr_reg;
            assign hwrite_o  = write_reg;
            assign hwdata_o  = wdata_reg;
            assign hsize_o   = 3'd2;          // 32-bit
            assign hburst_o  = (burst_cnt_reg > 4'd1 && ~abort_reg) ? 3'd1 : 3'd0;
            assign hprot_o   = 4'h3;          // Data, unprivileged, non-buf, non-cache
            assign htrans_o  = (curr_st == ST_ADDR) ?
                               (beat_first ? 2'd2 : 2'd3) : 2'd0;

            //------------------------------------------------------------------
            // DMA Interface
            //------------------------------------------------------------------
            assign dma_grant  = (curr_st == ST_IDLE);
            assign dma_rdata  = hrdata_reg;
            assign dma_ready  = ready_reg;
            assign dma_error  = error_reg;

        end
    endgenerate

endmodule
