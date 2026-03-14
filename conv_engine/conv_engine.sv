
module conv_engine #(
    parameter KERNEL_SIZE = 3,
    parameter DATA_W      = 8,
    parameter COEFF_W     = 8,
    // Full precision: DATA_W + COEFF_W + ceil(log2(KERNEL_SIZE^2))
    parameter RESULT_W    = DATA_W + COEFF_W + $clog2(KERNEL_SIZE * KERNEL_SIZE)
)(
    input  logic                                          clk,
    input  logic                                          rst_n,

    // --- Input AXI4-Stream (Slave: window from Line Buffer) ---
    input  logic [KERNEL_SIZE*KERNEL_SIZE*DATA_W-1:0]     s_tdata,
    input  logic                                          s_tvalid,
    output logic                                          s_tready,
    input  logic                                          s_tlast,

    // --- Config AXI4-Stream (Slave: kernel coefficients + mode) ---
    // Config protocol:
    //   Send KERNEL_SIZE^2 beats of signed coefficients (COEFF_W bits each),
    //   then 1 beat with mode select in lower 3 bits.
    //   Assert tlast on the final (mode) beat.
    input  logic [31:0]                                   cfg_tdata,
    input  logic                                          cfg_tvalid,
    output logic                                          cfg_tready,
    input  logic                                          cfg_tlast,

    // --- Output AXI4-Stream (Master: MAC result to Post-Processor) ---
    output logic signed [RESULT_W-1:0]                    m_tdata,
    output logic                                          m_tvalid,
    input  logic                                          m_tready,
    output logic                                          m_tlast
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam NUM_TAPS    = KERNEL_SIZE * KERNEL_SIZE;  // e.g., 9 for 3x3
    localparam PRODUCT_W   = DATA_W + COEFF_W;           // single multiply width

    // =========================================================================
    // Kernel coefficient storage
    // =========================================================================
    logic signed [COEFF_W-1:0] kernel_coeff [NUM_TAPS-1:0];
    logic [2:0]                filter_mode;

    // =========================================================================
    // Config loading state machine
    // =========================================================================
    typedef enum logic [1:0] {
        CFG_IDLE,
        CFG_LOAD_COEFFS,
        CFG_LOAD_MODE
    } cfg_state_t;

    cfg_state_t                cfg_state;
    logic [$clog2(NUM_TAPS):0] cfg_cnt;  // counts coefficients loaded

    // Config is always ready to accept when in loading states
    assign cfg_tready = (cfg_state == CFG_IDLE) || 
                        (cfg_state == CFG_LOAD_COEFFS) || 
                        (cfg_state == CFG_LOAD_MODE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_state   <= CFG_IDLE;
            cfg_cnt     <= '0;
            filter_mode <= 3'd1;  // Default to Sobel-X

            // Initialize with default Sobel-X kernel (3x3)
            // Will be overwritten for non-3x3 kernels via config stream
            for (int i = 0; i < NUM_TAPS; i++) begin
                kernel_coeff[i] <= '0;
            end

            // Default 3x3 Sobel-X (only valid if KERNEL_SIZE == 3)
            if (KERNEL_SIZE == 3) begin
                kernel_coeff[0] <= -8'sd1;  kernel_coeff[1] <=  8'sd0;  kernel_coeff[2] <=  8'sd1;
                kernel_coeff[3] <= -8'sd2;  kernel_coeff[4] <=  8'sd0;  kernel_coeff[5] <=  8'sd2;
                kernel_coeff[6] <= -8'sd1;  kernel_coeff[7] <=  8'sd0;  kernel_coeff[8] <=  8'sd1;
            end

        end else begin
            case (cfg_state)
                CFG_IDLE: begin
                    if (cfg_tvalid) begin
                        // Start loading custom coefficients
                        kernel_coeff[0] <= cfg_tdata[COEFF_W-1:0];
                        cfg_cnt         <= 1;
                        cfg_state       <= CFG_LOAD_COEFFS;
                    end
                end

                CFG_LOAD_COEFFS: begin
                    if (cfg_tvalid) begin
                        kernel_coeff[cfg_cnt] <= cfg_tdata[COEFF_W-1:0];
                        cfg_cnt <= cfg_cnt + 1;

                        if (cfg_cnt == NUM_TAPS - 1) begin
                            // All coefficients loaded, next beat is mode
                            cfg_state <= CFG_LOAD_MODE;
                        end
                    end
                end

                CFG_LOAD_MODE: begin
                    if (cfg_tvalid) begin
                        filter_mode <= cfg_tdata[2:0];

                        // If a preset mode is selected, override custom coefficients
                        if (KERNEL_SIZE == 3) begin
                            case (cfg_tdata[2:0])
                                3'd1: begin  // Sobel-X
                                    kernel_coeff[0] <= -8'sd1; kernel_coeff[1] <=  8'sd0; kernel_coeff[2] <=  8'sd1;
                                    kernel_coeff[3] <= -8'sd2; kernel_coeff[4] <=  8'sd0; kernel_coeff[5] <=  8'sd2;
                                    kernel_coeff[6] <= -8'sd1; kernel_coeff[7] <=  8'sd0; kernel_coeff[8] <=  8'sd1;
                                end
                                3'd2: begin  // Sobel-Y
                                    kernel_coeff[0] <= -8'sd1; kernel_coeff[1] <= -8'sd2; kernel_coeff[2] <= -8'sd1;
                                    kernel_coeff[3] <=  8'sd0; kernel_coeff[4] <=  8'sd0; kernel_coeff[5] <=  8'sd0;
                                    kernel_coeff[6] <=  8'sd1; kernel_coeff[7] <=  8'sd2; kernel_coeff[8] <=  8'sd1;
                                end
                                3'd3: begin  // Gaussian Blur (1/16 normalization done in post-proc)
                                    kernel_coeff[0] <=  8'sd1; kernel_coeff[1] <=  8'sd2; kernel_coeff[2] <=  8'sd1;
                                    kernel_coeff[3] <=  8'sd2; kernel_coeff[4] <=  8'sd4; kernel_coeff[5] <=  8'sd2;
                                    kernel_coeff[6] <=  8'sd1; kernel_coeff[7] <=  8'sd2; kernel_coeff[8] <=  8'sd1;
                                end
                                3'd4: begin  // Sharpen
                                    kernel_coeff[0] <=  8'sd0; kernel_coeff[1] <= -8'sd1; kernel_coeff[2] <=  8'sd0;
                                    kernel_coeff[3] <= -8'sd1; kernel_coeff[4] <=  8'sd5; kernel_coeff[5] <= -8'sd1;
                                    kernel_coeff[6] <=  8'sd0; kernel_coeff[7] <= -8'sd1; kernel_coeff[8] <=  8'sd0;
                                end
                                default: ;  // Mode 0 = custom, keep loaded coefficients
                            endcase
                        end

                        cfg_state <= CFG_IDLE;
                        cfg_cnt   <= '0;
                    end
                end

                default: cfg_state <= CFG_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Pipeline Stage 1: Multiply
    // Multiply each pixel in the window by its corresponding kernel coefficient.
    // Pixels are unsigned, coefficients are signed → result is signed.
    // =========================================================================
    logic signed [PRODUCT_W-1:0] products_s1 [NUM_TAPS-1:0];
    logic                        valid_s1;
    logic                        tlast_s1;

    // Extract individual pixels from packed window
    logic [DATA_W-1:0] pixels [NUM_TAPS-1:0];
    genvar gi;
    generate
        for (gi = 0; gi < NUM_TAPS; gi++) begin : gen_unpack
            assign pixels[gi] = s_tdata[gi*DATA_W +: DATA_W];
        end
    endgenerate

    // Backpressure for input
    logic pipe_advance_s1;
    assign pipe_advance_s1 = !valid_s1 || pipe_advance_s2;
    assign s_tready = pipe_advance_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            tlast_s1 <= 1'b0;
            for (int i = 0; i < NUM_TAPS; i++) begin
                products_s1[i] <= '0;
            end
        end else if (pipe_advance_s1) begin
            if (s_tvalid) begin
                valid_s1 <= 1'b1;
                tlast_s1 <= s_tlast;
                for (int i = 0; i < NUM_TAPS; i++) begin
                    // Signed multiplication: sign-extend unsigned pixel
                    products_s1[i] <= $signed({1'b0, pixels[i]}) * kernel_coeff[i];
                end
            end else begin
                valid_s1 <= 1'b0;
                tlast_s1 <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Pipeline Stage 2: Adder Tree
    // Sum all products using a balanced binary tree for timing efficiency.
    // For 9 taps: 5 adds (level 1) → 3 adds (level 2) → 2 adds (level 3) → 1 add (level 4)
    // We implement this as a single combinational sum for simplicity.
    // For larger kernels or higher frequencies, this could be further pipelined.
    // =========================================================================
    logic signed [RESULT_W-1:0] sum_s2;
    logic                       valid_s2;
    logic                       tlast_s2;
    logic                       pipe_advance_s2;

    assign pipe_advance_s2 = !valid_s2 || (m_tready);

    // Combinational adder tree
    logic signed [RESULT_W-1:0] tree_sum;
    always_comb begin
        tree_sum = '0;
        for (int i = 0; i < NUM_TAPS; i++) begin
            tree_sum = tree_sum + $signed({{(RESULT_W - PRODUCT_W){products_s1[i][PRODUCT_W-1]}},
                                            products_s1[i]});
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_s2   <= '0;
            valid_s2 <= 1'b0;
            tlast_s2 <= 1'b0;
        end else if (pipe_advance_s2) begin
            if (valid_s1) begin
                sum_s2   <= tree_sum;
                valid_s2 <= 1'b1;
                tlast_s2 <= tlast_s1;
            end else begin
                valid_s2 <= 1'b0;
                tlast_s2 <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Output assignment
    // =========================================================================
    assign m_tdata  = sum_s2;
    assign m_tvalid = valid_s2;
    assign m_tlast  = tlast_s2;

endmodule
