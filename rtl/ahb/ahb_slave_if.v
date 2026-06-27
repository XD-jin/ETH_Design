// ============================================================================
// Module: AHB_SLAVE_IF
// File:    ahb_slave_if.v
// Author:  ETH_Design Team
// Version: v1.0
// Description: AMBA 2.0 AHB Slave interface for CSR register access.
//   Decodes 4KB address space, supports 32-bit read/write.
// ============================================================================

module ahb_slave_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk, hresetn,
    input  wire        hsel,
    input  wire [12:0] haddr,       // 13-bit = 8KB address space
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    input  wire [ 1:0] htrans,
    input  wire [ 2:0] hsize,
    input  wire [ 2:0] hburst,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,

    // Register read/write ports (to internal register file)
    output wire        reg_wr_en,
    output wire [12:0] reg_addr,
    output wire [31:0] reg_wr_data,
    input  wire [31:0] reg_rd_data
);

    reg [31:0] hrdata_reg;
    reg        hready_reg;

    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign hrdata     = 32'd0;
            assign hready     = 1'b1;
            assign hresp      = 1'b0;
            assign reg_wr_en  = 1'b0;
            assign reg_addr   = 13'd0;
            assign reg_wr_data = 32'd0;
        end else begin : gen_active
            // Registered output for read data
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    hrdata_reg <= 32'd0;
                    hready_reg <= 1'b1;
                end else begin
                    if (hsel && htrans[1]) begin
                        if (hwrite)
                            hrdata_reg <= 32'd0;
                        else
                            hrdata_reg <= reg_rd_data;
                        hready_reg <= 1'b1;
                    end else begin
                        hready_reg <= 1'b1;
                    end
                end
            end

            assign hrdata     = hrdata_reg;
            assign hready     = hready_reg;
            assign hresp      = 1'b0;         // OKAY only
            assign reg_wr_en  = hsel && hwrite && htrans[1];
            assign reg_addr   = haddr;
            assign reg_wr_data = hwdata;
        end
    endgenerate

endmodule
