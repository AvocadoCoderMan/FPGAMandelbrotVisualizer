// C++ reference ("golden model") for the Mandelbrot pixels, compared with what mandelbrot.v
// pushes into the write FIFO. Bit-exact copy of the fixed-point arithmetic in the Verilog.
//
//   ./obj/Vtb_compute [number_of_pixels_to_check]      (default 200000)
#include "Vtb_compute.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static const int  W = 1280, H = 720, NPIX = W * H;
static const int  F = 28;                       // fractional bits, as in mandelbrot.v

// Number of iterations for one pixel, in Q4.28 fixed point like the hardware.
static int iterations_fixed(int32_t cx, int32_t cy, int max_iter) {
    int32_t zx = 0, zy = 0;
    int iter = 0;
    while (true) {
        int64_t p_xx = (int64_t)zx * zx;        // 64-bit products (scale 2^56)
        int64_t p_yy = (int64_t)zy * zy;
        int64_t p_xy = (int64_t)zx * zy;
        // back to scale 2^28: shift right 28, keep the low 32 bits (wraps like the hardware)
        int32_t xx = (int32_t)(p_xx >> F), yy = (int32_t)(p_yy >> F), xy = (int32_t)(p_xy >> F);
        int32_t nzx = (int32_t)((uint32_t)xx - (uint32_t)yy + (uint32_t)cx);   //  x^2 - y^2 + cx
        int32_t nzy = (int32_t)(((uint32_t)xy << 1) + (uint32_t)cy);           //  2xy + cy
        int64_t mag = (p_xx >> F) + (p_yy >> F);                               //  |z|^2, not wrapped
        if (mag > ((int64_t)4 << F) || iter == max_iter) break;                // escaped, or gave up
        zx = nzx; zy = nzy; iter++;
    }
    return iter;
}

// Same thing with ordinary doubles. Only used to show that the fixed-point version is a sane Mandelbrot.
static int iterations_double(int32_t cx_fixed, int32_t cy_fixed, int max_iter) {
    double cx = cx_fixed / (double)(1 << F), cy = cy_fixed / (double)(1 << F), zx = 0, zy = 0;
    int iter = 0;
    while (zx * zx + zy * zy <= 4.0 && iter < max_iter) {
        double t = zx * zx - zy * zy + cx;
        zy = 2 * zx * zy + cy;  zx = t;  iter++;
    }
    return iter;
}

// what the hardware writes for a given iteration count
static uint8_t to_pixel(int iter, int max_iter) { return iter == max_iter ? 0 : (uint8_t)((iter & 63) << 2); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    long limit = (argc > 1) ? atol(argv[1]) : 200000;

    Vtb_compute* top = new Vtb_compute;
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);              // 99 = every level of the hierarchy
    tfp->open("wave.vcd");
    uint64_t sim_time = 0;            // own time, one tick per half clock
    const long TRACE_FROM = 0, TRACE_TO = 3000;   // window of clock cycles to record
    long cycle = 0;
    top->clk = 0; top->eval();

    const int32_t CX = top->CX, CY = top->CY, STEP0 = top->STEP0, MIN_STEP = top->MIN_STEP;
    const int ZOOM_SHIFT = top->ZOOM_SHIFT;

    // state of the zoom, per frame
    int32_t step = STEP0;
    int max_iter = 250;

    long n = 0, bad = 0, double_diff = 0;        // pixels checked / wrong / different from the double model
    while (n < limit) {
        // looking at signals BEFORE the clock edge
        bool    en  = top->write_en;
        uint8_t got = top->write_data;
        int     gx  = top->calc_x, gy = top->calc_y;

        top->clk = 1; top->eval();
        if (cycle >= TRACE_FROM && cycle < TRACE_TO) tfp->dump(sim_time);
        sim_time++;
        top->clk = 0; top->eval();
        if (cycle >= TRACE_FROM && cycle < TRACE_TO) tfp->dump(sim_time);
        sim_time++;
        cycle++;

        if (!en) continue;                       // no pixel written in this clock

        // which pixel is this? n-th pixel overall -> frame, x, y
        int  p = n % NPIX, x = p % W, y = p / W;
        if (n > 0 && p == 0) {                   // a new frame starts: zoom one notch, like the design
            bool at_min = (step <= MIN_STEP);
            step     = at_min ? STEP0 : step - (step >> ZOOM_SHIFT);
            max_iter = at_min ? 250 : (max_iter < 1000 ? max_iter + 12 : max_iter);
        }
        // coordinates of this pixel: corner + pixel * step (32-bit wrap like the hardware)
        int32_t cx = (int32_t)((int64_t)CX - 640LL * step + (int64_t)x * step);
        int32_t cy = (int32_t)((int64_t)CY + 360LL * step - (int64_t)y * step);

        int     it  = iterations_fixed(cx, cy, max_iter);
        uint8_t exp = to_pixel(it, max_iter);
        if (it != iterations_double(cx, cy, max_iter)) double_diff++;

        if (got != exp || gx != x || gy != y) {
            if (bad < 10) printf("MISMATCH pixel %ld (x=%d y=%d): hardware %d, expected %d   [design says x=%d y=%d]\n",
                                 n, x, y, got, exp, gx, gy);
            bad++;
        }
        n++;
    }

    printf("checked %ld pixels (%.2f frames), %ld wrong\n", n, n / (double)NPIX, bad);
    printf("fixed-point model vs. plain double model: %ld of %ld pixels differ (%.3f %%)\n",
           double_diff, n, 100.0 * double_diff / n);
    printf(bad ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    tfp->close();
    top->final();
    delete top;
    return bad ? 1 : 0;
}
