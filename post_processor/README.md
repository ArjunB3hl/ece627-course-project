# Post-Processor (Output Stage)

## Description

The Post-Processor is the fourth and final stage of the streaming image convolution accelerator pipeline. It receives the signed MAC result from the Convolution Engine over AXI4-Stream and produces an 8-bit output pixel through one of three configurable post-processing modes: absolute-value clamping, binary thresholding, or right-shift normalization.

## Functionality

- **Mode 0 — Clamp:** Computes the absolute value of the signed input, then saturates to [0, 255]. Used for edge detection filters (e.g., Sobel) where both positive and negative gradients are meaningful.
- **Mode 1 — Threshold:** Compares |input| against a configurable threshold. Outputs 255 if above, 0 if at or below. Produces clean binary edge maps from gradient data.
- **Mode 2 — Shift (Normalization):** Performs an arithmetic right-shift on the signed input by a configurable amount, then clamps to [0, 255]. Used for kernels whose coefficients sum to a power of 2 (e.g., Gaussian blur with sum = 16 requires shift = 4).
- Full AXI4-Stream backpressure support.
- `TLAST` propagates from input to output to mark frame boundaries.
- All post-processing logic is combinational; the output is registered for clean AXI4-Stream timing.

## Interfaces

### Parameters

| Parameter     | Default | Description                                          |
|---------------|---------|------------------------------------------------------|
| `KERNEL_SIZE` | 3       | Convolution kernel dimension (affects RESULT_W)      |
| `DATA_W`      | 8       | Output pixel bitwidth                                |
| `COEFF_W`     | 8       | Coefficient bitwidth from convolution engine         |
| `RESULT_W`    | auto    | Input bitwidth = DATA_W + COEFF_W + clog2(K²)       |

### Input Ports

| Port       | Width     | Direction | Description                      |
|------------|-----------|-----------|----------------------------------|
| `clk`      | 1         | Input     | System clock                     |
| `rst_n`    | 1         | Input     | Active-low asynchronous reset    |
| `s_tdata`  | RESULT_W  | Input     | Signed MAC result (AXI-Stream)   |
| `s_tvalid` | 1         | Input     | Input data valid                 |
| `s_tready` | 1         | Output    | Input ready                      |
| `s_tlast`  | 1         | Input     | Input last signal                |

### Configuration Ports

| Port             | Width           | Direction | Description                              |
|------------------|-----------------|-----------|------------------------------------------|
| `i_pp_mode`      | 2               | Input     | 0 = Clamp, 1 = Threshold, 2 = Shift     |
| `i_threshold`    | DATA_W          | Input     | Binary threshold value (mode 1)          |
| `i_shift_amount` | clog2(RESULT_W) | Input     | Right-shift amount for normalization     |

### Output Ports

| Port       | Width   | Direction | Description                      |
|------------|---------|-----------|----------------------------------|
| `m_tdata`  | DATA_W  | Output    | 8-bit output pixel (AXI-Stream)  |
| `m_tvalid` | 1       | Output    | Output data valid                |
| `m_tready` | 1       | Input     | Output ready                     |
| `m_tlast`  | 1       | Output    | Last pixel of frame              |

## Testbench

The testbench verifies all three modes:

1. **Clamp Mode** — Tests positive in-range (100→100), negative (−50→50), positive overflow (400→255), negative overflow (−500→255), boundary values (0, 1, 255, −1).
2. **Threshold Mode** — Tests above threshold (150 vs 100→255), below (50→0), at threshold (100→0), negative values, and dynamic threshold changes.
3. **Shift Mode** — Tests Gaussian normalization (1600>>4=100, 3200>>4=200), overflow after shift (5000>>4→255), negative after shift (→0), shift=0 pass-through.
4. **Edge Cases** — Maximum positive/negative representable values, −1, +256.
5. **Backpressure** — Random downstream stalls over 30 test values with mixed positive/negative/overflow inputs.
6. **TLAST Propagation** — Verifies `tlast` passes through correctly and resets for the next frame.

