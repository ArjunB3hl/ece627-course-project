
`timescale 1ns / 1ps

module post_processor_tb;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam KERNEL_SIZE = 3;
    localparam DATA_W      = 8;
    localparam COEFF_W     = 8;
    localparam NUM_TAPS    = KERNEL_SIZE * KERNEL_SIZE;
    localparam RESULT_W    = DATA_W + COEFF_W + $clog2(NUM_TAPS);
    localparam CLK_PERIOD  = 10;

    // =========================================================================
    // Signals
    // =========================================================================
    logic                              clk;
    logic                              rst_n;

    // Input AXI-Stream
    logic signed [RESULT_W-1:0]        s_tdata;
    logic                              s_tvalid;
    logic                              s_tready;
    logic                              s_tlast;

    // Output AXI-Stream
    logic [DATA_W-1:0]                 m_tdata;
    logic                              m_tvalid;
    logic                              m_tready;
    logic                              m_tlast;

    // Config
    logic [1:0]                        i_pp_mode;
    logic [DATA_W-1:0]                 i_threshold;
    logic [$clog2(RESULT_W)-1:0]       i_shift_amount;

    // Test tracking
    integer errors;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    post_processor #(
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W),
        .COEFF_W     (COEFF_W),
        .RESULT_W    (RESULT_W)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (s_tdata),
        .s_tvalid       (s_tvalid),
        .s_tready       (s_tready),
        .s_tlast        (s_tlast),
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tready       (m_tready),
        .m_tlast        (m_tlast),
        .i_pp_mode      (i_pp_mode),
        .i_threshold    (i_threshold),
        .i_shift_amount (i_shift_amount)
    );

    // =========================================================================
    // Task: Reset
    // =========================================================================
    task automatic do_reset();
        rst_n          <= 1'b0;
        s_tdata        <= '0;
        s_tvalid       <= 1'b0;
        s_tlast        <= 1'b0;
        m_tready       <= 1'b0;
        i_pp_mode      <= 2'd0;
        i_threshold    <= 8'd128;
        i_shift_amount <= '0;
        @(posedge clk);
        @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    // =========================================================================
    // Task: Send one value and get result
    // =========================================================================
    task automatic send_get(
        input  logic signed [RESULT_W-1:0] value,
        input  logic                        last,
        output logic [DATA_W-1:0]           result,
        output logic                        result_last
    );
        s_tdata  <= value;
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        m_tready <= 1'b1;

        // Wait for input accepted
        do @(posedge clk); while (!s_tready);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;

        // Wait for output
        while (!m_tvalid) @(posedge clk);
        result      = m_tdata;
        result_last = m_tlast;
        @(posedge clk);
    endtask

    // =========================================================================
    // Helper: Check result against expected
    // =========================================================================
    task automatic check_result(
        input string         test_name,
        input logic signed [RESULT_W-1:0] input_val,
        input logic [DATA_W-1:0]          got,
        input logic [DATA_W-1:0]          expected
    );
        if (got !== expected) begin
            $display("  ERROR [%s]: input=%0d → got %0d, expected %0d",
                     test_name, input_val, got, expected);
            errors++;
        end
    endtask

    // =========================================================================
    // Test 1: Clamp Mode (mode=0)
    // |value| clamped to [0, 255]
    // =========================================================================
    task automatic test_clamp_mode();
        logic [DATA_W-1:0] result;
        logic              rlast;

        $display("\n=== Test 1: Clamp Mode ===");
        do_reset();
        errors     = 0;
        i_pp_mode <= 2'd0;
        @(posedge clk);

        // Positive value within range: 100 → 100
        send_get(20'sd100, 1'b0, result, rlast);
        check_result("pos_in_range", 20'sd100, result, 8'd100);

        // Negative value: -50 → |−50| = 50
        send_get(-20'sd50, 1'b0, result, rlast);
        check_result("neg_abs", -20'sd50, result, 8'd50);

        // Large positive: 400 → clamped to 255
        send_get(20'sd400, 1'b0, result, rlast);
        check_result("pos_saturate", 20'sd400, result, 8'd255);

        // Large negative: -500 → |−500| = 500 → clamped to 255
        send_get(-20'sd500, 1'b0, result, rlast);
        check_result("neg_saturate", -20'sd500, result, 8'd255);

        // Exactly 255: should pass through
        send_get(20'sd255, 1'b0, result, rlast);
        check_result("exact_255", 20'sd255, result, 8'd255);

        // Exactly 0: should be 0
        send_get(20'sd0, 1'b0, result, rlast);
        check_result("zero", 20'sd0, result, 8'd0);

        // Exactly 1: should be 1
        send_get(20'sd1, 1'b0, result, rlast);
        check_result("one", 20'sd1, result, 8'd1);

        // Negative 1: should be 1
        send_get(-20'sd1, 1'b0, result, rlast);
        check_result("neg_one", -20'sd1, result, 8'd1);

        if (errors == 0)
            $display("  PASSED: All clamp mode tests correct");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 2: Threshold Mode (mode=1)
    // |value| > threshold → 255, else → 0
    // =========================================================================
    task automatic test_threshold_mode();
        logic [DATA_W-1:0] result;
        logic              rlast;

        $display("\n=== Test 2: Threshold Mode ===");
        do_reset();
        errors      = 0;
        i_pp_mode  <= 2'd1;
        i_threshold <= 8'd100;
        @(posedge clk);

        // Above threshold: 150 → 255
        send_get(20'sd150, 1'b0, result, rlast);
        check_result("above_thresh", 20'sd150, result, 8'd255);

        // Below threshold: 50 → 0
        send_get(20'sd50, 1'b0, result, rlast);
        check_result("below_thresh", 20'sd50, result, 8'd0);

        // Exactly at threshold: 100 → 0 (not strictly greater)
        send_get(20'sd100, 1'b0, result, rlast);
        check_result("at_thresh", 20'sd100, result, 8'd0);

        // Just above threshold: 101 → 255
        send_get(20'sd101, 1'b0, result, rlast);
        check_result("just_above", 20'sd101, result, 8'd255);

        // Negative above threshold: -150 → |150| > 100 → 255
        send_get(-20'sd150, 1'b0, result, rlast);
        check_result("neg_above", -20'sd150, result, 8'd255);

        // Negative below threshold: -50 → |50| < 100 → 0
        send_get(-20'sd50, 1'b0, result, rlast);
        check_result("neg_below", -20'sd50, result, 8'd0);

        // Zero: 0 → below threshold → 0
        send_get(20'sd0, 1'b0, result, rlast);
        check_result("zero_thresh", 20'sd0, result, 8'd0);

        // Change threshold to 0: anything > 0 should be 255
        i_threshold <= 8'd0;
        @(posedge clk);

        send_get(20'sd1, 1'b0, result, rlast);
        check_result("thresh0_pos1", 20'sd1, result, 8'd255);

        send_get(20'sd0, 1'b0, result, rlast);
        check_result("thresh0_zero", 20'sd0, result, 8'd0);

        if (errors == 0)
            $display("  PASSED: All threshold mode tests correct");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 3: Shift Mode (mode=2)
    // Right-shift signed result, then clamp to [0, 255]
    // Useful for Gaussian blur normalization (divide by 16 = shift by 4)
    // =========================================================================
    task automatic test_shift_mode();
        logic [DATA_W-1:0] result;
        logic              rlast;

        $display("\n=== Test 3: Shift Mode (Normalization) ===");
        do_reset();
        errors          = 0;
        i_pp_mode      <= 2'd2;
        i_shift_amount <= 4;  // divide by 16 (for Gaussian)
        @(posedge clk);

        // Gaussian result for uniform 100 image: sum = 16*100 = 1600
        // 1600 >> 4 = 100
        send_get(20'sd1600, 1'b0, result, rlast);
        check_result("gauss_100", 20'sd1600, result, 8'd100);

        // Gaussian result for uniform 200 image: sum = 16*200 = 3200
        // 3200 >> 4 = 200
        send_get(20'sd3200, 1'b0, result, rlast);
        check_result("gauss_200", 20'sd3200, result, 8'd200);

        // Large value: 16*255 = 4080 >> 4 = 255
        send_get(20'sd4080, 1'b0, result, rlast);
        check_result("gauss_255", 20'sd4080, result, 8'd255);

        // Value that exceeds 255 after shift: 5000 >> 4 = 312 → clamp to 255
        send_get(20'sd5000, 1'b0, result, rlast);
        check_result("gauss_overflow", 20'sd5000, result, 8'd255);

        // Negative value: -800 >> 4 = -50 → clamp to 0
        send_get(-20'sd800, 1'b0, result, rlast);
        check_result("gauss_negative", -20'sd800, result, 8'd0);

        // Zero
        send_get(20'sd0, 1'b0, result, rlast);
        check_result("gauss_zero", 20'sd0, result, 8'd0);

        // Small value: 32 >> 4 = 2
        send_get(20'sd32, 1'b0, result, rlast);
        check_result("gauss_small", 20'sd32, result, 8'd2);

        // Test with shift=0 (no normalization): value clamped directly
        i_shift_amount <= 0;
        @(posedge clk);

        send_get(20'sd100, 1'b0, result, rlast);
        check_result("shift0_100", 20'sd100, result, 8'd100);

        send_get(20'sd300, 1'b0, result, rlast);
        check_result("shift0_overflow", 20'sd300, result, 8'd255);

        if (errors == 0)
            $display("  PASSED: All shift mode tests correct");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 4: Edge cases
    // =========================================================================
    task automatic test_edge_cases();
        logic [DATA_W-1:0] result;
        logic              rlast;
        logic signed [RESULT_W-1:0] max_pos, max_neg;

        $display("\n=== Test 4: Edge Cases ===");
        do_reset();
        errors     = 0;
        i_pp_mode <= 2'd0;  // clamp mode
        @(posedge clk);

        // Maximum positive value representable
        max_pos = {1'b0, {(RESULT_W-1){1'b1}}};  // e.g., +524287 for 20-bit
        send_get(max_pos, 1'b0, result, rlast);
        check_result("max_positive", max_pos, result, 8'd255);

        // Maximum negative value representable
        max_neg = {1'b1, {(RESULT_W-1){1'b0}}};  // e.g., -524288 for 20-bit
        send_get(max_neg, 1'b0, result, rlast);
        check_result("max_negative", max_neg, result, 8'd255);  // |max_neg| > 255

        // -1
        send_get(-20'sd1, 1'b0, result, rlast);
        check_result("minus_one", -20'sd1, result, 8'd1);

        // +256 → clamp to 255
        send_get(20'sd256, 1'b0, result, rlast);
        check_result("256_clamp", 20'sd256, result, 8'd255);

        if (errors == 0)
            $display("  PASSED: All edge cases correct");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 5: Backpressure
    // =========================================================================
    task automatic test_backpressure();
        logic [DATA_W-1:0]  results [$];
        logic [DATA_W-1:0]  golden  [$];
        integer num_tests;
        logic signed [RESULT_W-1:0] test_val;

        $display("\n=== Test 5: Backpressure Test ===");
        do_reset();
        errors    = 0;
        num_tests = 30;
        i_pp_mode <= 2'd0;  // clamp mode
        @(posedge clk);

        fork
            // Producer: send values
            begin
                for (int i = 0; i < num_tests; i++) begin
                    // Generate test values: mix of positive, negative, in-range, out-of-range
                    case (i % 4)
                        0: test_val = (i * 17) % 256;           // in range
                        1: test_val = -((i * 13) % 256);        // negative in range
                        2: test_val = 300 + i * 10;             // overflow
                        3: test_val = -(300 + i * 10);          // negative overflow
                    endcase

                    // Compute golden
                    if (test_val < 0) begin
                        if (-test_val > 255) golden.push_back(8'd255);
                        else golden.push_back((-test_val) & 8'hFF);
                    end else begin
                        if (test_val > 255) golden.push_back(8'd255);
                        else golden.push_back(test_val & 8'hFF);
                    end

                    s_tdata  <= test_val;
                    s_tvalid <= 1'b1;
                    s_tlast  <= (i == num_tests - 1);
                    do @(posedge clk); while (!s_tready);
                    s_tvalid <= 1'b0;
                    s_tlast  <= 1'b0;
                end
            end

            // Consumer: random stalls
            begin
                while (results.size() < num_tests) begin
                    m_tready <= ($urandom_range(0, 2) != 0);
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        results.push_back(m_tdata);
                    end
                end
                m_tready <= 1'b0;
            end
        join

        // Verify
        for (int i = 0; i < num_tests; i++) begin
            if (results[i] !== golden[i]) begin
                if (errors < 5)
                    $display("  ERROR: Index %0d: got %0d, expected %0d",
                             i, results[i], golden[i]);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d values correct under backpressure", num_tests);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 6: TLAST propagation
    // =========================================================================
    task automatic test_tlast_propagation();
        logic [DATA_W-1:0] result;
        logic              rlast;

        $display("\n=== Test 6: TLAST Propagation ===");
        do_reset();
        errors     = 0;
        i_pp_mode <= 2'd0;
        @(posedge clk);

        // Send without TLAST: output should have tlast=0
        send_get(20'sd42, 1'b0, result, rlast);
        if (rlast !== 1'b0) begin
            $display("  ERROR: TLAST should be 0, got 1");
            errors++;
        end

        // Send with TLAST: output should have tlast=1
        send_get(20'sd42, 1'b1, result, rlast);
        if (rlast !== 1'b1) begin
            $display("  ERROR: TLAST should be 1, got 0");
            errors++;
        end

        // Send without again after TLAST (next frame)
        send_get(20'sd42, 1'b0, result, rlast);
        if (rlast !== 1'b0) begin
            $display("  ERROR: TLAST should be 0 after frame boundary, got 1");
            errors++;
        end

        if (errors == 0)
            $display("  PASSED: TLAST propagates correctly through pipeline");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("============================================");
        $display(" Post-Processor Testbench");
        $display(" Result width: %0d bits, Output: %0d bits",
                 RESULT_W, DATA_W);
        $display("============================================");

        test_clamp_mode();
        test_threshold_mode();
        test_shift_mode();
        test_edge_cases();
        test_backpressure();
        test_tlast_propagation();

        $display("\n============================================");
        $display(" All Tests Complete!");
        $display("============================================\n");
        $stop;
    end

    // Timeout
    initial begin
        #(CLK_PERIOD * 100000);
        $display("ERROR: Simulation timeout!");
        $stop;
    end

endmodule
