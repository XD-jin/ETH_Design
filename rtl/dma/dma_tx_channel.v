// ============================================================================
// Module: DMA_TX_CHANNEL
// File:    dma_tx_channel.v
// Author:  ETH_Design Team
// Version: v2.0
// Date:    2026-06-27
// Description:
//   Single TX DMA channel. 5-phase operation:
//     1. ST_DESC0~3: Fetch 16-byte descriptor (4 AHB reads)
//     2. ST_XFER:    Read data from buffer → push to MTL via ATI
//     3. ST_DONE:    Write back status, advance to next descriptor
//   Supports ring descriptor with OWN bit polling.
// ============================================================================

module dma_tx_channel #(
    parameter P_RING_LEN   = 64,
    parameter P_SHELL_MODE = 0
) (
    input  wire        clk, rst_n,

    // CSR registers
    input  wire        ch_start,
    input  wire [31:0] desc_base,
    input  wire [ 7:0] desc_tail,
    input  wire [ 7:0] desc_len,
    input  wire [ 4:0] tx_pbl,

    // AHB Master interface (read only — TX reads from memory)
    output wire        ahb_req,
    input  wire        ahb_grant,
    output wire [31:0] ahb_addr,
    output wire [ 2:0] ahb_burst,
    input  wire [31:0] ahb_rdata,
    input  wire        rdata_valid,
    input  wire        ahb_ready,
    input  wire        ahb_error,

    // ATI interface (to MTL TX)
    output wire        ati_val,
    input  wire        ati_rdy,
    output wire [31:0] ati_data,
    output wire        ati_sop,
    output wire        ati_eop,
    output wire [ 1:0] ati_be,

    // Status
    output wire        ch_done,
    output wire        ch_error,
    output wire        ch_suspended
);

    //--------------------------------------------------------------------------
    // FSM States
    //--------------------------------------------------------------------------
    localparam ST_IDLE   = 3'd0;
    localparam ST_DESC0  = 3'd1;     // Read TDES0: buf1_addr
    localparam ST_DESC1  = 3'd2;     // Read TDES1: buf2_addr
    localparam ST_DESC2  = 3'd3;     // Read TDES2: lengths + IOC
    localparam ST_DESC3  = 3'd4;     // Read TDES3: OWN,FD,LD,CPC
    localparam ST_XFER   = 3'd5;     // Transfer data buffer → ATI
    localparam ST_DONE   = 3'd6;     // Frame complete, advance descriptor

    reg [ 2:0] curr_st, next_st;

    // Descriptor tracking
    reg [ 7:0] current_desc;
    reg [31:0] desc_addr;

    // Descriptor fields (parsed from AHB reads)
    reg [31:0] buf1_addr, buf2_addr;
    reg [15:0] buf1_len, buf2_len;
    reg        fd, ld;
    reg        ioc;
    reg [ 1:0] cpc;
    reg        own_bit;

    // Data transfer tracking
    reg [15:0] byte_cnt;             // Bytes sent for current buffer
    reg [15:0] frame_remain;         // Remaining bytes in current frame
    reg        active_buf;           // 0=buf1, 1=buf2
    reg        xfer_done;            // 1 = all data transferred

    // Error tracking
    reg        desc_error;           // OWN=0 or AHB error

    //--------------------------------------------------------------------------
    // Shell Mode
    //--------------------------------------------------------------------------
    generate
        if (P_SHELL_MODE) begin : gen_shell
            assign ahb_req   = 1'b0;
            assign ahb_addr  = 32'd0;
            assign ahb_burst = 3'd0;
            assign ati_val   = 1'b0;
            assign ati_data  = 32'd0;
            assign ati_sop   = 1'b0;
            assign ati_eop   = 1'b0;
            assign ati_be    = 2'd0;
            assign ch_done   = 1'b0;
            assign ch_error  = 1'b0;
            assign ch_suspended = 1'b0;
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
                    ST_IDLE:  next_st = ch_start ? ST_DESC0 : ST_IDLE;
                    ST_DESC0: next_st = (rdata_valid && ahb_grant) ? ST_DESC1 : ST_DESC0;
                    ST_DESC1: next_st = (rdata_valid && ahb_grant) ? ST_DESC2 : ST_DESC1;
                    ST_DESC2: next_st = (rdata_valid && ahb_grant) ? ST_DESC3 : ST_DESC2;
                    ST_DESC3: begin
                        if (rdata_valid) begin
                            if (own_bit)
                                next_st = ST_XFER;
                            else
                                next_st = ST_IDLE;   // OWN=0: suspend
                        end else
                            next_st = ST_DESC3;
                    end
                    ST_XFER: begin
                        if (ahb_error)
                            next_st = ST_DONE;
                        else if (xfer_done)
                            next_st = ST_DONE;
                        else
                            next_st = ST_XFER;
                    end
                    ST_DONE:  next_st = ST_IDLE;
                    default:  next_st = ST_IDLE;
                endcase
            end

            //------------------------------------------------------------------
            // Datapath
            //------------------------------------------------------------------
            always @(posedge clk or negedge rst_n) begin
                if (rst_n == 1'b0) begin
                    current_desc <= 8'd0;
                    desc_addr    <= 32'd0;
                    buf1_addr    <= 32'd0;
                    buf2_addr    <= 32'd0;
                    buf1_len     <= 16'd0;
                    buf2_len     <= 16'd0;
                    fd           <= 1'b0;
                    ld           <= 1'b0;
                    ioc          <= 1'b0;
                    cpc          <= 2'd0;
                    own_bit      <= 1'b0;
                    byte_cnt     <= 16'd0;
                    frame_remain <= 16'd0;
                    active_buf   <= 1'b0;
                    xfer_done    <= 1'b0;
                    desc_error   <= 1'b0;
                end else begin
                    case (curr_st)
                        ST_IDLE: begin
                            byte_cnt     <= 16'd0;
                            frame_remain <= 16'd0;
                            active_buf   <= 1'b0;
                            xfer_done    <= 1'b0;
                            desc_error   <= 1'b0;
                            // Pre-compute descriptor address
                            desc_addr <= desc_base + (current_desc * 32'd16);
                        end

                        // Descriptor word 0: TDES0 = buf1_addr[31:0]
                        ST_DESC0: begin
                            if (ahb_ready) begin
                                buf1_addr <= ahb_rdata;
                                desc_addr <= desc_addr + 32'd4;
                            end
                        end

                        // Descriptor word 1: TDES1 = buf2_addr[31:0]
                        ST_DESC1: begin
                            if (ahb_ready) begin
                                buf2_addr <= ahb_rdata;
                                desc_addr <= desc_addr + 32'd4;
                            end
                        end

                        // Descriptor word 2: TDES2 = {IOC,TTSE,B2L[13:8],VTIR,B1L[13:0]}
                        ST_DESC2: begin
                            if (ahb_ready) begin
                                ioc      <= ahb_rdata[31];
                                buf2_len <= {3'd0, ahb_rdata[29:16]};
                                buf1_len <= ahb_rdata[15:0];
                                desc_addr <= desc_addr + 32'd4;
                            end
                        end

                        // Descriptor word 3: TDES3 = {OWN,CTXT,FD,LD,CPC,SAIC,...FL[14:0]}
                        ST_DESC3: begin
                            if (ahb_ready) begin
                                own_bit  <= ahb_rdata[31];
                                fd       <= ahb_rdata[29];
                                ld       <= ahb_rdata[28];
                                cpc      <= ahb_rdata[27:26];
                                // FL (frame length) in [14:0]; we use buf1_len for data length
                                if (~own_bit)
                                    desc_error <= 1'b1;   // OWN=0: no data to send
                            end
                        end

                        // Transfer data from buffer to MTL via ATI
                        ST_XFER: begin
                            if (ahb_ready && ati_rdy) begin
                                frame_remain <= frame_remain + 16'd4;
                                byte_cnt     <= byte_cnt + 16'd4;

                                // Check if current buffer exhausted
                                if (~active_buf && (byte_cnt + 16'd4 >= buf1_len)) begin
                                    active_buf <= 1'b1;
                                    byte_cnt   <= 16'd0;
                                end
                                // Check if frame complete (all bytes transferred)
                                if (ld && (frame_remain + 16'd4 >= buf1_len + buf2_len))
                                    xfer_done <= 1'b1;
                            end
                        end

                        // Advance to next descriptor
                        ST_DONE: begin
                            current_desc <= (current_desc == desc_len - 1) ? 8'd0 : current_desc + 8'd1;
                        end
                    endcase
                end
            end

            //------------------------------------------------------------------
            // AHB Interface
            //------------------------------------------------------------------
            wire in_desc_phase;
            assign in_desc_phase = (curr_st == ST_DESC0) || (curr_st == ST_DESC1) ||
                                   (curr_st == ST_DESC2) || (curr_st == ST_DESC3);
            wire in_xfer_phase;
            assign in_xfer_phase = (curr_st == ST_XFER);

            // Only request bus when arbiter has granted access
            assign ahb_req   = in_desc_phase || in_xfer_phase;
            // Descriptor address increments by 4 each word; buffer address from buf1/buf2
            assign ahb_addr  = in_desc_phase ? desc_addr :
                               (active_buf ? buf2_addr + byte_cnt : buf1_addr + byte_cnt);
            assign ahb_burst = 3'd0;   // SINGLE read

            //------------------------------------------------------------------
            // ATI Interface (to MTL)
            //------------------------------------------------------------------
            assign ati_val  = in_xfer_phase && ahb_ready;
            assign ati_data = ahb_rdata;            // Data from AHB read
            assign ati_sop  = in_xfer_phase && (frame_remain == 16'd0);
            assign ati_eop  = in_xfer_phase && xfer_done;
            assign ati_be   = 2'b11;                // Always full word

            //------------------------------------------------------------------
            // Status
            //------------------------------------------------------------------
            assign ch_done     = (curr_st == ST_DONE);
            assign ch_error    = ahb_error || desc_error;
            assign ch_suspended = (curr_st == ST_IDLE) && ch_start;

        end
    endgenerate

endmodule
