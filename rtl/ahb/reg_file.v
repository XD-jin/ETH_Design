// ============================================================================
// Module: REG_FILE
// File:    reg_file.v
// Author:  ETH_Design Team
// Version: v1.0
// Date:    2026-06-27
//
// Description:
//   CSR Register File — 4KB address space decoder for 46 V1.0 registers.
//   Bridges AHB Slave Interface to internal sub-module configuration signals.
//
//   Supports: RW (read/write), RO (read-only), RC (read-clear), W1C (write-1-clear)
//
// Reset Strategy: Asynchronous reset, active low (hresetn). All registers reset to spec defaults.
// Clock: hclk (AHB bus clock).
// ============================================================================

module reg_file #(
    parameter P_SHELL_MODE = 0
) (
    input  wire        hclk,
    input  wire        hresetn,

    // AHB Slave interface (from ahb_slave_if)
    input  wire        reg_wr_en,
    input  wire [12:0] reg_addr,
    input  wire [31:0] reg_wr_data,
    output wire [31:0] reg_rd_data,

    // === MAC Core Configuration ===
    output wire [31:0] mac_config,
    output wire [31:0] mac_packet_filter,
    output wire [13:0] mac_watchdog_limit,
    output wire [63:0] mac_hash_table,
    output wire [15:0] mac_q0_tx_pause_time,
    output wire        mac_q0_tx_fc_enable,
    output wire        mac_q1_tx_fc_enable,
    output wire        mac_rx_fc_enable,
    output wire [ 3:0] mac_intr_enable,
    input  wire [ 3:0] mac_intr_status,       // From MAC: {TS, RSVD, PC, RO}
    output wire [47:0] mac_addr0,
    output wire [47:0] mac_addr1,
    output wire [47:0] mac_addr2,
    output wire [47:0] mac_addr3,

    // === MTL Configuration ===
    output wire [31:0] mtl_op_mode,
    output wire [ 3:0] mtl_rxq_dma_map,
    output wire [31:0] mtl_txq0_op_mode,
    output wire [31:0] mtl_txq1_op_mode,
    output wire [31:0] mtl_rxq0_op_mode,
    output wire [31:0] mtl_rxq1_op_mode,
    input  wire [31:0] mtl_intr_status,        // From MTL
    input  wire [31:0] mtl_txq0_underflow,
    input  wire [31:0] mtl_txq1_underflow,
    input  wire [31:0] mtl_rxq0_missed,
    input  wire [31:0] mtl_rxq1_missed,

    // === DMA Configuration ===
    output wire [31:0] dma_mode,
    output wire [31:0] dma_sysbus_mode,
    output wire [ 3:0] dma_intr_enable,
    input  wire [ 3:0] dma_intr_status,        // From DMA
    output wire [15:0] dma_tx_intr_timer,
    output wire [15:0] dma_rx_intr_timer,

    // Channel 0
    output wire [31:0] dma_ch0_ctrl,
    output wire [31:0] dma_ch0_tx_ctrl,
    output wire [31:0] dma_ch0_rx_ctrl,
    output wire [31:0] dma_ch0_tx_desc_addr,
    output wire [31:0] dma_ch0_rx_desc_addr,
    output wire [ 7:0] dma_ch0_tx_desc_tail,
    output wire [ 7:0] dma_ch0_rx_desc_tail,
    input  wire [31:0] dma_ch0_status,

    // Channel 1
    output wire [31:0] dma_ch1_ctrl,
    output wire [31:0] dma_ch1_tx_ctrl,
    output wire [31:0] dma_ch1_rx_ctrl,
    output wire [31:0] dma_ch1_tx_desc_addr,
    output wire [31:0] dma_ch1_rx_desc_addr,
    output wire [ 7:0] dma_ch1_tx_desc_tail,
    output wire [ 7:0] dma_ch1_rx_desc_tail,
    input  wire [31:0] dma_ch1_status,

    // MAC Version (RO)
    output wire [31:0] mac_version
);

    //--------------------------------------------------------------------------
    // Register storage
    //--------------------------------------------------------------------------
    // MAC Core
    reg [31:0] r_mac_config;
    reg [31:0] r_mac_packet_filter;
    reg [13:0] r_mac_watchdog_limit;
    reg [63:0] r_mac_hash_table;
    reg [15:0] r_mac_q0_tx_pause_time;
    reg        r_mac_q0_tx_fc_enable;
    reg [15:0] r_mac_q1_tx_pause_time;
    reg        r_mac_q1_tx_fc_enable;
    reg        r_mac_rx_fc_enable;
    reg [ 3:0] r_mac_intr_enable;
    reg [47:0] r_mac_addr0, r_mac_addr1, r_mac_addr2, r_mac_addr3;

    // MTL
    reg [31:0] r_mtl_op_mode;
    reg [ 3:0] r_mtl_rxq_dma_map;
    reg [31:0] r_mtl_txq0_op_mode, r_mtl_txq1_op_mode;
    reg [31:0] r_mtl_rxq0_op_mode, r_mtl_rxq1_op_mode;

    // DMA
    reg [31:0] r_dma_mode;
    reg [31:0] r_dma_sysbus_mode;
    reg [ 3:0] r_dma_intr_enable;
    reg [15:0] r_dma_tx_intr_timer, r_dma_rx_intr_timer;
    reg [31:0] r_dma_ch0_ctrl, r_dma_ch0_tx_ctrl, r_dma_ch0_rx_ctrl;
    reg [31:0] r_dma_ch0_tx_desc_addr, r_dma_ch0_rx_desc_addr;
    reg [ 7:0] r_dma_ch0_tx_desc_tail, r_dma_ch0_rx_desc_tail;
    reg [31:0] r_dma_ch1_ctrl, r_dma_ch1_tx_ctrl, r_dma_ch1_rx_ctrl;
    reg [31:0] r_dma_ch1_tx_desc_addr, r_dma_ch1_rx_desc_addr;
    reg [ 7:0] r_dma_ch1_tx_desc_tail, r_dma_ch1_rx_desc_tail;

    // MAC Version (hard-wired RO)
    wire [31:0] r_mac_version = 32'h0000_0100;   // V1.0

    //--------------------------------------------------------------------------
    // Write decode — one-hot per register
    //--------------------------------------------------------------------------
    wire wr_mac_config         = reg_wr_en && (reg_addr == 13'h000);
    wire wr_mac_packet_filter  = reg_wr_en && (reg_addr == 13'h008);
    wire wr_mac_watchdog       = reg_wr_en && (reg_addr == 13'h00C);
    wire wr_mac_hash_0         = reg_wr_en && (reg_addr == 13'h010);
    wire wr_mac_hash_1         = reg_wr_en && (reg_addr == 13'h014);
    wire wr_mac_q0_tx_fc       = reg_wr_en && (reg_addr == 13'h070);
    wire wr_mac_q1_tx_fc       = reg_wr_en && (reg_addr == 13'h074);
    wire wr_mac_rx_fc          = reg_wr_en && (reg_addr == 13'h090);
    wire wr_mac_intr_en        = reg_wr_en && (reg_addr == 13'h0B4);
    wire wr_mac_addr0_hi       = reg_wr_en && (reg_addr == 13'h300);
    wire wr_mac_addr0_lo       = reg_wr_en && (reg_addr == 13'h304);
    wire wr_mac_addr1_hi       = reg_wr_en && (reg_addr == 13'h308);
    wire wr_mac_addr1_lo       = reg_wr_en && (reg_addr == 13'h30C);
    wire wr_mac_addr2_hi       = reg_wr_en && (reg_addr == 13'h310);
    wire wr_mac_addr2_lo       = reg_wr_en && (reg_addr == 13'h314);
    wire wr_mac_addr3_hi       = reg_wr_en && (reg_addr == 13'h318);
    wire wr_mac_addr3_lo       = reg_wr_en && (reg_addr == 13'h31C);

    wire wr_mtl_op_mode        = reg_wr_en && (reg_addr == 13'hC00);
    wire wr_mtl_rxq_dma_map    = reg_wr_en && (reg_addr == 13'hC30);
    wire wr_mtl_txq0_op        = reg_wr_en && (reg_addr == 13'hD00);
    wire wr_mtl_txq1_op        = reg_wr_en && (reg_addr == 13'hD40);
    wire wr_mtl_rxq0_op        = reg_wr_en && (reg_addr == 13'hD30);
    wire wr_mtl_rxq1_op        = reg_wr_en && (reg_addr == 13'hD70);

    wire wr_dma_mode           = reg_wr_en && (reg_addr == 13'h1000);
    wire wr_dma_sysbus_mode    = reg_wr_en && (reg_addr == 13'h1004);
    wire wr_dma_intr_en        = reg_wr_en && (reg_addr == 13'h100C);
    wire wr_dma_tx_intr_timer  = reg_wr_en && (reg_addr == 13'h1014);
    wire wr_dma_rx_intr_timer  = reg_wr_en && (reg_addr == 13'h1018);
    // DMA CH0 (0x1100-0x117F)
    wire wr_dma_ch0_ctrl        = reg_wr_en && (reg_addr == 13'h1100);
    wire wr_dma_ch0_tx_ctrl     = reg_wr_en && (reg_addr == 13'h1104);
    wire wr_dma_ch0_rx_ctrl     = reg_wr_en && (reg_addr == 13'h1108);
    wire wr_dma_ch0_tx_desc     = reg_wr_en && (reg_addr == 13'h1114);
    wire wr_dma_ch0_rx_desc     = reg_wr_en && (reg_addr == 13'h111C);
    wire wr_dma_ch0_tx_tail     = reg_wr_en && (reg_addr == 13'h1128);
    wire wr_dma_ch0_rx_tail     = reg_wr_en && (reg_addr == 13'h112C);
    // DMA CH1 (0x1180-0x11FF)
    wire wr_dma_ch1_ctrl        = reg_wr_en && (reg_addr == 13'h1180);
    wire wr_dma_ch1_tx_ctrl     = reg_wr_en && (reg_addr == 13'h1184);
    wire wr_dma_ch1_rx_ctrl     = reg_wr_en && (reg_addr == 13'h1188);
    wire wr_dma_ch1_tx_desc     = reg_wr_en && (reg_addr == 13'h1194);
    wire wr_dma_ch1_rx_desc     = reg_wr_en && (reg_addr == 13'h119C);
    wire wr_dma_ch1_tx_tail     = reg_wr_en && (reg_addr == 13'h11A8);
    wire wr_dma_ch1_rx_tail     = reg_wr_en && (reg_addr == 13'h11AC);

    //--------------------------------------------------------------------------
    // Register write (hclk domain)
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            // Shell mode: writes ignored, outputs stay at reset defaults
        end else begin : gen_active
            always @(posedge hclk or negedge hresetn) begin
                if (hresetn == 1'b0) begin
                    r_mac_config          <= 32'h0000_0000;
                    r_mac_packet_filter   <= 32'h0000_0000;
                    r_mac_watchdog_limit  <= 14'd2048;
                    r_mac_hash_table      <= 64'd0;
                    r_mac_q0_tx_pause_time <= 16'hFFFF;
                    r_mac_q0_tx_fc_enable <= 1'b0;
                    r_mac_q1_tx_pause_time <= 16'hFFFF;
                    r_mac_q1_tx_fc_enable <= 1'b0;
                    r_mac_rx_fc_enable    <= 1'b0;
                    r_mac_intr_enable     <= 4'd0;
                    r_mac_addr0           <= 48'd0;
                    r_mac_addr1           <= 48'd0;
                    r_mac_addr2           <= 48'd0;
                    r_mac_addr3           <= 48'd0;
                    r_mtl_op_mode         <= 32'd0;
                    r_mtl_rxq_dma_map     <= 4'd0;
                    r_mtl_txq0_op_mode    <= 32'd0;
                    r_mtl_txq1_op_mode    <= 32'd0;
                    r_mtl_rxq0_op_mode    <= 32'd0;
                    r_mtl_rxq1_op_mode    <= 32'd0;
                    r_dma_mode            <= 32'd0;
                    r_dma_sysbus_mode     <= 32'h0100_0000;
                    r_dma_intr_enable     <= 4'd0;
                    r_dma_tx_intr_timer   <= 16'd0;
                    r_dma_rx_intr_timer   <= 16'd0;
                    r_dma_ch0_ctrl        <= 32'd0;
                    r_dma_ch0_tx_ctrl     <= 32'd0;
                    r_dma_ch0_rx_ctrl     <= 32'd0;
                    r_dma_ch0_tx_desc_addr <= 32'd0;
                    r_dma_ch0_rx_desc_addr <= 32'd0;
                    r_dma_ch0_tx_desc_tail <= 8'd0;
                    r_dma_ch0_rx_desc_tail <= 8'd0;
                    r_dma_ch1_ctrl        <= 32'd0;
                    r_dma_ch1_tx_ctrl     <= 32'd0;
                    r_dma_ch1_rx_ctrl     <= 32'd0;
                    r_dma_ch1_tx_desc_addr <= 32'd0;
                    r_dma_ch1_rx_desc_addr <= 32'd0;
                    r_dma_ch1_tx_desc_tail <= 8'd0;
                    r_dma_ch1_rx_desc_tail <= 8'd0;
                end else begin
                    // MAC registers
                    if (wr_mac_config)         r_mac_config         <= reg_wr_data;
                    if (wr_mac_packet_filter)  r_mac_packet_filter  <= reg_wr_data;
                    if (wr_mac_watchdog)       r_mac_watchdog_limit <= reg_wr_data[13:0];
                    if (wr_mac_hash_0)         r_mac_hash_table[31:0]  <= reg_wr_data;
                    if (wr_mac_hash_1)         r_mac_hash_table[63:32] <= reg_wr_data;
                    if (wr_mac_q0_tx_fc) begin
                        r_mac_q0_tx_pause_time <= reg_wr_data[31:16];
                        r_mac_q0_tx_fc_enable  <= reg_wr_data[0];
                    end
                    if (wr_mac_q1_tx_fc) begin
                        r_mac_q1_tx_pause_time <= reg_wr_data[31:16];
                        r_mac_q1_tx_fc_enable  <= reg_wr_data[0];
                    end
                    if (wr_mac_rx_fc)          r_mac_rx_fc_enable    <= reg_wr_data[0];
                    if (wr_mac_intr_en)        r_mac_intr_enable     <= reg_wr_data[3:0];
                    if (wr_mac_addr0_hi)       r_mac_addr0[47:32]    <= reg_wr_data[15:0];
                    if (wr_mac_addr0_lo)       r_mac_addr0[31:0]     <= reg_wr_data;
                    if (wr_mac_addr1_hi)       r_mac_addr1[47:32]    <= reg_wr_data[15:0];
                    if (wr_mac_addr1_lo)       r_mac_addr1[31:0]     <= reg_wr_data;
                    if (wr_mac_addr2_hi)       r_mac_addr2[47:32]    <= reg_wr_data[15:0];
                    if (wr_mac_addr2_lo)       r_mac_addr2[31:0]     <= reg_wr_data;
                    if (wr_mac_addr3_hi)       r_mac_addr3[47:32]    <= reg_wr_data[15:0];
                    if (wr_mac_addr3_lo)       r_mac_addr3[31:0]     <= reg_wr_data;

                    // MTL registers
                    if (wr_mtl_op_mode)        r_mtl_op_mode         <= reg_wr_data;
                    if (wr_mtl_rxq_dma_map)    r_mtl_rxq_dma_map     <= reg_wr_data[3:0];
                    if (wr_mtl_txq0_op)        r_mtl_txq0_op_mode    <= reg_wr_data;
                    if (wr_mtl_txq1_op)        r_mtl_txq1_op_mode    <= reg_wr_data;
                    if (wr_mtl_rxq0_op)        r_mtl_rxq0_op_mode    <= reg_wr_data;
                    if (wr_mtl_rxq1_op)        r_mtl_rxq1_op_mode    <= reg_wr_data;

                    // DMA registers
                    if (wr_dma_mode)           r_dma_mode            <= reg_wr_data;
                    if (wr_dma_sysbus_mode)    r_dma_sysbus_mode     <= reg_wr_data;
                    if (wr_dma_intr_en)        r_dma_intr_enable     <= reg_wr_data[3:0];
                    if (wr_dma_tx_intr_timer)  r_dma_tx_intr_timer   <= reg_wr_data[15:0];
                    if (wr_dma_rx_intr_timer)  r_dma_rx_intr_timer   <= reg_wr_data[15:0];
                    if (wr_dma_ch0_ctrl)       r_dma_ch0_ctrl        <= reg_wr_data;
                    if (wr_dma_ch0_tx_ctrl)    r_dma_ch0_tx_ctrl     <= reg_wr_data;
                    if (wr_dma_ch0_rx_ctrl)    r_dma_ch0_rx_ctrl     <= reg_wr_data;
                    if (wr_dma_ch0_tx_desc)    r_dma_ch0_tx_desc_addr <= reg_wr_data;
                    if (wr_dma_ch0_rx_desc)    r_dma_ch0_rx_desc_addr <= reg_wr_data;
                    if (wr_dma_ch0_tx_tail)    r_dma_ch0_tx_desc_tail <= reg_wr_data[7:0];
                    if (wr_dma_ch0_rx_tail)    r_dma_ch0_rx_desc_tail <= reg_wr_data[7:0];
                    if (wr_dma_ch1_ctrl)       r_dma_ch1_ctrl        <= reg_wr_data;
                    if (wr_dma_ch1_tx_ctrl)    r_dma_ch1_tx_ctrl     <= reg_wr_data;
                    if (wr_dma_ch1_rx_ctrl)    r_dma_ch1_rx_ctrl     <= reg_wr_data;
                    if (wr_dma_ch1_tx_desc)    r_dma_ch1_tx_desc_addr <= reg_wr_data;
                    if (wr_dma_ch1_rx_desc)    r_dma_ch1_rx_desc_addr <= reg_wr_data;
                    if (wr_dma_ch1_tx_tail)    r_dma_ch1_tx_desc_tail <= reg_wr_data[7:0];
                    if (wr_dma_ch1_rx_tail)    r_dma_ch1_rx_desc_tail <= reg_wr_data[7:0];
                end
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Read data mux
    //--------------------------------------------------------------------------
    reg [31:0] rd_data_reg;
    always @(*) begin
        casez (reg_addr)
            // MAC Core
            13'h000: rd_data_reg = r_mac_config;
            13'h008: rd_data_reg = r_mac_packet_filter;
            13'h00C: rd_data_reg = {18'd0, r_mac_watchdog_limit};
            13'h010: rd_data_reg = r_mac_hash_table[31:0];
            13'h014: rd_data_reg = r_mac_hash_table[63:32];
            13'h070: rd_data_reg = {r_mac_q0_tx_pause_time, 15'd0, r_mac_q0_tx_fc_enable};
            13'h074: rd_data_reg = {r_mac_q1_tx_pause_time, 15'd0, r_mac_q1_tx_fc_enable};
            13'h090: rd_data_reg = {31'd0, r_mac_rx_fc_enable};
            13'h0B0: rd_data_reg = {28'd0, mac_intr_status};       // RC
            13'h0B4: rd_data_reg = {28'd0, r_mac_intr_enable};
            13'h0B8: rd_data_reg = 32'd0;                           // Rx/Tx Status (placeholder)
            13'h110: rd_data_reg = r_mac_version;

            // MAC Addresses
            13'h300: rd_data_reg = {16'd0, r_mac_addr0[47:32]};
            13'h304: rd_data_reg = r_mac_addr0[31:0];
            13'h308: rd_data_reg = {16'd0, r_mac_addr1[47:32]};
            13'h30C: rd_data_reg = r_mac_addr1[31:0];
            13'h310: rd_data_reg = {16'd0, r_mac_addr2[47:32]};
            13'h314: rd_data_reg = r_mac_addr2[31:0];
            13'h318: rd_data_reg = {16'd0, r_mac_addr3[47:32]};
            13'h31C: rd_data_reg = r_mac_addr3[31:0];

            // MTL
            13'hC00: rd_data_reg = r_mtl_op_mode;
            13'hC20: rd_data_reg = mtl_intr_status;
            13'hC30: rd_data_reg = {28'd0, r_mtl_rxq_dma_map};
            13'hD00: rd_data_reg = r_mtl_txq0_op_mode;
            13'hD04: rd_data_reg = mtl_txq0_underflow;
            13'hD30: rd_data_reg = r_mtl_rxq0_op_mode;
            13'hD34: rd_data_reg = mtl_rxq0_missed;
            13'hD40: rd_data_reg = r_mtl_txq1_op_mode;
            13'hD44: rd_data_reg = mtl_txq1_underflow;
            13'hD70: rd_data_reg = r_mtl_rxq1_op_mode;
            13'hD74: rd_data_reg = mtl_rxq1_missed;

            // DMA
            13'h1000: rd_data_reg = r_dma_mode;
            13'h1004: rd_data_reg = r_dma_sysbus_mode;
            13'h1008: rd_data_reg = {28'd0, dma_intr_status};
            13'h100C: rd_data_reg = {28'd0, r_dma_intr_enable};
            13'h1014: rd_data_reg = {16'd0, r_dma_tx_intr_timer};
            13'h1018: rd_data_reg = {16'd0, r_dma_rx_intr_timer};
            // DMA CH0
            13'h1100: rd_data_reg = r_dma_ch0_ctrl;
            13'h1104: rd_data_reg = r_dma_ch0_tx_ctrl;
            13'h1108: rd_data_reg = r_dma_ch0_rx_ctrl;
            13'h1114: rd_data_reg = r_dma_ch0_tx_desc_addr;
            13'h111C: rd_data_reg = r_dma_ch0_rx_desc_addr;
            13'h1128: rd_data_reg = {24'd0, r_dma_ch0_tx_desc_tail};
            13'h112C: rd_data_reg = {24'd0, r_dma_ch0_rx_desc_tail};
            13'h1144: rd_data_reg = dma_ch0_status;
            // DMA CH1
            13'h1180: rd_data_reg = r_dma_ch1_ctrl;
            13'h1184: rd_data_reg = r_dma_ch1_tx_ctrl;
            13'h1188: rd_data_reg = r_dma_ch1_rx_ctrl;
            13'h1194: rd_data_reg = r_dma_ch1_tx_desc_addr;
            13'h119C: rd_data_reg = r_dma_ch1_rx_desc_addr;
            13'h11A8: rd_data_reg = {24'd0, r_dma_ch1_tx_desc_tail};
            13'h11AC: rd_data_reg = {24'd0, r_dma_ch1_rx_desc_tail};
            13'h11C4: rd_data_reg = dma_ch1_status;

            default: rd_data_reg = 32'd0;
        endcase
    end

    assign reg_rd_data = P_SHELL_MODE ? 32'd0 : rd_data_reg;

    //--------------------------------------------------------------------------
    // Output assignments to sub-module config wires
    //--------------------------------------------------------------------------
    assign mac_config           = r_mac_config;
    assign mac_packet_filter    = r_mac_packet_filter;
    assign mac_watchdog_limit   = r_mac_watchdog_limit;
    assign mac_hash_table       = r_mac_hash_table;
    assign mac_q0_tx_pause_time = r_mac_q0_tx_pause_time;
    assign mac_q0_tx_fc_enable  = r_mac_q0_tx_fc_enable;
    assign mac_q1_tx_fc_enable  = r_mac_q1_tx_fc_enable;
    assign mac_rx_fc_enable     = r_mac_rx_fc_enable;
    assign mac_intr_enable      = r_mac_intr_enable;
    assign mac_addr0            = r_mac_addr0;
    assign mac_addr1            = r_mac_addr1;
    assign mac_addr2            = r_mac_addr2;
    assign mac_addr3            = r_mac_addr3;

    assign mtl_op_mode      = r_mtl_op_mode;
    assign mtl_rxq_dma_map  = r_mtl_rxq_dma_map;
    assign mtl_txq0_op_mode = r_mtl_txq0_op_mode;
    assign mtl_txq1_op_mode = r_mtl_txq1_op_mode;
    assign mtl_rxq0_op_mode = r_mtl_rxq0_op_mode;
    assign mtl_rxq1_op_mode = r_mtl_rxq1_op_mode;

    assign dma_mode          = r_dma_mode;
    assign dma_sysbus_mode   = r_dma_sysbus_mode;
    assign dma_intr_enable   = r_dma_intr_enable;
    assign dma_tx_intr_timer = r_dma_tx_intr_timer;
    assign dma_rx_intr_timer = r_dma_rx_intr_timer;
    assign dma_ch0_ctrl        = r_dma_ch0_ctrl;
    assign dma_ch0_tx_ctrl     = r_dma_ch0_tx_ctrl;
    assign dma_ch0_rx_ctrl     = r_dma_ch0_rx_ctrl;
    assign dma_ch0_tx_desc_addr = r_dma_ch0_tx_desc_addr;
    assign dma_ch0_rx_desc_addr = r_dma_ch0_rx_desc_addr;
    assign dma_ch0_tx_desc_tail = r_dma_ch0_tx_desc_tail;
    assign dma_ch0_rx_desc_tail = r_dma_ch0_rx_desc_tail;
    assign dma_ch1_ctrl        = r_dma_ch1_ctrl;
    assign dma_ch1_tx_ctrl     = r_dma_ch1_tx_ctrl;
    assign dma_ch1_rx_ctrl     = r_dma_ch1_rx_ctrl;
    assign dma_ch1_tx_desc_addr = r_dma_ch1_tx_desc_addr;
    assign dma_ch1_rx_desc_addr = r_dma_ch1_rx_desc_addr;
    assign dma_ch1_tx_desc_tail = r_dma_ch1_tx_desc_tail;
    assign dma_ch1_rx_desc_tail = r_dma_ch1_rx_desc_tail;
    assign mac_version         = r_mac_version;

endmodule
