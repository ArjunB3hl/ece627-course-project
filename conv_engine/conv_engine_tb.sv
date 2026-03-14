
`timescale 1ns / 1ps

module conv_engine_tb;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam KERNEL_SIZE = 3;
    localparam DATA_W      = 8;
    localparam COEFF_W     = 8;
    localparam NUM_TAPS    = KERNEL_SIZE * KERNEL_SIZE;
    localparam WINDOW_W    = NUM_TAPS * DATA_W;
    localparam RESULT_W    = DATA_W + COEFF_W + $clog2(NUM_TAPS);
    localparam CLK_PERIOD  = 10;

    // =========================================================================
    // Signals
    // =========================================================================
    logic                    clk;
    logic                    rst_n;

    // Input AXI-Stream (window)
    logic [WINDOW_W-1:0]     s_tdata;
    logic                    s_tvalid;
    logic                    s_tready;
    logic                    s_tlast;

    // Config AXI-Stream
    logic [31:0]             cfg_tdata;
    logic                    cfg_tvalid;
    logic                    cfg_tready;
    logic                    cfg_tlast;

    // Output AXI-Stream
    logic signed [RESULT_W-1:0] m_tdata;
    logic                       m_tvalid;
    logic                       m_tready;
    logic                       m_tlast;

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
    conv_engine #(
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W),
        .COEFF_W     (COEFF_W),
        .RESULT_W    (RESULT_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (s_tdata),
        .s_tvalid   (s_tvalid),
        .s_tready   (s_tready),
        .s_tlast    (s_tlast),
        .cfg_tdata  (cfg_tdata),
        .cfg_tvalid (cfg_tvalid),
        .cfg_tready (cfg_tready),
        .cfg_tlast  (cfg_tlast),
        .m_tdata    (m_tdata),
        .m_tvalid   (m_tvalid),
        .m_tready   (m_tready),
        .m_tlast    (m_tlast)
    );

    // =========================================================================
    // Task: Reset
    // =========================================================================
    task automatic do_reset();
        rst_n      <= 1'b0;
        s_tdata    <= '0;
        s_tvalid   <= 1'b0;
        s_tlast    <= 1'b0;
        cfg_tdata  <= '0;
        cfg_tvalid <= 1'b0;
        cfg_tlast  <= 1'b0;
        m_tready   <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    // =========================================================================
    // Helper: Pack a 3x3 window into the flat bus
    // window[row][col] → tdata[(row*3+col)*8 +: 8]
    // =========================================================================
    function automatic logic [WINDOW_W-1:0] pack_window(
        input logic [DATA_W-1:0] w [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0]
    );
        logic [WINDOW_W-1:0] win_packed;
        win_packed = '0;
        for (int r = 0; r < KERNEL_SIZE; r++) begin
            for (int c = 0; c < KERNEL_SIZE; c++) begin
                win_packed[(r*KERNEL_SIZE + c)*DATA_W +: DATA_W] = w[r][c];
            end
        end
        return win_packed;
    endfunction

    // =========================================================================
    // Helper: Compute expected MAC result in software
    // =========================================================================
    function automatic integer compute_golden_mac(
        input logic [DATA_W-1:0]       pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0],
        input logic signed [COEFF_W-1:0] coeffs [NUM_TAPS-1:0]
    );
        integer sum;
        sum = 0;
        for (int r = 0; r < KERNEL_SIZE; r++) begin
            for (int c = 0; c < KERNEL_SIZE; c++) begin
                sum = sum + $signed({1'b0, pixels[r][c]}) * coeffs[r*KERNEL_SIZE + c];
            end
        end
        return sum;
    endfunction

    // =========================================================================
    // Task: Send one window and wait for result
    // =========================================================================
    task automatic send_window_get_result(
        input  logic [WINDOW_W-1:0]        window,
        input  logic                        last,
        output logic signed [RESULT_W-1:0]  result
    );
        // Send input
        s_tdata  <= window;
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        m_tready <= 1'b1;

        // Wait for input accepted
        do @(posedge clk); while (!s_tready);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;

        // Wait for output
        while (!m_tvalid) @(posedge clk);
        result = m_tdata;
        @(posedge clk);
    endtask

    // =========================================================================
    // Task: Load custom kernel via config stream
    // Sends NUM_TAPS coefficients then 1 mode beat
    // =========================================================================
    task automatic load_kernel(
        input logic signed [COEFF_W-1:0] coeffs [NUM_TAPS-1:0],
        input logic [2:0]                mode
    );
        // Send coefficients
        for (int i = 0; i < NUM_TAPS; i++) begin
            cfg_tdata  <= {{(32-COEFF_W){1'b0}}, coeffs[i]};
            cfg_tvalid <= 1'b1;
            cfg_tlast  <= 1'b0;
            @(posedge clk);
            while (!cfg_tready) @(posedge clk);
        end

        // Send mode
        cfg_tdata  <= {29'd0, mode};
        cfg_tvalid <= 1'b1;
        cfg_tlast  <= 1'b1;
        @(posedge clk);
        while (!cfg_tready) @(posedge clk);
        cfg_tvalid <= 1'b0;
        cfg_tlast  <= 1'b0;
        @(posedge clk);
    endtask

    // =========================================================================
    // Test 1: Identity Kernel (only center = 1)
    // Output should equal center pixel value
    // =========================================================================
    task automatic test_identity_kernel();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] identity_k [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] result;
        integer golden;

        $display("\n=== Test 1: Identity Kernel ===");
        do_reset();
        errors = 0;

        // Create identity kernel: all zeros except center = 1
        for (int i = 0; i < NUM_TAPS; i++) identity_k[i] = 0;
        identity_k[(NUM_TAPS-1)/2] = 8'sd1;  // center element

        // Load kernel
        load_kernel(identity_k, 3'd0);

        // Test with several windows
        for (int t = 0; t < 10; t++) begin
            // Create window with known values
            for (int r = 0; r < KERNEL_SIZE; r++)
                for (int c = 0; c < KERNEL_SIZE; c++)
                    pixels[r][c] = (t * 17 + r * 7 + c * 3) & 8'hFF;

            win_packed = pack_window(pixels);
            golden = pixels[(KERNEL_SIZE-1)/2][(KERNEL_SIZE-1)/2];  // center pixel

            send_window_get_result(win_packed, (t == 9), result);

            if (result !== golden[RESULT_W-1:0]) begin
                $display("  ERROR: Test %0d: got %0d, expected %0d (center pixel)",
                         t, result, golden);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: Identity kernel produces center pixel values");
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 2: Default Sobel-X
    // =========================================================================
    task automatic test_default_sobel_x();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] sobel_x [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] result;
        integer golden;

        $display("\n=== Test 2: Default Sobel-X Kernel ===");
        do_reset();
        errors = 0;
        m_tready <= 1'b1;

        // Sobel-X coefficients for golden computation
        sobel_x[0] = -8'sd1; sobel_x[1] =  8'sd0; sobel_x[2] =  8'sd1;
        sobel_x[3] = -8'sd2; sobel_x[4] =  8'sd0; sobel_x[5] =  8'sd2;
        sobel_x[6] = -8'sd1; sobel_x[7] =  8'sd0; sobel_x[8] =  8'sd1;

        // Window representing a vertical edge:
        //   0   0  100
        //   0   0  100
        //   0   0  100
        pixels[0][0] = 0;   pixels[0][1] = 0;   pixels[0][2] = 100;
        pixels[1][0] = 0;   pixels[1][1] = 0;   pixels[1][2] = 100;
        pixels[2][0] = 0;   pixels[2][1] = 0;   pixels[2][2] = 100;

        win_packed = pack_window(pixels);
        golden = compute_golden_mac(pixels, sobel_x);

        $display("  Vertical edge window, expected Sobel-X result: %0d", golden);

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Got %0d (expected %0d)", result, golden);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end

        // Horizontal edge (should give ~0 for Sobel-X):
        //   100 100 100
        //     0   0   0
        //     0   0   0
        pixels[0][0] = 100; pixels[0][1] = 100; pixels[0][2] = 100;
        pixels[1][0] = 0;   pixels[1][1] = 0;   pixels[1][2] = 0;
        pixels[2][0] = 0;   pixels[2][1] = 0;   pixels[2][2] = 0;

        win_packed = pack_window(pixels);
        golden = compute_golden_mac(pixels, sobel_x);

        $display("  Horizontal edge window, expected Sobel-X result: %0d", golden);

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Got %0d (expected %0d)", result, golden);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end
    endtask

    // =========================================================================
    // Test 3: Custom kernel via config stream
    // Load an all-ones kernel: output should be sum of all pixels
    // =========================================================================
    task automatic test_custom_kernel();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] all_ones [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] result;
        integer golden;

        $display("\n=== Test 3: Custom Kernel (All Ones) ===");
        do_reset();
        errors = 0;

        // All-ones kernel
        for (int i = 0; i < NUM_TAPS; i++) all_ones[i] = 8'sd1;

        // Load custom kernel (mode 0)
        load_kernel(all_ones, 3'd0);

        // Test: window of values 1-9
        pixels[0][0] = 1; pixels[0][1] = 2; pixels[0][2] = 3;
        pixels[1][0] = 4; pixels[1][1] = 5; pixels[1][2] = 6;
        pixels[2][0] = 7; pixels[2][1] = 8; pixels[2][2] = 9;

        win_packed = pack_window(pixels);
        golden = 1+2+3+4+5+6+7+8+9;  // = 45

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Sum of 1..9 = %0d (expected %0d)", result, golden);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end
    endtask

    // =========================================================================
    // Test 4: Preset mode switching
    // Load Sobel-Y via mode select, verify with known window
    // =========================================================================
    task automatic test_preset_modes();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] sobel_y [NUM_TAPS-1:0];
        logic signed [COEFF_W-1:0] dummy_coeffs [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] result;
        integer golden;

        $display("\n=== Test 4: Preset Mode (Sobel-Y) ===");
        do_reset();
        errors = 0;

        // Sobel-Y for golden computation
        sobel_y[0] = -8'sd1; sobel_y[1] = -8'sd2; sobel_y[2] = -8'sd1;
        sobel_y[3] =  8'sd0; sobel_y[4] =  8'sd0; sobel_y[5] =  8'sd0;
        sobel_y[6] =  8'sd1; sobel_y[7] =  8'sd2; sobel_y[8] =  8'sd1;

        // Load Sobel-Y preset (dummy coefficients, mode 2 overrides them)
        for (int i = 0; i < NUM_TAPS; i++) dummy_coeffs[i] = 8'sd0;
        load_kernel(dummy_coeffs, 3'd2);

        // Horizontal edge: strong response for Sobel-Y
        //     0   0   0
        //     0   0   0
        //   100 100 100
        pixels[0][0] = 0;   pixels[0][1] = 0;   pixels[0][2] = 0;
        pixels[1][0] = 0;   pixels[1][1] = 0;   pixels[1][2] = 0;
        pixels[2][0] = 100; pixels[2][1] = 100; pixels[2][2] = 100;

        win_packed = pack_window(pixels);
        golden = compute_golden_mac(pixels, sobel_y);

        $display("  Horizontal edge, Sobel-Y expected: %0d", golden);

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Got %0d", result);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end
    endtask

    // =========================================================================
    // Test 5: Backpressure
    // =========================================================================
    task automatic test_backpressure();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] all_ones [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] results [$];
        integer golden_vals [$];
        integer golden, num_tests;

        $display("\n=== Test 5: Backpressure Test ===");
        do_reset();
        errors = 0;
        num_tests = 20;

        // All-ones kernel for easy golden computation
        for (int i = 0; i < NUM_TAPS; i++) all_ones[i] = 8'sd1;
        load_kernel(all_ones, 3'd0);

        fork
            // Producer: send windows
            begin
                for (int t = 0; t < num_tests; t++) begin
                    for (int r = 0; r < KERNEL_SIZE; r++)
                        for (int c = 0; c < KERNEL_SIZE; c++)
                            pixels[r][c] = ((t + 1) * (r * KERNEL_SIZE + c + 1)) & 8'hFF;

                    win_packed = pack_window(pixels);

                    // Compute golden sum
                    golden = 0;
                    for (int r = 0; r < KERNEL_SIZE; r++)
                        for (int c = 0; c < KERNEL_SIZE; c++)
                            golden = golden + pixels[r][c];
                    golden_vals.push_back(golden);

                    s_tdata  <= win_packed;
                    s_tvalid <= 1'b1;
                    s_tlast  <= (t == num_tests - 1);
                    do @(posedge clk); while (!s_tready);
                    s_tvalid <= 1'b0;
                    s_tlast  <= 1'b0;
                end
            end

            // Consumer: random backpressure
            begin
                while (results.size() < num_tests) begin
                    m_tready <= ($urandom_range(0, 2) != 0);  // ~67% ready
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
            if (results[i] !== golden_vals[i][RESULT_W-1:0]) begin
                if (errors < 5)
                    $display("  ERROR: Window %0d: got %0d, expected %0d",
                             i, results[i], golden_vals[i]);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d windows correct under backpressure", num_tests);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 6: Uniform window (all pixels same value)
    // With all-ones kernel, result = NUM_TAPS * pixel_value
    // =========================================================================
    task automatic test_uniform_window();
        logic [DATA_W-1:0] pixels [KERNEL_SIZE-1:0][KERNEL_SIZE-1:0];
        logic signed [COEFF_W-1:0] all_ones [NUM_TAPS-1:0];
        logic [WINDOW_W-1:0] win_packed;
        logic signed [RESULT_W-1:0] result;
        integer golden;

        $display("\n=== Test 6: Uniform Window ===");
        do_reset();
        errors = 0;

        for (int i = 0; i < NUM_TAPS; i++) all_ones[i] = 8'sd1;
        load_kernel(all_ones, 3'd0);

        // All pixels = 100 → sum = 9 * 100 = 900
        for (int r = 0; r < KERNEL_SIZE; r++)
            for (int c = 0; c < KERNEL_SIZE; c++)
                pixels[r][c] = 100;

        win_packed = pack_window(pixels);
        golden = NUM_TAPS * 100;

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Uniform 100 → sum = %0d (expected %0d)", result, golden);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end

        // All pixels = 255 → sum = 9 * 255 = 2295
        for (int r = 0; r < KERNEL_SIZE; r++)
            for (int c = 0; c < KERNEL_SIZE; c++)
                pixels[r][c] = 255;

        win_packed = pack_window(pixels);
        golden = NUM_TAPS * 255;

        send_window_get_result(win_packed, 1'b0, result);

        if (result == golden[RESULT_W-1:0]) begin
            $display("  PASSED: Uniform 255 → sum = %0d (expected %0d)", result, golden);
        end else begin
            $display("  FAILED: Got %0d (expected %0d)", result, golden);
            errors++;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("============================================");
        $display(" Convolution Engine Testbench");
        $display(" Kernel: %0dx%0d, Pixel: %0d-bit, Coeff: %0d-bit",
                 KERNEL_SIZE, KERNEL_SIZE, DATA_W, COEFF_W);
        $display(" Result width: %0d bits", RESULT_W);
        $display("============================================");

        test_identity_kernel();
        test_default_sobel_x();
        test_custom_kernel();
        test_preset_modes();
        test_backpressure();
        test_uniform_window();

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

