module top #(
    parameter IMG_WIDTH   = 8,
    parameter IMG_HEIGHT  = 6,
    parameter KERNEL_SIZE = 3,
    parameter DATA_W      = 8,
    parameter COEFF_W     = 8
)(
    input  logic                                   clk,
    input  logic                                   rst_n,

    // -------------------------------------------------------------------------
    // Raw pixel input stream (from memory / DMA / testbench)
    // -------------------------------------------------------------------------
    input  logic [DATA_W-1:0]                      s_tdata,
    input  logic                                   s_tvalid,
    output logic                                   s_tready,
    input  logic                                   s_tlast,

    // -------------------------------------------------------------------------
    // Kernel config stream → conv_engine
    // -------------------------------------------------------------------------
    input  logic [31:0]                            cfg_tdata,
    input  logic                                   cfg_tvalid,
    output logic                                   cfg_tready,
    input  logic                                   cfg_tlast,

    // -------------------------------------------------------------------------
    // Post-processor configuration (static registers)
    // -------------------------------------------------------------------------
    input  logic [1:0]                             i_pp_mode,
    input  logic [DATA_W-1:0]                      i_threshold,
    input  logic [4:0]                             i_shift_amount,

    // -------------------------------------------------------------------------
    // Processed pixel output stream
    // -------------------------------------------------------------------------
    output logic [DATA_W-1:0]                      m_tdata,
    output logic                                   m_tvalid,
    input  logic                                   m_tready,
    output logic                                   m_tlast,

    // -------------------------------------------------------------------------
    // Frame metadata (from pixel_streamer)
    // -------------------------------------------------------------------------
    output logic [$clog2(IMG_WIDTH)-1:0]           o_col,
    output logic [$clog2(IMG_HEIGHT)-1:0]          o_row,
    output logic                                   o_frame_start,
    output logic                                   o_frame_done
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam RESULT_W = DATA_W + COEFF_W + $clog2(KERNEL_SIZE * KERNEL_SIZE);
    localparam SHIFT_W  = $clog2(RESULT_W);
    localparam WINDOW_W = KERNEL_SIZE * KERNEL_SIZE * DATA_W;

    // =========================================================================
    // Inter-stage wires
    // =========================================================================

    // pixel_streamer → line_buffer
    logic [DATA_W-1:0]   ps_lb_tdata;
    logic                ps_lb_tvalid;
    logic                ps_lb_tready;
    logic                ps_lb_tlast;

    // line_buffer → conv_engine
    logic [WINDOW_W-1:0] lb_ce_tdata;
    logic                lb_ce_tvalid;
    logic                lb_ce_tready;
    logic                lb_ce_tlast;

    // conv_engine → post_processor
    logic signed [RESULT_W-1:0] ce_pp_tdata;
    logic                       ce_pp_tvalid;
    logic                       ce_pp_tready;
    logic                       ce_pp_tlast;

    // =========================================================================
    // Stage 1 — Pixel Streamer
    // =========================================================================
    pixel_streamer #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W)
    ) u_pixel_streamer (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_tdata       (s_tdata),
        .s_tvalid      (s_tvalid),
        .s_tready      (s_tready),
        .s_tlast       (s_tlast),
        .m_tdata       (ps_lb_tdata),
        .m_tvalid      (ps_lb_tvalid),
        .m_tready      (ps_lb_tready),
        .m_tlast       (ps_lb_tlast),
        .o_col         (o_col),
        .o_row         (o_row),
        .o_frame_start (o_frame_start),
        .o_frame_done  (o_frame_done)
    );

    // =========================================================================
    // Stage 2 — Line Buffer
    // =========================================================================
    line_buffer #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W)
    ) u_line_buffer (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (ps_lb_tdata),
        .s_tvalid (ps_lb_tvalid),
        .s_tready (ps_lb_tready),
        .s_tlast  (ps_lb_tlast),
        .m_tdata  (lb_ce_tdata),
        .m_tvalid (lb_ce_tvalid),
        .m_tready (lb_ce_tready),
        .m_tlast  (lb_ce_tlast)
    );

    // =========================================================================
    // Stage 3 — Convolution Engine
    // =========================================================================
    conv_engine #(
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W),
        .COEFF_W     (COEFF_W),
        .RESULT_W    (RESULT_W)
    ) u_conv_engine (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (lb_ce_tdata),
        .s_tvalid   (lb_ce_tvalid),
        .s_tready   (lb_ce_tready),
        .s_tlast    (lb_ce_tlast),
        .cfg_tdata  (cfg_tdata),
        .cfg_tvalid (cfg_tvalid),
        .cfg_tready (cfg_tready),
        .cfg_tlast  (cfg_tlast),
        .m_tdata    (ce_pp_tdata),
        .m_tvalid   (ce_pp_tvalid),
        .m_tready   (ce_pp_tready),
        .m_tlast    (ce_pp_tlast)
    );

    // =========================================================================
    // Stage 4 — Post-Processor
    // =========================================================================
    post_processor #(
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W),
        .COEFF_W     (COEFF_W),
        .RESULT_W    (RESULT_W)
    ) u_post_processor (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (ce_pp_tdata),
        .s_tvalid       (ce_pp_tvalid),
        .s_tready       (ce_pp_tready),
        .s_tlast        (ce_pp_tlast),
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tready       (m_tready),
        .m_tlast        (m_tlast),
        .i_pp_mode      (i_pp_mode),
        .i_threshold    (i_threshold),
        .i_shift_amount (i_shift_amount[SHIFT_W-1:0])
    );

endmodule
