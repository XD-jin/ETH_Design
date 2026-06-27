// ============================================================================
// Module: AHB_SLAVE_IF
// File:    ahb_slave_if.v
// Author:  ETH_Design Team
// Version: v2.1
// Date:    2026-06-27
//
// Description:
//   AMBA 2.0 AHB Slave interface for CSR register access.
//   Two-phase pipelined: Phase1=Address, Phase2=Data.
//   Supports 32-bit accesses only. Byte/halfword = ERROR.
//   Zero wait state (HREADY always high). Single-beat only.
// ============================================================================

module ahb_slave_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk,
    input  wire        hresetn,

    input  wire        hsel,
    input  wire [12:0] haddr,
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    input  wire [ 1:0] htrans,
    input  wire [ 2:0] hsize,          // 000=8b, 001=16b, 010=32b
    input  wire [ 2:0] hburst,

    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,          // 0=OKAY, 1=ERROR

    output wire        reg_wr_en,
    output wire [12:0] reg_addr,
    output wire [31:0] reg_wr_data,
    input  wire [31:0] reg_rd_data
);

    //--------------------------------------------------------------------------
    // Phase 1 → Phase 2 registers
    //--------------------------------------------------------------------------
    reg        access_valid;
    reg [12:0] addr_reg;
    reg        write_reg;
    reg        size_ok;               // 1 = HSIZE is valid (32-bit only)
    reg        burst_ok;              // 1 = HBURST is SINGLE or INCR
    reg        hresp_reg;

    wire transfer_active;
    assign transfer_active = hsel && htrans[1];    // NONSEQ or SEQ

    // 32-bit access only
    wire hsize_ok;
    assign hsize_ok = (hsize == 3'd2);

    // Single-beat or INCR (burst not supported for CSR)
    wire hburst_ok;
    assign hburst_ok = (hburst == 3'd0) || (hburst == 3'd1);

    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign hrdata     = 32'd0;
            assign hready     = 1'b1;
            assign hresp      = 1'b0;
            assign reg_wr_en  = 1'b0;
            assign reg_addr   = 13'd0;
            assign reg_wr_data = 32'd0;
        end else begin : gen_active

            //------------------------------------------------------------------
            // Phase 1: Capture address + check HSIZE/HBURST validity
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    access_valid <= 1'b0;
                    addr_reg     <= 13'd0;
                    write_reg    <= 1'b0;
                    size_ok      <= 1'b0;
                    burst_ok     <= 1'b0;
                end else begin
                    if (transfer_active) begin
                        access_valid <= 1'b1;
                        addr_reg     <= haddr;
                        write_reg    <= hwrite;
                        size_ok      <= hsize_ok;
                        burst_ok     <= hburst_ok;
                    end else begin
                        access_valid <= 1'b0;
                    end
                end
            end

            //------------------------------------------------------------------
            // Phase 2: Data response with HSIZE/HBURST error check
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    hresp_reg  <= 1'b0;
                end else begin
                    if (access_valid) begin
                        // Two-cycle response (OKAY or ERROR)
                        // hresp: 0=OKAY, 1=ERROR for unsupported size/burst
                        hresp_reg <= ~(size_ok && burst_ok);
                    end else begin
                        hresp_reg <= 1'b0;
                    end
                end
            end

            //------------------------------------------------------------------
            // Outputs
            //------------------------------------------------------------------
            // hrdata: combinational from reg_rd_data (zero when in error)
            assign hrdata     = (access_valid && ~write_reg && size_ok && burst_ok) ? reg_rd_data : 32'd0;
            assign hready     = 1'b1;     // Zero wait state
            assign hresp      = hresp_reg;

            // Write: pass hwdata through in Phase 2 (data phase)
            assign reg_wr_en   = access_valid && write_reg && size_ok && burst_ok;
            assign reg_addr    = addr_reg;
            assign reg_wr_data = hwdata;

        end
    endgenerate

endmodule
