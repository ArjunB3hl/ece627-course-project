
module line_buffer #(
    parameter IMG_WIDTH   = 640,
    parameter IMG_HEIGHT  = 480,
    parameter KERNEL_SIZE = 3,
    parameter DATA_W      = 8
)(
    input  logic                                      clk,
    input  logic                                      rst_n,

    // --- Input AXI-Stream ---
    input  logic [DATA_W-1:0]                         s_tdata,
    input  logic                                      s_tvalid,
    output logic                                      s_tready,
    input  logic                                      s_tlast,

    // --- Output AXI-Stream ---
    output logic [KERNEL_SIZE*KERNEL_SIZE*DATA_W-1:0] m_tdata,
    output logic                                      m_tvalid,
    input  logic                                      m_tready,
    output logic                                      m_tlast
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam NUM_ROWS     = KERNEL_SIZE;
    localparam NUM_BUFFERS  = KERNEL_SIZE - 1;
    localparam COL_W        = $clog2(IMG_WIDTH + 1);
    localparam ROW_W        = $clog2(IMG_HEIGHT + 1);

    // =========================================================================
    // Storage
    // =========================================================================
    logic [DATA_W-1:0] row_buffer [NUM_BUFFERS-1:0][IMG_WIDTH-1:0];
    logic [DATA_W-1:0] row_out    [NUM_BUFFERS-1:0];
    logic [DATA_W-1:0] window_col [NUM_ROWS-1:0][KERNEL_SIZE-1:0];

    logic [COL_W-1:0]  wr_ptr;
    logic [COL_W-1:0]  col_cnt;
    logic [ROW_W-1:0]  row_cnt;

    // =========================================================================
    // Handshake / validity
    // =========================================================================
    logic enough_rows, enough_cols, window_valid;
    logic input_accept, output_handshake;
    logic last_input_pixel;
    logic frame_end_input;

    assign enough_rows       = (row_cnt >= KERNEL_SIZE - 1);
    assign enough_cols       = (col_cnt >= KERNEL_SIZE - 1);
    assign window_valid      = enough_rows && enough_cols;

    assign input_accept      = s_tvalid && s_tready;
    assign output_handshake  = m_tvalid && m_tready;

    assign last_input_pixel  = (row_cnt == IMG_HEIGHT - 1) &&
                               (col_cnt == IMG_WIDTH  - 1);

    assign frame_end_input   = input_accept && last_input_pixel;

    // Accept input if:
    //  - no output is currently pending, or
    //  - downstream is ready, or
    //  - current input does not produce a valid output window
    assign s_tready = !m_tvalid || m_tready || !window_valid;

    // =========================================================================
    // Read current row-buffer outputs at wr_ptr
    // =========================================================================
    genvar rb;
    generate
        for (rb = 0; rb < NUM_BUFFERS; rb++) begin : gen_row_out
            assign row_out[rb] = row_buffer[rb][wr_ptr];
        end
    endgenerate

    // =========================================================================
    // Build the NEXT packed window (after shifting in current input pixel)
    // This is the key fix: output must reflect the window INCLUDING s_tdata,
    // not the previous cycle's window_col contents.
    // =========================================================================
    logic [DATA_W-1:0] next_right_col [NUM_ROWS-1:0];
    logic [KERNEL_SIZE*KERNEL_SIZE*DATA_W-1:0] packed_window_next;

    integer r, c;
    always_comb begin
        packed_window_next = '0;

        for (r = 0; r < NUM_BUFFERS; r++) begin
            next_right_col[r] = row_out[r];
        end
        next_right_col[NUM_ROWS-1] = s_tdata;

        for (r = 0; r < NUM_ROWS; r++) begin
            for (c = 0; c < KERNEL_SIZE; c++) begin
                if (c == KERNEL_SIZE - 1)
                    packed_window_next[(r*KERNEL_SIZE + c)*DATA_W +: DATA_W] = next_right_col[r];
                else
                    packed_window_next[(r*KERNEL_SIZE + c)*DATA_W +: DATA_W] = window_col[r][c+1];
            end
        end
    end

    // =========================================================================
    // Row buffer update
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            for (int k = 0; k < NUM_BUFFERS; k++) begin
                for (int x = 0; x < IMG_WIDTH; x++) begin
                    row_buffer[k][x] <= '0;
                end
            end
        end else if (input_accept) begin
            if (frame_end_input) begin
                // Clear state for the next frame after accepting the last pixel
                wr_ptr <= '0;
                for (int k = 0; k < NUM_BUFFERS; k++) begin
                    for (int x = 0; x < IMG_WIDTH; x++) begin
                        row_buffer[k][x] <= '0;
                    end
                end
            end else begin
                // Newest buffer gets current pixel
                row_buffer[NUM_BUFFERS-1][wr_ptr] <= s_tdata;

                // Older buffers get data from newer buffers
                for (int k = 0; k < NUM_BUFFERS - 1; k++) begin
                    row_buffer[k][wr_ptr] <= row_out[k+1];
                end

                if (wr_ptr == IMG_WIDTH - 1)
                    wr_ptr <= '0;
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    // =========================================================================
    // Column window update
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int rr = 0; rr < NUM_ROWS; rr++) begin
                for (int cc = 0; cc < KERNEL_SIZE; cc++) begin
                    window_col[rr][cc] <= '0;
                end
            end
        end else if (input_accept) begin
            if (frame_end_input) begin
                // Clear for next frame
                for (int rr = 0; rr < NUM_ROWS; rr++) begin
                    for (int cc = 0; cc < KERNEL_SIZE; cc++) begin
                        window_col[rr][cc] <= '0;
                    end
                end
            end else begin
                // Shift left
                for (int rr = 0; rr < NUM_ROWS; rr++) begin
                    for (int cc = 0; cc < KERNEL_SIZE - 1; cc++) begin
                        window_col[rr][cc] <= window_col[rr][cc+1];
                    end
                end

                // Insert newest column
                for (int rr = 0; rr < NUM_BUFFERS; rr++) begin
                    window_col[rr][KERNEL_SIZE-1] <= row_out[rr];
                end
                window_col[NUM_ROWS-1][KERNEL_SIZE-1] <= s_tdata;
            end
        end
    end

    // =========================================================================
    // Row / column counters
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= '0;
            row_cnt <= '0;
        end else if (input_accept) begin
            if (last_input_pixel) begin
                col_cnt <= '0;
                row_cnt <= '0;
            end else if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= '0;
                row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    // =========================================================================
    // Output AXI-Stream register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tdata  <= '0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end else begin
            // Clear after handshake if no replacement output is generated
            if (output_handshake) begin
                m_tvalid <= 1'b0;
                m_tlast  <= 1'b0;
            end

            // Register a new valid window from the CURRENT accepted input
            if (input_accept && window_valid) begin
                m_tdata  <= packed_window_next;
                m_tvalid <= 1'b1;
                m_tlast  <= last_input_pixel;
            end
        end
    end

endmodule

