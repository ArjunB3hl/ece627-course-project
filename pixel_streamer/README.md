# Pixel Streamer (Input Controller)

## Description

The Pixel Streamer is the first stage of the streaming image convolution accelerator pipeline. It receives raw 8-bit grayscale pixels over an AXI4-Stream slave interface, tracks the current row and column position within the image frame, asserts `TLAST` at frame boundaries, and forwards pixels to the Line Buffer via an AXI4-Stream master interface. It also generates metadata signals (frame start, frame done) useful for downstream synchronization and debugging.

## Functionality

- Accepts a stream of 8-bit grayscale pixels via AXI4-Stream input.
- Maintains row and column counters that track the current pixel position within the frame.
- Asserts `m_tlast` on the last pixel of each frame (row = IMG_HEIGHT-1, col = IMG_WIDTH-1).
- Counters automatically reset at the start of a new frame after the last pixel is transferred.
- Handles downstream backpressure: holds output data stable when the downstream module is not ready.
- Fully parameterizable for any image resolution and kernel size.

## Interfaces

### Parameters

| Parameter     | Default | Description                              |
|---------------|---------|------------------------------------------|
| `IMG_WIDTH`   | 640     | Number of pixels per row (columns)       |
| `IMG_HEIGHT`  | 480     | Number of rows in the image              |
| `KERNEL_SIZE` | 3       | Convolution kernel dimension (3, 5, 7…)  |
| `DATA_W`      | 8       | Pixel bitwidth                           |

### Input Ports

| Port       | Width      | Direction | Description                          |
|------------|------------|-----------|--------------------------------------|
| `clk`      | 1          | Input     | System clock                         |
| `rst_n`    | 1          | Input     | Active-low asynchronous reset        |
| `s_tdata`  | DATA_W     | Input     | Input pixel data (AXI-Stream)        |
| `s_tvalid` | 1          | Input     | Input data valid (AXI-Stream)        |
| `s_tready` | 1          | Output    | Input ready (AXI-Stream)             |
| `s_tlast`  | 1          | Input     | Input last signal (AXI-Stream)       |

### Output Ports

| Port           | Width                  | Direction | Description                            |
|----------------|------------------------|-----------|----------------------------------------|
| `m_tdata`      | DATA_W                 | Output    | Output pixel data (AXI-Stream)         |
| `m_tvalid`     | 1                      | Output    | Output data valid (AXI-Stream)         |
| `m_tready`     | 1                      | Input     | Output ready (AXI-Stream)              |
| `m_tlast`      | 1                      | Output    | Asserted on last pixel of frame        |
| `o_col`        | clog2(IMG_WIDTH)       | Output    | Current column index                   |
| `o_row`        | clog2(IMG_HEIGHT)      | Output    | Current row index                      |
| `o_frame_start`| 1                      | Output    | Pulses high on first pixel of frame    |
| `o_frame_done` | 1                      | Output    | Pulses high when frame transfer done   |

### AXI4-Stream Handshake

A transfer occurs when `tvalid && tready` are both high on the rising clock edge. Backpressure is implemented as:

```systemverilog
assign s_tready = !m_tvalid || m_tready;
```

This means the module accepts new input when either it has no valid output or the downstream module has consumed the current output.

## Testbench

The testbench exercises the module with the following tests using a small 8×6 image:

1. **Normal Streaming** — Full frame with no backpressure, verifies all pixel values pass through correctly.
2. **Backpressure** — Downstream randomly deasserts `m_tready` (~75% ready), verifies no data loss.
3. **Input Stalling** — Producer randomly inserts idle cycles, verifies all pixels arrive correctly.
4. **TLAST and Counter Verification** — Verifies row/column counters match expected values for every pixel.
5. **Multiple Frames** — Sends 2 back-to-back frames, verifies counters reset correctly between frames.


