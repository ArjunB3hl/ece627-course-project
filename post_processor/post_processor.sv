
module post_processor #(
    parameter KERNEL_SIZE = 3,
    parameter DATA_W      = 8,
    parameter COEFF_W     = 8,
    parameter RESULT_W    = DATA_W + COEFF_W + $clog2(KERNEL_SIZE * KERNEL_SIZE)
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // --- Input AXI4-Stream (Slave: from Convolution Engine) ---
    input  logic signed [RESULT_W-1:0]    s_tdata,
    input  logic                          s_tvalid,
    output logic                          s_tready,
    input  logic                          s_tlast,

    // --- Output AXI4-Stream (Master: final processed pixel) ---
    output logic [DATA_W-1:0]             m_tdata,
    output logic                          m_tvalid,
    input  logic                          m_tready,
    output logic                          m_tlast,

    // --- Configuration registers (directly exposed) ---
    input  logic [1:0]                    i_pp_mode,       // 0=clamp, 1=threshold, 2=shift
    input  logic [DATA_W-1:0]             i_threshold,     // threshold value for mode 1
    input  logic [$clog2(RESULT_W)-1:0]   i_shift_amount   // right-shift for mode 2
);

    // =========================================================================
    // Internal signals
    // =========================================================================
    logic signed [RESULT_W-1:0]  abs_val;         // absolute value of input
    logic [DATA_W-1:0]           clamped;          // clamped to [0, 255]
    logic [DATA_W-1:0]           thresholded;      // binary threshold result
    logic [DATA_W-1:0]           shifted;          // right-shifted & clamped
    logic [DATA_W-1:0]           result_mux;       // selected output

    // Pipeline handshake
    logic                        pipe_advance;

    // =========================================================================
    // Backpressure
    // =========================================================================
    assign s_tready    = !m_tvalid || m_tready;
    assign pipe_advance = s_tready;

    // =========================================================================
    // Absolute value computation
    // =========================================================================
    always_comb begin
        if (s_tdata < 0)
            abs_val = -s_tdata;
        else
            abs_val = s_tdata;
    end

    // =========================================================================
    // Mode 0: Clamp (Absolute Value → Saturate to [0, 255])
    //
    // Takes |result| and clamps it to fit in DATA_W bits.
    // If |result| > max unsigned DATA_W value, output max (e.g., 255).
    // Otherwise, output the lower DATA_W bits.
    // =========================================================================
    localparam logic [DATA_W-1:0] MAX_VAL = {DATA_W{1'b1}};  // e.g., 255

    always_comb begin
        // Check if absolute value exceeds DATA_W-bit range
        if (abs_val > {{(RESULT_W-DATA_W){1'b0}}, MAX_VAL})
            clamped = MAX_VAL;
        else
            clamped = abs_val[DATA_W-1:0];
    end

    // =========================================================================
    // Mode 1: Binary Threshold
    //
    // If |result| > threshold → output 255 (white)
    // Else                    → output 0   (black)
    //
    // Useful for edge detection: apply Sobel, then threshold to get
    // clean binary edges.
    // =========================================================================
    always_comb begin
        if (abs_val > {{(RESULT_W-DATA_W){1'b0}}, i_threshold})
            thresholded = MAX_VAL;
        else
            thresholded = {DATA_W{1'b0}};
    end

    // =========================================================================
    // Mode 2: Right-Shift & Clamp (Normalization)
    //
    // For kernels whose coefficients sum to a power of 2 (e.g., Gaussian
    // blur with sum = 16), the MAC result needs to be divided to bring
    // it back into the pixel range. A right-shift by log2(sum) achieves
    // this efficiently.
    //
    // Process:
    //   1. Take the signed result (not absolute value — blur preserves sign)
    //   2. Arithmetic right-shift by i_shift_amount
    //   3. Clamp negative values to 0, values > 255 to 255
    // =========================================================================
    logic signed [RESULT_W-1:0] shifted_signed;

    always_comb begin
        shifted_signed = s_tdata >>> i_shift_amount;

        if (shifted_signed < 0)
            shifted = {DATA_W{1'b0}};
        else if (shifted_signed > $signed({{(RESULT_W-DATA_W){1'b0}}, MAX_VAL}))
            shifted = MAX_VAL;
        else
            shifted = shifted_signed[DATA_W-1:0];
    end

    // =========================================================================
    // Output multiplexer: select post-processing mode
    // =========================================================================
    always_comb begin
        case (i_pp_mode)
            2'd0:    result_mux = clamped;
            2'd1:    result_mux = thresholded;
            2'd2:    result_mux = shifted;
            default: result_mux = clamped;
        endcase
    end

    // =========================================================================
    // Output AXI4-Stream registration
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata  <= '0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end else if (pipe_advance) begin
            if (s_tvalid) begin
                m_tdata  <= result_mux;
                m_tvalid <= 1'b1;
                m_tlast  <= s_tlast;
            end else begin
                m_tvalid <= 1'b0;
                m_tlast  <= 1'b0;
            end
        end
    end

endmodule
