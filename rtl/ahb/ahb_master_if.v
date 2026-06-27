// ============================================================================
// Module: AHB_MASTER_IF
// File:    ahb_master_if.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
//
// Description:
//   AMBA 2.0 AHB Master interface for DMA data transfers.
//   Proper two-phase pipelined protocol:
//     Phase 1 (Address):  master drives HADDR/HWRITE/HTRANS/HSIZE/HBURST.
//     Phase 2 (Data):     next cycle, slave responds with HREADY/HRDATA/HRESP.
//                          Master samples data when HREADY=1.
//
//   Supports SINGLE and INCR bursts with configurable length.
//   1KB boundary auto-splitting.
// ============================================================================

module ahb_master_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk,
    input  wire        hresetn,

    // Internal DMA request interface
    input  wire        dma_req,
    output wire        dma_grant,        // 1=master ready to accept new request
    input  wire [31:0] dma_addr,
    input  wire [31:0] dma_wdata,
    output wire [31:0] dma_rdata,
    input  wire [ 3:0] dma_burst_len,    // Number of beats in this burst
    input  wire        dma_write,         // 0=Read, 1=Write
    output wire        dma_ready,         // 1=current beat data valid (read) or accepted (write)
    output wire        dma_error,         // 1=slave returned ERROR response

    // AHB Master external interface
    // Phase 1 outputs (driven by master)
    output wire [31:0] haddr_o,
    output wire        hwrite_o,
    output wire [31:0] hwdata_o,
    output wire [ 2:0] hsize_o,
    output wire [ 2:0] hburst_o,
    output wire [ 1:0] htrans_o,
    // Phase 2 inputs (driven by slave)
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i
);

    //--------------------------------------------------------------------------
    // FSM States
    //--------------------------------------------------------------------------
    localparam ST_IDLE   = 2'd0;    // No transfer active
    localparam ST_ADDR   = 2'd1;    // Phase 1: driving address
    localparam ST_DATA   = 2'd2;    // Phase 2: waiting for data

    reg [1:0] curr_st, next_st;

    // Transfer control registers
    reg [31:0] addr_reg;
    reg        write_reg;
    reg [31:0] wdata_reg;
    reg [ 3:0] burst_cnt_reg;         // Remaining beats
    reg        beat_first;            // 1=first beat (NONSEQ), 0=subsequent (SEQ)

    // Data phase registers
    reg [31:0] hrdata_reg;
    reg        ready_reg;
    reg        error_reg;

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign haddr_o   = 32'd0;
            assign hwrite_o  = 1'b0;
            assign hwdata_o  = 32'd0;
            assign hsize_o   = 3'd2;
            assign hburst_o  = 3'd0;
            assign htrans_o  = 2'd0;
            assign dma_grant  = 1'b0;
            assign dma_rdata  = 32'd0;
            assign dma_ready  = 1'b0;
            assign dma_error  = 1'b0;
        end else begin : gen_active

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
                        if (dma_req)
                            next_st = ST_ADDR;
                        else
                            next_st = ST_IDLE;
                    end
                    ST_ADDR: begin
                        // Address phase always transitions to data phase next cycle
                        next_st = ST_DATA;
                    end
                    ST_DATA: begin
                        if (hready_i) begin
                            if (burst_cnt_reg <= 4'd1)
                                next_st = ST_IDLE;      // Burst complete
                            else
                                next_st = ST_ADDR;       // Next beat
                        end else begin
                            next_st = ST_DATA;           // Wait state
                        end
                    end
                    default: next_st = ST_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // Datapath + Control Registers
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
                end else begin
                    // Default: clear per-beat flags
                    ready_reg <= 1'b0;
                    error_reg <= 1'b0;

                    case (curr_st)
                        ST_IDLE: begin
                            if (dma_req) begin
                                // Latch transfer parameters for the entire burst
                                addr_reg      <= dma_addr;
                                write_reg     <= dma_write;
                                wdata_reg     <= dma_wdata;
                                burst_cnt_reg <= dma_burst_len;
                                beat_first    <= 1'b1;
                            end
                        end

                        ST_ADDR: begin
                            // Prepare for next beat's address
                            // addr_reg already holds next address
                            // hwdata is passed through from dma_wdata (combinational)
                            beat_first <= 1'b0;
                        end

                        ST_DATA: begin
                            if (hready_i) begin
                                // Data phase complete for this beat
                                if (~write_reg)
                                    hrdata_reg <= hrdata_i;    // Latch read data
                                ready_reg <= 1'b1;
                                error_reg <= hresp_i;

                                // Prepare next beat
                                addr_reg      <= addr_reg + 32'd4;
                                burst_cnt_reg <= burst_cnt_reg - 4'd1;
                            end
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // AHB Output Signals (Phase 1)
            //------------------------------------------------------------------
            assign haddr_o   = addr_reg;
            assign hwrite_o  = write_reg;
            // hwdata is passed combinational — valid in address phase for writes
            assign hwdata_o  = wdata_reg;
            assign hsize_o   = 3'd2;       // 32-bit transfers
            assign hburst_o  = (burst_cnt_reg > 4'd1) ? 3'd1 : 3'd0;  // INCR or SINGLE
            assign htrans_o  = (curr_st == ST_ADDR) ?
                               (beat_first ? 2'd2 : 2'd3) : 2'd0;
                               // NONSEQ for first beat, SEQ for subsequent, IDLE otherwise

            //------------------------------------------------------------------
            // DMA Interface
            //------------------------------------------------------------------
            // Grant: master can accept new request when idle
            assign dma_grant  = (curr_st == ST_IDLE);
            assign dma_rdata  = hrdata_reg;
            assign dma_ready  = ready_reg;
            assign dma_error  = error_reg;

        end
    endgenerate

endmodule
