# AXI4-Stream Image Convolution Pipeline — System Integration

## Overview

This repository implements a fully pipelined, parametric 2D image convolution accelerator described in SystemVerilog. The top-level module (`top.sv`) instantiates and connects four sub-modules in a linear datapath, all communicating over the AXI4-Stream handshake protocol (`valid` / `ready` / `last`).



## Functionality

The pipeline computes a 2D discrete convolution of a greyscale image with a programmable kernel:

```
output[r][c] = post_proc( Σ  image[r+kr][c+kc] × kernel[kr][kc] )
```

- **Input:** raw 8-bit pixels streamed row-by-row over AXI-Stream.
- **Kernel loading:** `KERNEL_SIZE²` signed coefficient beats followed by one mode-select beat over the `cfg` AXI-Stream port. Built-in presets (Sobel-X, Sobel-Y, Gaussian, Sharpen) can be selected without restreaming coefficients.
- **Output:** `(IMG_WIDTH − K + 1) × (IMG_HEIGHT − K + 1)` processed 8-bit pixels, streamed with AXI-Stream handshake and `tlast` on the final pixel.
- **Post-processing modes:**

| `i_pp_mode` | Mode | Description |
|---|---|---|
| `2'b00` | Clamp | `\|MAC\|` clamped to `[0, 255]` |
| `2'b01` | Threshold | `result > threshold → 255`, else `0` |
| `2'b10` | Shift | Arithmetic right-shift by `i_shift_amount`, then clamp (e.g. Gaussian ÷16) |

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `KERNEL_SIZE` | `3` | Kernel dimension (3 → 3×3, 5 → 5×5, 7 → 7×7) |
| `IMG_WIDTH` | `8` | Input image width in pixels |
| `IMG_HEIGHT` | `6` | Input image height in pixels |
| `DATA_W` | `8` | Pixel bit-width |
| `COEFF_W` | `8` | Coefficient bit-width (signed) |

Internally derived:
- `RESULT_W = DATA_W + COEFF_W + ⌈log₂(K²)⌉` — full-precision MAC width (20 bits for K=3)
- `WINDOW_W = K² × DATA_W` — packed window bus width (72 bits for K=3)

---

## Port Interface

### Clock and Reset

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low synchronous reset |

### Pixel Input Stream (AXI4-Stream Slave)

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_tdata` | in | `DATA_W` | Pixel value |
| `s_tvalid` | in | 1 | Producer has valid data |
| `s_tready` | out | 1 | Pipeline ready to accept |
| `s_tlast` | in | 1 | Last pixel of input frame |

### Kernel Config Stream (AXI4-Stream Slave)

| Port | Dir | Width | Description |
|---|---|---|---|
| `cfg_tdata` | in | 32 | Coefficient (bits `COEFF_W-1:0`) or mode (bits `2:0`) |
| `cfg_tvalid` | in | 1 | Valid config beat |
| `cfg_tready` | out | 1 | Ready to accept |
| `cfg_tlast` | in | 1 | Must be high on the final mode beat |

### Post-Processor Configuration (Static Registers)

| Port | Dir | Width | Description |
|---|---|---|---|
| `i_pp_mode` | in | 2 | 0=clamp, 1=threshold, 2=shift |
| `i_threshold` | in | `DATA_W` | Threshold value for mode 1 |
| `i_shift_amount` | in | 5 | Right-shift count for mode 2 |

### Pixel Output Stream (AXI4-Stream Master)

| Port | Dir | Width | Description |
|---|---|---|---|
| `m_tdata` | out | `DATA_W` | Processed pixel |
| `m_tvalid` | out | 1 | Output valid |
| `m_tready` | in | 1 | Downstream ready |
| `m_tlast` | out | 1 | Last pixel of output frame |

### Frame Metadata

| Port | Dir | Width | Description |
|---|---|---|---|
| `o_col` | out | `⌈log₂(W)⌉` | Current column index |
| `o_row` | out | `⌈log₂(H)⌉` | Current row index |
| `o_frame_start` | out | 1 | Pulses on first input pixel |
| `o_frame_done` | out | 1 | Pulses on last input pixel |

---

## Resource Utilization & Timing Results

### VTR (Verilog-to-Routing)

- **Tool flow:** Yosys 0.55 (slang frontend + parmys plugin) → ABC → VPR pack/place/route
- **Target architecture:** `k6_frac_N10_40nm` — 6-input fracturable LUT, 40 nm technology node
- **Synthesis command:** `hierarchy -top top -G KERNEL_SIZE=K -G IMG_WIDTH=W -G IMG_HEIGHT=H`

#### Kernel Size Sweep — IMG fixed at 16×16

| Config | Taps (K²) | CLBs | Fmax (MHz) |
|---|---|---|---|
| K=3, 16×16 | 9 | 196 | 98.1 |
| K=5, 16×16 | 25 | 441 | 53.1 |
| K=7, 16×16 | 49 | 784 | 37.5 |

CLBs scale approximately as K² because `conv_engine` instantiates one multiplier per tap. Fmax drops as K grows because the adder tree in `conv_engine` deepens, increasing the combinational delay on the critical path.

#### Image Resolution Sweep — K fixed at 3

| Config | Image Pixels | CLBs | Fmax (MHz) |
|---|---|---|---|
| K=3, 8×8 | 64 | 169 | 104.6 |
| K=3, 16×16 | 256 | 196 | 98.1 |
| K=3, 32×32 | 1024 | 225 | 107.7 |

CLBs grow linearly with image width because `line_buffer` holds `(K−1) × IMG_WIDTH` registers to buffer partial rows. The critical path is unaffected by image size so Fmax remains approximately constant.

### Vivado (Xilinx)

| LUTs | FFs | IOs | WNS (ns) |
|------|-----|-----|----------|
| 913  | 535 | 56  | 5.149    |


## Integration Testing

End-to-end testing is performed by `top_tb.sv`, which instantiates five configurations concurrently and applies four tests to each.

### Configurations Tested

| Instance | K | IMG | Output windows |
|---|---|---|---|
| `cfg_k3_s` | 3 | 8×6 | 6×4 = 24 |
| `cfg_k5` | 5 | 10×8 | 6×4 = 24 |
| `cfg_k7` | 7 | 12×10 | 6×4 = 24 |
| `cfg_k3_m` | 3 | 16×12 | 14×10 = 140 |
| `cfg_k3_l` | 3 | 20×16 | 18×14 = 252 |

### Tests Applied

The testbench applies 4 tests to each configuration, verifying end-to-end correctness across the full pipeline (pixel_streamer → line_buffer → conv_engine → post_processor).

#### Test 1: Identity Kernel
- **Kernel:** Center coefficient = 1, all others = 0
- **Post-processor:** Clamp mode
- **Purpose:** Baseline sanity check — verifies data flows correctly through all 4 pipeline stages
- **Pass condition:** Each output equals the center pixel of its corresponding window
- **Why this test:** Simplest possible convolution; if this fails, something fundamental is broken in the datapath

#### Test 2: All-Ones Kernel + Clamp
- **Kernel:** All K² coefficients = 1
- **Post-processor:** Clamp mode (saturate to [0, 255])
- **Purpose:** Tests full multiply-accumulate operation and overflow handling
- **Pass condition:** `output[i] = min(sum of K² window pixels, 255)`
- **Why this test:** Exercises the MAC arithmetic with realistic sums that can exceed 255, validating the post-processor's saturation logic

#### Test 3: Backpressure Handling
- **Kernel:** Identity (center = 1)
- **Consumer:** Randomly asserts `m_tready` ~50% of cycles
- **Purpose:** Tests that the entire pipeline handles downstream stalls correctly
- **Pass condition:** All outputs match expected values despite random stalls
- **Why this test:** In real systems, consumers may not always be ready. This verifies:
  - Pipeline stages correctly hold data when stalled
  - No pixels are lost, duplicated, or corrupted
  - Backpressure propagates correctly through all 4 modules

#### Test 4: TLAST Propagation
- **Kernel:** Identity (center = 1)
- **Purpose:** Verifies frame boundary signaling through the pipeline
- **Pass condition:** `m_tlast` asserted on exactly the last output pixel (e.g., pixel #24 for 6×4 output grid)
- **Why this test:** TLAST must propagate correctly through all stages:
  - pixel_streamer generates TLAST on last input pixel
  - line_buffer forwards TLAST on last valid window
  - conv_engine passes TLAST through its 2-stage pipeline
  - post_processor outputs TLAST on final processed result

