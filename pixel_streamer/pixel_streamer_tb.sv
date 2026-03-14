`timescale 1ns / 1ps

module pixel_streamer_tb;

    // =========================================================================
    // Parameters - use small image for fast simulation
    // =========================================================================
    localparam IMG_WIDTH    = 8;
    localparam IMG_HEIGHT   = 6;
    localparam KERNEL_SIZE  = 3;
    localparam DATA_W       = 8;
    localparam TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;
    localparam CLK_PERIOD   = 10;

    // =========================================================================
    // Signals
    // =========================================================================
    logic clk;
    logic rst_n;

    // Input AXI-Stream
    logic [DATA_W-1:0] s_tdata;
    logic              s_tvalid;
    logic              s_tready;
    logic              s_tlast;

    // Output AXI-Stream
    logic [DATA_W-1:0] m_tdata;
    logic              m_tvalid;
    logic              m_tready;
    logic              m_tlast;

    // Metadata
    logic [$clog2(IMG_WIDTH)-1:0]  o_col;
    logic [$clog2(IMG_HEIGHT)-1:0] o_row;
    logic                          o_frame_start;
    logic                          o_frame_done;

    // Test tracking
    integer            pixels_received;
    integer            errors;
    logic [DATA_W-1:0] received_data[$];

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    pixel_streamer #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .KERNEL_SIZE (KERNEL_SIZE),
        .DATA_W      (DATA_W)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_tdata       (s_tdata),
        .s_tvalid      (s_tvalid),
        .s_tready      (s_tready),
        .s_tlast       (s_tlast),
        .m_tdata       (m_tdata),
        .m_tvalid      (m_tvalid),
        .m_tready      (m_tready),
        .m_tlast       (m_tlast),
        .o_col         (o_col),
        .o_row         (o_row),
        .o_frame_start (o_frame_start),
        .o_frame_done  (o_frame_done)
    );

    // =========================================================================
    // Task: Reset the DUT
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
    // Task: Send one pixel on input AXI-Stream (waits for handshake)
    // =========================================================================
    task automatic send_pixel(input logic [DATA_W-1:0] pixel);
        s_tdata  <= pixel;
        s_tvalid <= 1'b1;
        s_tlast  <= 1'b0;
        do begin
            @(posedge clk);
        end while (!s_tready);
        s_tvalid <= 1'b0;
    endtask

    // =========================================================================
    // Task: Collect output pixels (runs in parallel)
    // =========================================================================
    task automatic collect_outputs(input integer expected_count);
        pixels_received = 0;
        received_data.delete();
        while (pixels_received < expected_count) begin
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                received_data.push_back(m_tdata);
                pixels_received++;
            end
        end
    endtask

    // =========================================================================
    // Test 1: Normal streaming - full frame, no backpressure
    // =========================================================================
    task automatic test_normal_streaming();
        integer i;
        logic [DATA_W-1:0] expected_pixel;

        $display("\n=== Test 1: Normal Streaming (no backpressure) ===");
        do_reset();

        errors   = 0;
        m_tready <= 1'b1;

        fork
            begin
                for (i = 0; i < TOTAL_PIXELS; i++) begin
                    send_pixel(i[DATA_W-1:0]);
                end
            end
            begin
                collect_outputs(TOTAL_PIXELS);
            end
        join

        for (i = 0; i < TOTAL_PIXELS; i++) begin
            expected_pixel = i[DATA_W-1:0];
            if (received_data[i] !== expected_pixel) begin
                $display("  ERROR: Pixel %0d: got %0d, expected %0d",
                         i, received_data[i], expected_pixel);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d pixels received correctly", TOTAL_PIXELS);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 2: Backpressure - downstream stalls intermittently
    // =========================================================================
    task automatic test_backpressure();
        integer i;
        logic [DATA_W-1:0] expected_pixel;

        $display("\n=== Test 2: Backpressure Test ===");
        do_reset();

        errors = 0;

        fork
            begin
                for (i = 0; i < TOTAL_PIXELS; i++) begin
                    send_pixel(i[DATA_W-1:0]);
                end
            end
            begin
                pixels_received = 0;
                received_data.delete();
                while (pixels_received < TOTAL_PIXELS) begin
                    m_tready <= ($urandom_range(0, 3) != 0);
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        received_data.push_back(m_tdata);
                        pixels_received++;
                    end
                end
                m_tready <= 1'b0;
            end
        join

        for (i = 0; i < TOTAL_PIXELS; i++) begin
            expected_pixel = i[DATA_W-1:0];
            if (received_data[i] !== expected_pixel) begin
                $display("  ERROR: Pixel %0d: got %0d, expected %0d",
                         i, received_data[i], expected_pixel);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d pixels survived backpressure", TOTAL_PIXELS);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 3: Input stalling - producer stalls intermittently
    // =========================================================================
    task automatic test_input_stalling();
        integer i;
        integer pixel_idx;
        integer gap;
        logic [DATA_W-1:0] expected_pixel;

        $display("\n=== Test 3: Input Stalling Test ===");
        do_reset();

        errors   = 0;
        m_tready <= 1'b1;

        fork
            begin
                s_tvalid <= 1'b0;
                s_tdata  <= '0;
                s_tlast  <= 1'b0;

                for (pixel_idx = 0; pixel_idx < TOTAL_PIXELS; pixel_idx++) begin
                    gap = $urandom_range(0, 3);

                    repeat (gap) begin
                        s_tvalid <= 1'b0;
                        s_tdata  <= '0;
                        s_tlast  <= 1'b0;
                        @(posedge clk);
                    end

                    send_pixel(pixel_idx[DATA_W-1:0]);
                end

                s_tvalid <= 1'b0;
                s_tdata  <= '0;
                s_tlast  <= 1'b0;
            end
            begin
                collect_outputs(TOTAL_PIXELS);
            end
        join

        if (received_data.size() != TOTAL_PIXELS) begin
            $display("  ERROR: Expected %0d pixels, got %0d",
                     TOTAL_PIXELS, received_data.size());
            errors++;
        end

        for (i = 0; i < TOTAL_PIXELS; i++) begin
            expected_pixel = i[DATA_W-1:0];
            if (received_data[i] !== expected_pixel) begin
                if (errors < 5)
                    $display("  ERROR: Pixel %0d: got %0d, expected %0d",
                             i, received_data[i], expected_pixel);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: All %0d pixels correct despite input stalling", TOTAL_PIXELS);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Test 4: TLAST and counter verification
    // =========================================================================
    task automatic test_tlast_and_counters();
        integer i;
        integer expected_col, expected_row;

        $display("\n=== Test 4: TLAST and Counter Verification ===");
        do_reset();

        errors   = 0;
        m_tready <= 1'b1;

        for (i = 0; i < TOTAL_PIXELS; i++) begin
            s_tdata  <= i[DATA_W-1:0];
            s_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
            #1;

            expected_col = ((i + 1) % IMG_WIDTH);
            expected_row = ((i + 1) / IMG_WIDTH);
            if (i == TOTAL_PIXELS - 1) begin
                expected_col = 0;
                expected_row = 0;
            end

            if (o_col !== expected_col[$clog2(IMG_WIDTH)-1:0]) begin
                $display("  ERROR: After pixel %0d: col=%0d, expected=%0d", i, o_col, expected_col);
                errors++;
            end
            if (o_row !== expected_row[$clog2(IMG_HEIGHT)-1:0]) begin
                $display("  ERROR: After pixel %0d: row=%0d, expected=%0d", i, o_row, expected_row);
                errors++;
            end
        end
        s_tvalid <= 1'b0;

        @(posedge clk);
        @(posedge clk);

        if (errors == 0)
            $display("  PASSED: Row/column counters correct for all %0d pixels", TOTAL_PIXELS);
        else
            $display("  FAILED: %0d counter errors", errors);
    endtask

    // =========================================================================
    // Test 5: Multiple frames back-to-back
    // =========================================================================
    task automatic test_multiple_frames();
        integer frame, i;

        $display("\n=== Test 5: Multiple Frames (counter reset) ===");
        do_reset();

        errors   = 0;
        m_tready <= 1'b1;

        for (frame = 0; frame < 2; frame++) begin
            $display("  Sending frame %0d...", frame);

            fork
                begin
                    for (i = 0; i < TOTAL_PIXELS; i++) begin
                        send_pixel((frame * TOTAL_PIXELS + i) & 8'hFF);
                    end
                end
                begin
                    collect_outputs(TOTAL_PIXELS);
                end
            join

            @(posedge clk);
            #1;
            if (o_col !== '0 || o_row !== '0) begin
                $display("  ERROR: Frame %0d: counters not reset (col=%0d, row=%0d)",
                         frame, o_col, o_row);
                errors++;
            end
        end

        if (errors == 0)
            $display("  PASSED: Counters reset correctly across %0d frames", 2);
        else
            $display("  FAILED: %0d errors", errors);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("============================================");
        $display(" Pixel Streamer Testbench");
        $display(" Image: %0d x %0d, Kernel: %0dx%0d",
                 IMG_WIDTH, IMG_HEIGHT, KERNEL_SIZE, KERNEL_SIZE);
        $display("============================================");

        test_normal_streaming();
        test_backpressure();
        test_input_stalling();
        test_tlast_and_counters();
        test_multiple_frames();

        $display("\n============================================");
        $display(" All Tests Complete!");
        $display("============================================\n");
        $stop;
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 100000);
        $display("ERROR: Simulation timeout!");
        $stop;
    end

endmodule


