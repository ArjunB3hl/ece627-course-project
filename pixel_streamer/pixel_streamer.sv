
module pixel_streamer #(
    parameter IMG_WIDTH   = 640,
    parameter IMG_HEIGHT  = 480,
    parameter KERNEL_SIZE = 3,
    parameter DATA_W      = 8
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // --- Input AXI4-Stream (Slave interface: from testbench/memory) ---
    input  logic [DATA_W-1:0]   s_tdata,
    input  logic                 s_tvalid,
    output logic                 s_tready,
    input  logic                 s_tlast,     // optional: testbench may assert at end of frame

    // --- Output AXI4-Stream (Master interface: to Line Buffer) ---
    output logic [DATA_W-1:0]   m_tdata,
    output logic                 m_tvalid,
    input  logic                 m_tready,
    output logic                 m_tlast,     // asserted on last pixel of frame

    // --- Position metadata outputs (optional, useful for debugging/border handling) ---
    output logic [$clog2(IMG_WIDTH)-1:0]  o_col,
    output logic [$clog2(IMG_HEIGHT)-1:0] o_row,
    output logic                          o_frame_start,  // pulses high on first pixel
    output logic                          o_frame_done    // pulses high when frame completes
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam COL_W       = $clog2(IMG_WIDTH);
    localparam ROW_W       = $clog2(IMG_HEIGHT);
    localparam TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    // =========================================================================
    // Internal signals
    // =========================================================================
    logic [COL_W-1:0]  col_cnt;     // current column (0 to IMG_WIDTH-1)
    logic [ROW_W-1:0]  row_cnt;     // current row    (0 to IMG_HEIGHT-1)
    logic              last_pixel;   // high when at final pixel of frame
    logic              handshake_in; // input transfer occurred
    logic              handshake_out;// output transfer occurred

    // =========================================================================
    // Handshake detection
    // =========================================================================
    assign handshake_in  = s_tvalid && s_tready;
    assign handshake_out = m_tvalid && m_tready;

    // =========================================================================
    // Backpressure: accept input when downstream can accept, or when we have
    // no valid output data being held.
    // =========================================================================
    assign s_tready = !m_tvalid || m_tready;

    // =========================================================================
    // Last pixel detection
    // =========================================================================
    assign last_pixel = (col_cnt == IMG_WIDTH - 1) && (row_cnt == IMG_HEIGHT - 1);

    // =========================================================================
    // Output data register with AXI4-Stream handshake
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata  <= '0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end else begin
            if (s_tready) begin
                // We can accept new data (either output was consumed or wasn't valid)
                if (s_tvalid) begin
                    // Input handshake: register the pixel and pass it through
                    m_tdata  <= s_tdata;
                    m_tvalid <= 1'b1;
                    m_tlast  <= last_pixel;
                end else begin
                    // No input available: clear valid (output was already consumed)
                    m_tvalid <= 1'b0;
                    m_tlast  <= 1'b0;
                end
            end
            // else: downstream is stalled, hold current output values
        end
    end

    // =========================================================================
    // Row and column counters
    // Increment on each successful input handshake.
    // Wrap column at IMG_WIDTH, increment row at end of each row.
    // Reset both at end of frame.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= '0;
            row_cnt <= '0;
        end else if (handshake_in) begin
            if (last_pixel) begin
                // End of frame: reset counters
                col_cnt <= '0;
                row_cnt <= '0;
            end else if (col_cnt == IMG_WIDTH - 1) begin
                // End of row: wrap column, increment row
                col_cnt <= '0;
                row_cnt <= row_cnt + 1'b1;
            end else begin
                // Normal: increment column
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // Metadata outputs
    // =========================================================================
    assign o_col = col_cnt;
    assign o_row = row_cnt;

    // Frame start: first pixel of a new frame is being transferred
    assign o_frame_start = handshake_in && (col_cnt == '0) && (row_cnt == '0);

    // Frame done: last pixel of the frame has been transferred out
    assign o_frame_done  = handshake_out && m_tlast;

endmodule
