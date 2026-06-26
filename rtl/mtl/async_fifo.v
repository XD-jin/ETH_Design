// ============================================================================
// Module: ASYNC_FIFO
// File:    async_fifo.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-26
//
// Description:
//   Asynchronous FIFO with Gray-code pointer synchronization for safe
//   clock domain crossing. Dual-port SRAM based, depth must be power of 2.
//
//   Full/empty detection uses synchronized Gray-code pointers:
//     - Full:  wr_ptr_gray[ADDR_WIDTH:ADDR_WIDTH-1] inverted vs rd_ptr_sync
//     - Empty: wr_ptr_sync == rd_ptr_gray
//
// Reset Strategy:
//   Two independent asynchronous resets: wr_rst_n (write domain), rd_rst_n (read domain).
//
// Clock Strategy:
//   wr_clk (write domain) and rd_clk (read domain) are independent and asynchronous.
//
// Parameters:
//   P_DATA_WIDTH    Data width in bits
//   P_DEPTH         FIFO depth (must be power of 2)
//   P_SHELL_MODE    1 = Bypass
// ============================================================================

module async_fifo #(
    parameter P_DATA_WIDTH = 32,
    parameter P_DEPTH      = 16,
    parameter P_SHELL_MODE = 0
) (
    // Write domain
    input  wire                   wr_clk,
    input  wire                   wr_rst_n,
    input  wire                   wr_en,
    input  wire [P_DATA_WIDTH-1:0] wr_data,
    output wire                   full,
    output wire                   almost_full,

    // Read domain
    input  wire                   rd_clk,
    input  wire                   rd_rst_n,
    input  wire                   rd_en,
    output wire [P_DATA_WIDTH-1:0] rd_data,
    output wire                   empty,
    output wire                   almost_empty
);

    //--------------------------------------------------------------------------
    // Verilog-2001 compatible $clog2 function
    //--------------------------------------------------------------------------
    function integer clog2;
        input integer depth;
        integer i;
        begin
            i = depth - 1;
            for (clog2 = 0; i > 0; clog2 = clog2 + 1) i = i >> 1;
        end
    endfunction

    localparam P_ADDR_WIDTH = clog2(P_DEPTH);

    //--------------------------------------------------------------------------
    // Internal Signals
    //--------------------------------------------------------------------------
    // Dual-port SRAM
    reg [P_DATA_WIDTH-1:0] mem [0:P_DEPTH-1];

    // Write pointers (binary + gray)
    reg  [P_ADDR_WIDTH:0] wr_ptr_bin;
    wire [P_ADDR_WIDTH:0] wr_ptr_gray;
    reg  [P_ADDR_WIDTH:0] wr_ptr_gray_reg;

    // Read pointers (binary + gray)
    reg  [P_ADDR_WIDTH:0] rd_ptr_bin;
    wire [P_ADDR_WIDTH:0] rd_ptr_gray;
    reg  [P_ADDR_WIDTH:0] rd_ptr_gray_reg;

    // Synchronized pointers
    reg  [P_ADDR_WIDTH:0] wr_ptr_sync_ff1, wr_ptr_sync_ff2;  // in rd_clk domain
    reg  [P_ADDR_WIDTH:0] rd_ptr_sync_ff1, rd_ptr_sync_ff2;  // in wr_clk domain

    // Binary-to-Gray conversion
    assign wr_ptr_gray = wr_ptr_bin ^ (wr_ptr_bin >> 1);
    assign rd_ptr_gray = rd_ptr_bin ^ (rd_ptr_bin >> 1);

    // Full/Empty logic
    wire full_int, empty_int;

    generate
        if (P_SHELL_MODE) begin : gen_shell

            assign full         = 1'b0;
            assign almost_full  = 1'b0;
            assign empty        = 1'b1;
            assign almost_empty = 1'b1;
            assign rd_data      = {P_DATA_WIDTH{1'b0}};

        end else begin : gen_active

            //------------------------------------------------------------------
            // Write Domain
            //------------------------------------------------------------------
            always @(posedge wr_clk or negedge wr_rst_n) begin
                if (wr_rst_n == 1'b0) begin
                    wr_ptr_bin       <= {(P_ADDR_WIDTH+1){1'b0}};
                    wr_ptr_gray_reg  <= {(P_ADDR_WIDTH+1){1'b0}};
                    rd_ptr_sync_ff1  <= {(P_ADDR_WIDTH+1){1'b0}};
                    rd_ptr_sync_ff2  <= {(P_ADDR_WIDTH+1){1'b0}};
                end else begin
                    // Synchronize read pointer into write domain (2-FF)
                    rd_ptr_sync_ff1 <= rd_ptr_gray_reg;
                    rd_ptr_sync_ff2 <= rd_ptr_sync_ff1;

                    if (wr_en && ~full_int) begin
                        mem[wr_ptr_bin[P_ADDR_WIDTH-1:0]] <= wr_data;
                        wr_ptr_bin <= wr_ptr_bin + 1;
                    end
                    wr_ptr_gray_reg <= wr_ptr_gray;
                end
            end

            // Full = write Gray pointer top 2 bits are complement of synced read pointer
            assign full_int = (wr_ptr_gray[P_ADDR_WIDTH:P_ADDR_WIDTH-1] ==
                              ~rd_ptr_sync_ff2[P_ADDR_WIDTH:P_ADDR_WIDTH-1]) &&
                             (wr_ptr_gray[P_ADDR_WIDTH-2:0] ==
                              rd_ptr_sync_ff2[P_ADDR_WIDTH-2:0]);
            assign full        = full_int;
            assign almost_full = full_int || (wr_ptr_bin + 2 >= rd_ptr_sync_ff2 + P_DEPTH);

            //------------------------------------------------------------------
            // Read Domain
            //------------------------------------------------------------------
            always @(posedge rd_clk or negedge rd_rst_n) begin
                if (rd_rst_n == 1'b0) begin
                    rd_ptr_bin       <= {(P_ADDR_WIDTH+1){1'b0}};
                    rd_ptr_gray_reg  <= {(P_ADDR_WIDTH+1){1'b0}};
                    wr_ptr_sync_ff1  <= {(P_ADDR_WIDTH+1){1'b0}};
                    wr_ptr_sync_ff2  <= {(P_ADDR_WIDTH+1){1'b0}};
                end else begin
                    // Synchronize write pointer into read domain (2-FF)
                    wr_ptr_sync_ff1 <= wr_ptr_gray_reg;
                    wr_ptr_sync_ff2 <= wr_ptr_sync_ff1;

                    if (rd_en && ~empty_int)
                        rd_ptr_bin <= rd_ptr_bin + 1;
                    rd_ptr_gray_reg <= rd_ptr_gray;
                end
            end

            // Empty = read Gray pointer == synced write pointer
            assign empty_int    = (rd_ptr_gray == wr_ptr_sync_ff2);
            assign empty        = empty_int;
            assign almost_empty = empty_int || (rd_ptr_bin + 2 >= wr_ptr_sync_ff2);

            // Read data (registered output)
            assign rd_data = mem[rd_ptr_bin[P_ADDR_WIDTH-1:0]];

        end
    endgenerate

endmodule
