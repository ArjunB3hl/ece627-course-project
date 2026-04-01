`timescale 1ns / 1ps

module tb_config #(
    parameter KERNEL_SIZE = 3,
    parameter IMG_WIDTH   = 8,
    parameter IMG_HEIGHT  = 6,
    parameter DATA_W      = 8,
    parameter COEFF_W     = 8
)();

    localparam NUM_TAPS  = KERNEL_SIZE * KERNEL_SIZE;
    localparam TOTAL_PIX = IMG_WIDTH * IMG_HEIGHT;
    localparam OUT_W     = IMG_WIDTH  - KERNEL_SIZE + 1;
    localparam OUT_H     = IMG_HEIGHT - KERNEL_SIZE + 1;
    localparam TOTAL_OUT = OUT_W * OUT_H;
    localparam CLK_HALF  = 5;

    logic clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic                          rst_n;
    logic [DATA_W-1:0]             s_tdata;
    logic                          s_tvalid, s_tready, s_tlast;
    logic [31:0]                   cfg_tdata;
    logic                          cfg_tvalid, cfg_tready, cfg_tlast;
    logic [1:0]                    i_pp_mode;
    logic [DATA_W-1:0]             i_threshold;
    logic [4:0]                    i_shift_amount;
    logic [DATA_W-1:0]             m_tdata;
    logic                          m_tvalid, m_tready, m_tlast;
    logic [$clog2(IMG_WIDTH)-1:0]  o_col;
    logic [$clog2(IMG_HEIGHT)-1:0] o_row;
    logic                          o_frame_start, o_frame_done;

    // Module-level arrays — tasks access these directly, no array ports needed
    logic signed [COEFF_W-1:0] kernel_buf [0:NUM_TAPS-1];
    logic [DATA_W-1:0]         test_image [0:TOTAL_PIX-1];
    logic [DATA_W-1:0]         golden     [0:TOTAL_OUT-1];
    logic [DATA_W-1:0]         received   [0:TOTAL_OUT-1];

    integer rx_count, errors, errors_total;

    top #(
        .IMG_WIDTH   (IMG_WIDTH),  .IMG_HEIGHT  (IMG_HEIGHT),
        .KERNEL_SIZE (KERNEL_SIZE),.DATA_W      (DATA_W),
        .COEFF_W     (COEFF_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .cfg_tdata(cfg_tdata), .cfg_tvalid(cfg_tvalid),
        .cfg_tready(cfg_tready), .cfg_tlast(cfg_tlast),
        .i_pp_mode(i_pp_mode), .i_threshold(i_threshold),
        .i_shift_amount(i_shift_amount),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast),
        .o_col(o_col), .o_row(o_row),
        .o_frame_start(o_frame_start), .o_frame_done(o_frame_done)
    );

    initial begin
        for (int i = 0; i < TOTAL_PIX; i++)
            test_image[i] = i[DATA_W-1:0];  // pixel[i] = i mod 256
    end

    // =========================================================================
    // Stimulus tasks
    // =========================================================================
    task automatic do_reset();
        rst_n <= 1'b0; s_tdata <= '0; s_tvalid <= 1'b0; s_tlast <= 1'b0;
        cfg_tdata <= '0; cfg_tvalid <= 1'b0; cfg_tlast <= 1'b0;
        m_tready <= 1'b0; i_pp_mode <= 2'd0;
        i_threshold <= 8'd128; i_shift_amount <= 5'd0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1; @(posedge clk);
    endtask

    task automatic do_load_kernel(input logic [2:0] mode);
        for (int i = 0; i < NUM_TAPS; i++) begin
            cfg_tdata <= {{(32-COEFF_W){1'b0}}, kernel_buf[i]};
            cfg_tvalid <= 1'b1; cfg_tlast <= 1'b0;
            @(posedge clk);
            while (!cfg_tready) @(posedge clk);
        end
        cfg_tdata <= {29'd0, mode}; cfg_tvalid <= 1'b1; cfg_tlast <= 1'b1;
        @(posedge clk);
        while (!cfg_tready) @(posedge clk);
        cfg_tvalid <= 1'b0; cfg_tlast <= 1'b0; @(posedge clk);
    endtask

    task automatic send_frame();
        for (int i = 0; i < TOTAL_PIX; i++) begin
            s_tdata <= test_image[i]; s_tvalid <= 1'b1;
            s_tlast <= (i == TOTAL_PIX - 1) ? 1'b1 : 1'b0;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        s_tvalid <= 1'b0; s_tlast <= 1'b0;
    endtask

    task automatic collect_all();
        rx_count = 0;
        while (rx_count < TOTAL_OUT) begin
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                received[rx_count] = m_tdata;
                rx_count = rx_count + 1;
            end
        end
    endtask

    task automatic verify_all(input string tag);
        for (int i = 0; i < TOTAL_OUT; i++) begin
            if (received[i] !== golden[i]) begin
                if (errors < 3)
                    $display("  MISMATCH [K=%0d %0dx%0d | %s] out[%0d]: got %0d, exp %0d",
                             KERNEL_SIZE, IMG_WIDTH, IMG_HEIGHT,
                             tag, i, received[i], golden[i]);
                errors++; errors_total++;
            end
        end
    endtask

    // =========================================================================
    // Golden builders
    // =========================================================================
    task automatic make_golden_identity();
        int cx;
        for (int i = 0; i < TOTAL_OUT; i++) begin
            cx = ((i/OUT_W) + KERNEL_SIZE/2)*IMG_WIDTH + ((i%OUT_W) + KERNEL_SIZE/2);
            golden[i] = test_image[cx];
        end
    endtask

    task automatic make_golden_all_ones();
        int s, img_r, img_c;
        for (int i = 0; i < TOTAL_OUT; i++) begin
            s = 0;
            for (int kr = 0; kr < KERNEL_SIZE; kr++)
                for (int kc = 0; kc < KERNEL_SIZE; kc++) begin
                    img_r = (i/OUT_W) + kr; img_c = (i%OUT_W) + kc;
                    s = s + test_image[img_r*IMG_WIDTH + img_c];
                end
            golden[i] = (s > 255) ? 8'd255 : s[DATA_W-1:0];
        end
    endtask

    // =========================================================================
    // Display helpers
    // =========================================================================

    // Print kernel as K×K grid
    task automatic print_kernel();
        for (int kr = 0; kr < KERNEL_SIZE; kr++) begin
            $write("      [");
            for (int kc = 0; kc < KERNEL_SIZE; kc++)
                $write(" %3d", $signed(kernel_buf[kr*KERNEL_SIZE + kc]));
            $display(" ]");
        end
    endtask

    // Print compact results table: idx | expected | actual | status
    task automatic print_results(input string label);
        int pass_count;
        pass_count = 0;
        $display("  Results (%s):", label);
        $display("    %4s | %5s | %5s | %8s | %6s | %s",
                 "idx", "r_out", "c_out", "expected", "actual", "status");
        $display("    -----+-------+-------+----------+--------+-------");
        for (int i = 0; i < TOTAL_OUT; i++) begin
            if (received[i] === golden[i]) pass_count = pass_count + 1;
            $display("    %4d | %5d | %5d | %8d | %6d | %s",
                     i, i/OUT_W, i%OUT_W,
                     golden[i], received[i],
                     (received[i] === golden[i]) ? "OK" : "FAIL");
        end
        $display("    => %0d / %0d correct", pass_count, TOTAL_OUT);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        errors_total = 0;

        $display("\n--------------------------------------------------------------");
        $display(" K=%0d  IMG=%0dx%0d  Taps=%0d  Output grid=%0dx%0d (%0d windows)",
                 KERNEL_SIZE, IMG_WIDTH, IMG_HEIGHT, NUM_TAPS, OUT_W, OUT_H, TOTAL_OUT);
        $display("--------------------------------------------------------------");

        // ------------------------------------------------------------------
        // Test 1 — Identity kernel
        // ------------------------------------------------------------------
        errors = 0;
        $display("\n  [Test 1] Identity kernel — output = center pixel of each window");
        $display("  Kernel:");
        for (int i = 0; i < NUM_TAPS; i++) kernel_buf[i] = '0;
        kernel_buf[NUM_TAPS/2] = 8'sd1;
        print_kernel();
        make_golden_identity();
        do_reset(); do_load_kernel(3'd0);
        i_pp_mode <= 2'd0; m_tready <= 1'b1;
        fork send_frame(); collect_all(); join
        verify_all("identity");
        print_results("identity");
        $display("  => %s", (errors == 0) ? "PASSED" : "FAILED");

        // ------------------------------------------------------------------
        // Test 2 — All-ones kernel + clamp
        // ------------------------------------------------------------------
        errors = 0;
        $display("\n  [Test 2] All-ones kernel — output = sum of K² window pixels (clamped to 255)");
        $display("  Kernel:");
        for (int i = 0; i < NUM_TAPS; i++) kernel_buf[i] = 8'sd1;
        print_kernel();
        make_golden_all_ones();
        do_reset(); do_load_kernel(3'd0);
        i_pp_mode <= 2'd0; m_tready <= 1'b1;
        fork send_frame(); collect_all(); join
        verify_all("all_ones");
        print_results("all_ones");
        $display("  => %s", (errors == 0) ? "PASSED" : "FAILED");

        // ------------------------------------------------------------------
        // Test 3 — Backpressure
        // ------------------------------------------------------------------
        errors = 0;
        $display("\n  [Test 3] Backpressure — identity kernel, m_tready ~50%% random");
        for (int i = 0; i < NUM_TAPS; i++) kernel_buf[i] = '0;
        kernel_buf[NUM_TAPS/2] = 8'sd1;
        make_golden_identity();
        do_reset(); do_load_kernel(3'd0);
        i_pp_mode <= 2'd0;
        fork
            send_frame();
            begin
                rx_count = 0;
                while (rx_count < TOTAL_OUT) begin
                    m_tready <= ($urandom_range(0,1) == 0);
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        received[rx_count] = m_tdata;
                        rx_count = rx_count + 1;
                    end
                end
                m_tready <= 1'b0;
            end
        join
        verify_all("backpressure");
        print_results("backpressure");
        $display("  => %s", (errors == 0) ? "PASSED" : "FAILED");

        // ------------------------------------------------------------------
        // Test 4 — TLAST propagation
        // ------------------------------------------------------------------
        errors = 0;
        $display("\n  [Test 4] TLAST — must arrive on pixel %0d (last output)", TOTAL_OUT);
        for (int i = 0; i < NUM_TAPS; i++) kernel_buf[i] = '0;
        kernel_buf[NUM_TAPS/2] = 8'sd1;
        do_reset(); do_load_kernel(3'd0);
        i_pp_mode <= 2'd0; m_tready <= 1'b1;
        begin
            integer cnt; integer saw;
            cnt = 0; saw = 0;
            fork
                send_frame();
                begin
                    while (!saw) begin
                        @(posedge clk);
                        if (m_tvalid && m_tready) begin
                            cnt = cnt + 1;
                            if (m_tlast) saw = 1;
                        end
                    end
                end
            join
            $display("    tlast on pixel %0d  (expected %0d)  => %s",
                     cnt, TOTAL_OUT,
                     (cnt === TOTAL_OUT) ? "CORRECT" : "WRONG");
            if (cnt !== TOTAL_OUT) begin errors++; errors_total++; end
        end
        $display("  => %s", (errors == 0) ? "PASSED" : "FAILED");

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n  K=%0d %0dx%0d : %s  (%0d errors total)",
                 KERNEL_SIZE, IMG_WIDTH, IMG_HEIGHT,
                 (errors_total == 0) ? "ALL PASSED" : "FAILURES",
                 errors_total);
    end

endmodule


// =============================================================================
// top_tb — runs all five configurations concurrently
// =============================================================================
module top_tb;

    initial begin
        $display("==============================================================");
        $display(" Parametric Testbench — 5 configs x 4 tests");
        $display(" Kernel sweep : K=3/5/7  (6x4 = 24-window output grid)");
        $display(" Res. sweep   : K=3  8x6 / 16x12 / 20x16");
        $display("==============================================================");
    end

    // Kernel sweep
    tb_config #(.KERNEL_SIZE(3), .IMG_WIDTH(8),  .IMG_HEIGHT(6))  cfg_k3_s ();
    tb_config #(.KERNEL_SIZE(5), .IMG_WIDTH(10), .IMG_HEIGHT(8))  cfg_k5   ();
    tb_config #(.KERNEL_SIZE(7), .IMG_WIDTH(12), .IMG_HEIGHT(10)) cfg_k7   ();

    // Resolution sweep (K=3 fixed)
    tb_config #(.KERNEL_SIZE(3), .IMG_WIDTH(16), .IMG_HEIGHT(12)) cfg_k3_m ();
    tb_config #(.KERNEL_SIZE(3), .IMG_WIDTH(20), .IMG_HEIGHT(16)) cfg_k3_l ();

    initial begin
        #(10 * 600_000);
        $display("\n==============================================================");
        $display(" Simulation complete");
        $display("==============================================================\n");
        $finish;
    end

endmodule
