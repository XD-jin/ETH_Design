// ============================================================================
// Module: AHB_SRAM
// File:    ahb_sram.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-27
//
// Description:
//   AMBA 2.0 AHB Slave SRAM — 32KB (8192 x 32-bit).
//   Two-phase pipelined: Phase1 captures address, Phase2 returns data.
//   Supports 32-bit read/write. Byte/halfword → ERROR.
//   Data initialized from mem.dat via \$readmemh at simulation start.
//
// Parameters:
//   P_MEM_FILE    Hex data file for initialization
//   P_DEPTH       Memory depth in 32-bit words (default 8192 = 32KB)
// ============================================================================

module ahb_sram #(
    parameter P_MEM_FILE = "mem.dat",
    parameter P_DEPTH    = 8192     // 32KB = 8192 * 32-bit
) (
    input  wire        hclk,
    input  wire        hresetn,

    // AHB Slave
    input  wire        hsel,
    input  wire [31:0] haddr,
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    input  wire [ 1:0] htrans,
    input  wire [ 2:0] hsize,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp
);

    //--------------------------------------------------------------------------
    // Memory array
    //--------------------------------------------------------------------------
    reg [31:0] mem [0:P_DEPTH-1];

    //--------------------------------------------------------------------------
    // Initialize from hex file
    //--------------------------------------------------------------------------
    initial begin
        $readmemh(P_MEM_FILE, mem);
        $display("[SRAM] Loaded %s, %0d words", P_MEM_FILE, P_DEPTH);
    end

    //--------------------------------------------------------------------------
    // Phase 1 → Phase 2 registers
    //--------------------------------------------------------------------------
    reg        access_valid;
    reg [14:0] addr_reg;     // Word address (byte addr >> 2)
    reg        write_reg;
    reg        size_ok;

    wire transfer_active;
    assign transfer_active = hsel && htrans[1];

    // 32-bit access only
    wire hsize_ok;
    assign hsize_ok = (hsize == 3'd2);

    //--------------------------------------------------------------------------
    // Phase 1: Capture address
    //--------------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (hresetn == 1'b0) begin
            access_valid <= 1'b0;
            addr_reg     <= 15'd0;
            write_reg    <= 1'b0;
            size_ok      <= 1'b0;
        end else begin
            if (transfer_active) begin
                access_valid <= 1'b1;
                addr_reg     <= haddr[16:2];  // 32-bit word address
                write_reg    <= hwrite;
                size_ok      <= hsize_ok;
            end else begin
                access_valid <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Phase 2: Data response — combinational for 2-cycle access
    //--------------------------------------------------------------------------
    wire mem_read_en;
    assign mem_read_en = access_valid && ~write_reg && size_ok;

    assign hrdata = mem_read_en ? mem[addr_reg] : 32'd0;
    assign hready = 1'b1;
    assign hresp  = access_valid ? ~(size_ok) : 1'b0;

    // Write: sequential (registered address, data from hwdata)
    always @(posedge hclk) begin
        if (access_valid && write_reg && size_ok)
            mem[addr_reg] <= hwdata;
    end

endmodule
