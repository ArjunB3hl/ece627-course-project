# Line Buffer (3×3 Window Generator)

## Description

The Line Buffer is the second stage of the streaming image convolution accelerator pipeline. It buffers `KERNEL_SIZE - 1` complete rows of the input image using shift registers and produces a sliding `KERNEL_SIZE × KERNEL_SIZE` pixel window on its output AXI4-Stream interface. This window is consumed by the downstream Convolution Engine for multiply-accumulate computation.

The module implements "valid" convolution — no zero-padding is applied at image borders. The first valid output window is produced after `KERNEL_SIZE - 1` full rows and `KERNEL_SIZE - 1` columns have been received. For a 3×3 kernel on a 640×480 image, this produces 638×478 = 304,964 output windows per frame.

## Functionality

- Buffers `KERNEL_SIZE - 1` rows using shift-register-based row buffers, each `IMG_WIDTH` deep.
- Maintains a `KERNEL_SIZE × KERNEL_SIZE` column window register that shifts horizontally as new pixels arrive.
- Computes the next-state window combinationally to avoid one-cycle-behind latency from non-blocking assignments.
- Outputs the packed window only when both the row and column conditions for a valid window are met.
- Handles AXI4-Stream backpressure on both input and output interfaces.
- Asserts `m_tlast` on the last valid output window of the frame.
- Fully parameterizable: changing `KERNEL_SIZE` automatically adjusts the number of row buffers and window size.


## Interfaces

### Parameters

| Parameter     | Default | Description                              |
|---------------|---------|------------------------------------------|
| `IMG_WIDTH`   | 640     | Number of pixels per row (columns)       |
| `IMG_HEIGHT`  | 480     | Number of rows in the image              |
| `KERNEL_SIZE` | 3       | Convolution kernel dimension (3, 5, 7…)  |
| `DATA_W`      | 8       | Pixel bitwidth                           |

### Input Ports

| Port       | Width      | Direction | Description                    |
|------------|------------|-----------|--------------------------------|
| `clk`      | 1          | Input     | System clock                   |
| `rst_n`    | 1          | Input     | Active-low asynchronous reset  |
| `s_tdata`  | DATA_W     | Input     | Input pixel data (AXI-Stream)  |
| `s_tvalid` | 1          | Input     | Input data valid               |
| `s_tready` | 1          | Output    | Input ready                    |
| `s_tlast`  | 1          | Input     | Input last signal              |

### Output Ports

| Port       | Width                              | Direction | Description                          |
|------------|------------------------------------|-----------|--------------------------------------|
| `m_tdata`  | KERNEL_SIZE × KERNEL_SIZE × DATA_W | Output    | Packed pixel window (AXI-Stream)     |
| `m_tvalid` | 1                                  | Output    | Output data valid                    |
| `m_tready` | 1                                  | Input     | Output ready                         |
| `m_tlast`  | 1                                  | Output    | Asserted on last window of frame     |

### Window Packing Format

The output window is packed as a flat bit vector:

```
m_tdata[(row * KERNEL_SIZE + col) * DATA_W +: DATA_W] = window[row][col]
```

Where `row = 0` is the oldest (top) row and `col = 0` is the leftmost (oldest) column.

## Testbench

The testbench uses a small 8×6 image where each pixel value equals `row * IMG_WIDTH + col` for easy verification:

1. **Basic Window Correctness** — Sends full frame, verifies all 24 output windows (6×4) contain the expected 3×3 neighborhoods.
2. **Backpressure** — Random downstream stalls (~75% ready), verifies no window corruption.
3. **Output Count & TLAST** — Verifies exactly 24 windows are produced and `TLAST` is asserted on the last one.
4. **Multiple Frames** — Sends 2 consecutive frames, verifies correct windows in both.
5. **Visual Inspection** — Prints the first 4 windows for manual verification against expected values.

