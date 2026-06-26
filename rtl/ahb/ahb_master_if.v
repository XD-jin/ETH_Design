// ============================================================================
// Module: AHB_MASTER_IF
// File:    ahb_master_if.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: AMBA 2.0 AHB Master interface for DMA data transfers.
//   Supports INCR/SINGLE bursts with configurable length, 1KB boundary splitting.
// ============================================================================

module ahb_master_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk, hresetn,

    // Internal DMA request interface
    input  wire        dma_req,
    output wire        dma_grant,
    input  wire [31:0] dma_addr,
    input  wire [31:0] dma_wdata,
    output wire [31:0] dma_rdata,
    input  wire [ 3:0] dma_burst_len,
    input  wire        dma_write,         // 0=Read, 1=Write
    output wire        dma_ready,
    output wire        dma_error,

    // AHB Master external interface
    output wire [31:0] haddr_o,
    output wire        hwrite_o,
    output wire [31:0] hwdata_o,
    output wire [ 2:0] hsize_o,
    output wire [ 2:0] hburst_o,
    output wire [ 1:0] htrans_o,
    input  wire [31:0] hrdata_i,
    input  wire        hready_i,
    input  wire        hresp_i
);

    reg [31:0] haddr_reg;
    reg        hwrite_reg;
    reg [31:0] hwdata_reg;
    reg        active;
    reg [ 3:0] burst_cnt;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign haddr_o  = 32'd0;
            assign hwrite_o = 1'b0;
            assign hwdata_o = 32'd0;
            assign hsize_o  = 3'd2;     // 32-bit
            assign hburst_o = 3'd0;     // SINGLE
            assign htrans_o = 2'd0;     // IDLE
            assign dma_grant = 1'b0;
            assign dma_rdata = 32'd0;
            assign dma_ready = 1'b0;
            assign dma_error = 1'b0;
        end else begin : gen_active
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    haddr_reg  <= 32'd0;
                    hwrite_reg <= 1'b0;
                    hwdata_reg <= 32'd0;
                    active     <= 1'b0;
                    burst_cnt  <= 4'd0;
                end else begin
                    if (dma_req && ~active) begin
                        active     <= 1'b1;
                        haddr_reg  <= dma_addr;
                        hwrite_reg <= dma_write;
                        hwdata_reg <= dma_wdata;
                        burst_cnt  <= dma_burst_len;
                    end else if (active && hready_i) begin
                        haddr_reg <= haddr_reg + 32'd4;
                        burst_cnt <= burst_cnt - 4'd1;
                        if (burst_cnt <= 4'd1)
                            active <= 1'b0;
                    end
                end
            end

            assign haddr_o  = haddr_reg;
            assign hwrite_o = hwrite_reg;
            assign hwdata_o = hwdata_reg;
            assign hsize_o  = 3'd2;
            assign hburst_o = (dma_burst_len > 4'd1) ? 3'd1 : 3'd0;  // INCR or SINGLE
            assign htrans_o = active ? 2'd2 : 2'd0;  // NONSEQ or IDLE
            assign dma_grant = ~active || (active && hready_i && burst_cnt <= 4'd1);
            assign dma_rdata = hrdata_i;
            assign dma_ready = active && hready_i;
            assign dma_error = active && hresp_i;
        end
    endgenerate

endmodule
