// ============================================================================
// Module: AHB_SLAVE_IF
// File:    ahb_slave_if.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
//
// Description:
//   AMBA 2.0 AHB Slave interface for CSR register access.
//   Proper two-phase pipelined implementation:
//     Phase 1 (Address):  Master drives HADDR/HWRITE/HSEL/HTRANS.
//                          Slave registers address on rising edge when HREADY=1
//                          and a valid transfer is requested.
//     Phase 2 (Data):     Next cycle. Slave drives HRDATA (read) or samples
//                          HWDATA (write). HREADY=0 inserts wait states.
//
//   Timing: 2-cycle minimum per access (addr phase + data phase).
//           Zero internal wait states → HREADY always high after reset.
//
// Reset Strategy: Asynchronous reset, active low (hresetn).
// Clock: hclk (AHB bus clock).
// ============================================================================

module ahb_slave_if #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk,
    input  wire        hresetn,

    // AHB Slave bus — Phase 1 (Address/Control) inputs
    input  wire        hsel,
    input  wire [12:0] haddr,       // 13-bit address
    input  wire        hwrite,
    input  wire [31:0] hwdata,
    input  wire [ 1:0] htrans,      // 00=IDLE, 01=BUSY, 10=NONSEQ, 11=SEQ
    input  wire [ 2:0] hsize,
    input  wire [ 2:0] hburst,

    // AHB Slave bus — Phase 2 (Data) outputs
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,       // 0=OKAY, 1=ERROR

    // Register access ports (to reg_file)
    output wire        reg_wr_en,     // pulsed high for 1 cycle in data phase
    output wire [12:0] reg_addr,      // registered address (stable in data phase)
    output wire [31:0] reg_wr_data,   // write data (passed through from hwdata)
    input  wire [31:0] reg_rd_data    // read data from register file
);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    // Phase 1 → Phase 2 registered signals
    reg        access_valid;          // 1 = a valid access was captured in Phase 1
    reg [12:0] addr_reg;              // Registered address (Phase 1 capture)
    reg        write_reg;             // Registered write flag
    reg [31:0] wdata_reg;             // Registered write data

    // Read data is combinational (see assign below)
    reg        hready_reg;
    reg        hresp_reg;

    //--------------------------------------------------------------------------
    // Transfer detection
    //--------------------------------------------------------------------------
    wire transfer_active;
    assign transfer_active = hsel && htrans[1];    // NONSEQ or SEQ

    //--------------------------------------------------------------------------
    // Shell Mode
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
            // Phase 1: Capture address on rising edge when transfer starts
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    access_valid <= 1'b0;
                    addr_reg     <= 13'd0;
                    write_reg    <= 1'b0;
                    wdata_reg    <= 32'd0;
                end else begin
                    if (transfer_active) begin
                        // Capture address phase info
                        access_valid <= 1'b1;
                        addr_reg     <= haddr;
                        write_reg    <= hwrite;
                        wdata_reg    <= hwdata;       // hwdata is valid in address phase for writes
                    end else begin
                        // Clear valid flag when no transfer
                        access_valid <= 1'b0;
                    end
                end
            end

            //------------------------------------------------------------------
            // Phase 2: Respond with data in the clock cycle after address capture
            //------------------------------------------------------------------
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    hready_reg <= 1'b1;
                    hresp_reg  <= 1'b0;
                end else begin
                    // Phase 2 Data Response:
                    // After address is captured (access_valid=1), respond in the
                    // next cycle. For reads: drive reg_rd_data. For writes: ack.
                    // Insert 1 wait state: hready=0 during data preparation,
                    // hready=1 when data is ready.
                    if (access_valid) begin
                        // Data phase — respond to the captured access
                        // hrdata is combinational from reg_rd_data (see assign)
                        hready_reg <= 1'b1;              // Data valid this cycle
                        hresp_reg  <= 1'b0;              // OKAY
                    end else begin
                        hready_reg <= 1'b1;              // Ready for next access
                        hresp_reg  <= 1'b0;
                    end
                end
            end

            //------------------------------------------------------------------
            // Outputs
            //------------------------------------------------------------------
            // Read data: combinational from reg_rd_data during data phase
            // This avoids the 1-cycle pipeline delay of registered hrdata
            assign hrdata     = (access_valid && ~write_reg) ? reg_rd_data : 32'd0;
            assign hready     = hready_reg;
            assign hresp      = hresp_reg;

            // Write strobe: pulsed in the data phase when access_valid=1 and it's a write
            assign reg_wr_en  = access_valid && write_reg;
            assign reg_addr   = addr_reg;              // Stable registered address
            assign reg_wr_data = wdata_reg;             // Registered write data

        end
    endgenerate

endmodule
