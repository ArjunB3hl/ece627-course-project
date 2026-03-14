
`timescale 1ns / 1ps

module line_buffer_tb;

    // =========================================================================
    // Parameters - small image for fast simulation
    // =========================================================================
    localparam IMG_WIDTH   = 8;
    localparam IMG_HEIGHT  = 6;
    localparam KERNEL_SIZE = 3;
    localparam DATA_W      = 8;
    localparam CLK_PERIOD  = 10;

    // Derived
    localparam WINDOW_SIZE  = KERNEL_SIZE * KERNEL_SIZE;
    localparam WINDOW_W     = WINDOW_SIZE * DATA_W;
    localparam OUT_WIDTH    = IMG_WIDTH  - KERNEL_SIZE + 1;  // 6
    localparam OUT_HEIGHT   = IMG_HEIGHT - KERNEL_SIZE + 1;  // 4
    localparam TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;        // 48
    localparam TOTAL_OUTPUTS = OUT_WIDTH * OUT_HEIGHT;       // 24

    // =========================================================================
    // Signals
    // =========================================================================
    logic                   clk;
    logic                   rst_n;

    // Input AXI-Stream
    logic [DATA_W-1:0]      s_tdata;
    logic                   s_tvalid;
    logic                   s_tready;
    logic                   s_tlast;

    // Output AXI-Stream
    logic [WINDOW_W-1:0]    m_tdata;
    logic                   m_tvalid;
    logic                   m_tready;
    logic                   m_tlast;

    // Test image: stored as a flat array, value = row*IMG_WIDTH + col
    // This makes it easy to verify windows
    logic [DATA_W-1:0]      test_image [TOTAL_PIXELS-1:0];

    // Collected output windows
    logic [WINDOW_W-1:0]    received_windows [$];
    integer                 windows_received;
    integer                 errors;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    line_buffer #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (s_tdata),
        .s_tvalid (s_tvalid),
        .s_tready (s_tready),
        .s_tlast  (s_tlast),
        .m_tdata  (m_tdata),
        .m_tvalid (m_tvalid),
        .m_tready (m_tready),
        .m_tlast  (m_tlast)
    );

    // =========================================================================
    // Initialize test image
    // Pixel value = row * IMG_WIDTH + col (unique per pixel, easy to verify)
    // =========================================================================
    initial begin
        for (int i = 0; i < TOTAL_PIXELS; i++) begin
            test_image[i] = i[DATA_W-1:0];
        end
    end

    // =========================================================================
    // Task: Reset DUT
    // =========================================================================
    task automatic do_reset();
        rst_n    <= 1'b0;
        s_tdata  <= '0;
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
        m_tready <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    // =========================================================================
    // Task: Send one pixel
    // =========================================================================
    task automatic send_pixel(input logic [DATA_W-1:0] pixel, input logic last);
        s_tdata  <= pixel;
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        do begin
            @(posedge clk);
        end while (!s_tready);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // =========================================================================
    // Task: Send entire frame
    // =========================================================================
    task automatic send_frame();
        for (int i = 0; i < TOTAL_PIXELS; i++) begin
            send_pixel(test_image[i], (i == TOTAL_PIXELS - 1));
        end
    endtask

    // =========================================================================
    // Task: Collect output windows
    // =========================================================================
    task automatic collect_windows(input integer expected_count);
        windows_received = 0;
        received_windows.delete();
        while (windows_received < expected_count) begin
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                received_windows.push_back(m_tdata);
                windows_received++;
            end
        end
    endtask

    // =========================================================================
    // Function: Extract a pixel from a packed window
    // window[(row*KERNEL_SIZE + col) * DATA_W +: DATA_W]
    // =========================================================================
    function automatic logic [DATA_W-1:0] get_window_pixel(
        input logic [WINDOW_W-1:0] window,
        input int row,
        input int col
    );
        int idx;
        idx = (row * KERNEL_SIZE + col) * DATA_W;
        return window[idx +: DATA_W];
    endfunction

    // =========================================================================
    // Function: Compute expected pixel value in a window
    // For output window (out_row, out_col), the pixel at window position
    // (kr, kc) corresponds to image pixel at:
    //   image_row = out_row + kr
    //   image_col = out_col + kc
    //   value = image_row * IMG_WIDTH + image_col
    // =========================================================================
    function automatic logic [DATA_W-1:0] expected_pixel(
        input int out_row,
        input int out_col,
        input int kr,
        input int kc
    );
        int img_row, img_col, pixel_val;
        img_row   = out_row + kr;
        img_col   = out_col + kc;
        pixel_val = img_row * IMG_WIDTH + img_col;
        return pixel_val[DATA_W-1:0];
    endfunction

    // =========================================================================
    // Test 1: Basic window correctness (no backpressure)
    // =========================================================================
    task automatic test_basic_windows();
        int out_idx, out_row, out_col;
        logic [DATA_W-1:0] got_pix, exp_pix;

        $display("\n=== Test 1: Basic Window Correctness ===");
        do_reset();
        errors = 0;
        m_tready <= 1'b1;

        fork
            send_frame();
            collect_windows(TOTAL_OUTPUTS);
        join

        $display("  Received %0d windows (expected %0d)", windows_received, TOTAL_OUTPUTS);

        // Verify each output window
        for (out_idx = 0; out_idx < TOTAL_OUTPUTS; out_idx++) begin
            out_row = out_idx / OUT_WIDTH;
            out_col = out_idx % OUT_WIDTH;

            for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
                for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                    got_pix = get_window_pixel(received_windows[out_idx], kr, kc);
                    exp_pix = expected_pixel(out_row, out_col, kr, kc);

                    if (got_pix !== exp_pix) begin
                        if (errors < 10) begin  // Limit error output
                            $display("  ERROR: Window[%0d] (out_row=%0d, out_col=%0d) "
                                     + "pixel[%0d][%0d]: got %0d, expected %0d",
                                     out_idx, out_row, out_col, kr, kc, got_pix, exp_pix);
                        end
                        errors++;
                    end
                end
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d windows verified correctly", TOTAL_OUTPUTS);
        else
            $display("  FAILED: %0d pixel errors across all windows", errors);
    endtask

    // =========================================================================
    // Test 2: Backpressure test (random downstream stalls)
    // =========================================================================
    task automatic test_backpressure();
        int out_idx, out_row, out_col;
        logic [DATA_W-1:0] got_pix, exp_pix;

        $display("\n=== Test 2: Backpressure Test ===");
        do_reset();
        errors = 0;

        fork
            send_frame();
            // Consumer with random stalls
            begin
                windows_received = 0;
                received_windows.delete();
                while (windows_received < TOTAL_OUTPUTS) begin
                    m_tready <= ($urandom_range(0, 3) != 0);  // 75% ready
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        received_windows.push_back(m_tdata);
                        windows_received++;
                    end
                end
                m_tready <= 1'b0;
            end
        join

        // Verify all windows
        for (out_idx = 0; out_idx < TOTAL_OUTPUTS; out_idx++) begin
            out_row = out_idx / OUT_WIDTH;
            out_col = out_idx % OUT_WIDTH;

            for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
                for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                    got_pix = get_window_pixel(received_windows[out_idx], kr, kc);
                    exp_pix = expected_pixel(out_row, out_col, kr, kc);
                    if (got_pix !== exp_pix) errors++;
                end
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d windows correct under backpressure", TOTAL_OUTPUTS);
        else
            $display("  FAILED: %0d pixel errors", errors);
    endtask

    // =========================================================================
    // Test 3: Output count verification
    // =========================================================================
    task automatic test_output_count();
        int count;
        logic saw_tlast;

        $display("\n=== Test 3: Output Count & TLAST Verification ===");
        do_reset();
        errors    = 0;
        count     = 0;
        saw_tlast = 0;
        m_tready <= 1'b1;

        fork
            send_frame();
            begin
                // Count outputs until TLAST or timeout
                while (!saw_tlast) begin
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        count++;
                        if (m_tlast) saw_tlast = 1;
                    end
                end
            end
        join

        if (count == TOTAL_OUTPUTS)
            $display("  PASSED: Output count = %0d (expected %0d)", count, TOTAL_OUTPUTS);
        else begin
            $display("  FAILED: Output count = %0d (expected %0d)", count, TOTAL_OUTPUTS);
            errors++;
        end

        if (saw_tlast)
            $display("  PASSED: TLAST asserted on last output window");
        else begin
            $display("  FAILED: TLAST not seen");
            errors++;
        end
    endtask

    // =========================================================================
    // Test 4: Multiple frames
    // =========================================================================
    task automatic test_multiple_frames();
        int out_idx, out_row, out_col;
        logic [DATA_W-1:0] got_pix, exp_pix;

        $display("\n=== Test 4: Multiple Frames ===");
        do_reset();
        errors = 0;
        m_tready <= 1'b1;

        for (int frame = 0; frame < 2; frame++) begin
            $display("  Frame %0d...", frame);

            fork
                send_frame();
                collect_windows(TOTAL_OUTPUTS);
            join

            // Verify all windows of this frame
            for (out_idx = 0; out_idx < TOTAL_OUTPUTS; out_idx++) begin
                out_row = out_idx / OUT_WIDTH;
                out_col = out_idx % OUT_WIDTH;

                for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
                    for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                        got_pix = get_window_pixel(received_windows[out_idx], kr, kc);
                        exp_pix = expected_pixel(out_row, out_col, kr, kc);
                        if (got_pix !== exp_pix) errors++;
                    end
                end
            end
        end

        if (errors == 0)
            $display("  PASSED: Both frames produced correct windows");
        else
            $display("  FAILED: %0d pixel errors across frames", errors);
    endtask

    // =========================================================================
    // Test 5: Print first few windows for visual inspection
    // =========================================================================
    task automatic test_print_windows();
        int out_row, out_col;
        logic [DATA_W-1:0] pix;

        $display("\n=== Visual Inspection: First 4 Windows ===");
        $display("  Image layout (8x6, value = row*8 + col):");
        $display("    Row 0:  0  1  2  3  4  5  6  7");
        $display("    Row 1:  8  9 10 11 12 13 14 15");
        $display("    Row 2: 16 17 18 19 20 21 22 23");
        $display("    ...");

        do_reset();
        m_tready <= 1'b1;

        fork
            send_frame();
            collect_windows(4);  // Just first 4
        join

        for (int w = 0; w < 4; w++) begin
            out_row = w / OUT_WIDTH;
            out_col = w % OUT_WIDTH;
            $display("\n  Window %0d (top-left at row=%0d, col=%0d):", w, out_row, out_col);
            for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
                $write("    [");
                for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                    pix = get_window_pixel(received_windows[w], kr, kc);
                    $write(" %3d", pix);
                end
                $display(" ]");
            end
        end

        // Expected first window (row=0, col=0):
        //   [  0   1   2 ]
        //   [  8   9  10 ]
        //   [ 16  17  18 ]
        $display("\n  Expected first window:");
        $display("    [   0   1   2 ]");
        $display("    [   8   9  10 ]");
        $display("    [  16  17  18 ]");
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("============================================");
        $display(" Line Buffer Testbench");
        $display(" Image: %0d x %0d, Kernel: %0dx%0d",
                 IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE);
        $display(" Expected output windows: %0d x %0d = %0d",
                 OUT_WIDTH, OUT_HEIGHT, TOTAL_OUTPUTS);
        $display("============================================");

        test_basic_windows();
        test_backpressure();
        test_output_count();
        test_multiple_frames();
        test_print_windows();

        $display("\n============================================");
        $display(" All Tests Complete!");
        $display("============================================\n");
        $stop;
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 500000);
        $display("ERROR: Simulation timeout!");
        $stop;
    end

endmodule
