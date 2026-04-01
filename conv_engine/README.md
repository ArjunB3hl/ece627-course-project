# Convolution Engine (MAC Unit)

## Description

The Convolution Engine is the third stage of the streaming image convolution accelerator pipeline. It receives a `KERNEL_SIZE × KERNEL_SIZE` pixel window from the Line Buffer over AXI4-Stream and performs a multiply-accumulate (MAC) operation using programmable signed kernel coefficients. The module supports multiple built-in filter presets (Sobel-X, Sobel-Y, Gaussian Blur, Sharpen) as well as custom coefficient loading via a dedicated AXI4-Stream configuration channel.

## Functionality

- Performs `KERNEL_SIZE²` signed multiplications and accumulates the results into a single sum.
- Two-stage internal pipeline:
  - **Stage 1 (Multiply):** Each unsigned pixel is sign-extended and multiplied by its corresponding signed kernel coefficient.
  - **Stage 2 (Accumulate):** A combinational adder tree sums all products with sign extension to prevent overflow.
- Programmable kernel coefficients loaded at runtime via a dedicated config AXI4-Stream channel.
- Built-in preset filter modes for 3×3 kernels:
  - Mode 0: Custom (user-loaded coefficients)
  - Mode 1: Sobel-X (vertical edge detection)
  - Mode 2: Sobel-Y (horizontal edge detection)
  - Mode 3: Gaussian Blur (3×3 approximation, coefficients sum to 16)
  - Mode 4: Sharpen
- Full AXI4-Stream backpressure support on all interfaces.
- Output bitwidth is automatically computed as `DATA_W + COEFF_W + ceil(log2(KERNEL_SIZE²))` to guarantee no overflow for any kernel size.



## Interfaces

### Parameters

| Parameter     | Default | Description                                          |
|---------------|---------|------------------------------------------------------|
| `KERNEL_SIZE` | 3       | Convolution kernel dimension (3, 5, 7…)              |
| `DATA_W`      | 8       | Input pixel bitwidth (unsigned)                      |
| `COEFF_W`     | 8       | Kernel coefficient bitwidth (signed)                 |
| `RESULT_W`    | auto    | Output bitwidth = DATA_W + COEFF_W + clog2(K²)      |

### Input Ports (Pixel Window)

| Port       | Width                   | Direction | Description                      |
|------------|-------------------------|-----------|----------------------------------|
| `clk`      | 1                       | Input     | System clock                     |
| `rst_n`    | 1                       | Input     | Active-low asynchronous reset    |
| `s_tdata`  | KERNEL_SIZE² × DATA_W   | Input     | Packed pixel window (AXI-Stream) |
| `s_tvalid` | 1                       | Input     | Input data valid                 |
| `s_tready` | 1                       | Output    | Input ready                      |
| `s_tlast`  | 1                       | Input     | Input last signal                |

### Config Ports (Kernel Coefficients)

| Port        | Width | Direction | Description                          |
|-------------|-------|-----------|--------------------------------------|
| `cfg_tdata` | 32    | Input     | Coefficient or mode value            |
| `cfg_tvalid`| 1     | Input     | Config data valid                    |
| `cfg_tready`| 1     | Output    | Config ready                         |
| `cfg_tlast` | 1     | Input     | Asserted on final config beat (mode) |

Config protocol: Send `KERNEL_SIZE²` coefficient beats, then 1 mode beat with `cfg_tlast` asserted.

### Output Ports

| Port       | Width     | Direction | Description                 |
|------------|-----------|-----------|-----------------------------|
| `m_tdata`  | RESULT_W  | Output    | Signed MAC result           |
| `m_tvalid` | 1         | Output    | Output data valid           |
| `m_tready` | 1         | Input     | Output ready                |
| `m_tlast`  | 1         | Output    | Last result of frame        |

## Testbench

The testbench verifies correctness with:

1. **Identity Kernel** — Only center coefficient = 1, verifies output equals center pixel value.
2. **Default Sobel-X** — Applies Sobel-X to vertical and horizontal edge patterns, verifies expected gradient responses.
3. **Custom Kernel Loading** — Loads an all-ones kernel via config stream, verifies output = sum of all pixels.
4. **Preset Mode Switching** — Loads Sobel-Y via mode select, verifies correct response to a horizontal edge.
5. **Backpressure** — Random downstream stalls (~67% ready), verifies no data corruption over 20 windows.
6. **Uniform Window** — All pixels = 100 and 255, verifies output = K² × pixel_value.

## Resource Utilization and Timing

### VTR (Verilog-to-Routing)

Synthesis and place-and-route performed using VTR with Yosys + Parmys frontend.

**Target Architecture:** `k6_frac_N10_40nm` (6-input fracturable LUT, 40nm technology)

| Configuration | CLBs | Fmax (MHz) | Status |
|---------------|------|------------|--------|
| K3_W16_H16    | 144  | 102.88     | OK     |
| K5_W16_H16    | 324  | 53.10      | OK     |
| K7_W16_H16    | 625  | 35.86      | OK     |

### Vivado (Xilinx)

| LUTs | FFs  | IOs | WNS (ns) |
|------|------|-----|----------|
| ~700 | ~450 | ~52 | 6.474    |

### Analysis

**VTR:**
- **Dominates system area:** ~70% of total CLBs at K=3
- **CLBs scale as O(K²):** 9 multipliers (K=3) → 25 (K=5) → 49 (K=7)
- **Critical timing path:** Adder tree depth limits system Fmax
  - K=3: 102.88 MHz
  - K=5: 53.10 MHz (↓48% from K=3)
  - K=7: 35.86 MHz (↓65% from K=3)
- The combinational adder tree becomes the bottleneck for larger kernels; further pipelining could improve Fmax at the cost of latency

**Vivado:**
- Moderate LUT usage (~700) for K² multipliers and adder tree
- Lower FF count (~450) as pipeline registers are minimal
- Positive WNS (6.474 ns) indicates comfortable timing margin on Xilinx fabric
