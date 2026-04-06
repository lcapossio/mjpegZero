// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// tb_verilator.cpp — Verilator C++ testbench for code coverage
// ============================================================================
// Exercises the mjpegZero encoder pipeline with comprehensive stimulus:
//   - AXI-Lite register reads + writes (all 6 registers)
//   - Restart marker insertion
//   - Multi-frame operation (2 frames)
//   - Soft reset between frames
//   - W1C status bit clearing
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "Vmjpegzero_enc_top.h"
#include "verilated.h"
#include "verilated_cov.h"

// ---------------------------------------------------------------------------
// Constants (must match DUT parameters set at Verilator compile time)
// ---------------------------------------------------------------------------
static constexpr int IMG_WIDTH  = 64;
static constexpr int IMG_HEIGHT = 8;
static constexpr int NUM_PIXELS = IMG_WIDTH * IMG_HEIGHT;
static constexpr int CLK_HALF   = 5; // 100 MHz

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
static vluint64_t sim_time = 0;

double sc_time_stamp() { return static_cast<double>(sim_time); }

// ---------------------------------------------------------------------------
// Helper: tick one clock edge
// ---------------------------------------------------------------------------
static void tick(Vmjpegzero_enc_top *dut) {
    dut->clk = 0; dut->eval(); sim_time += CLK_HALF;
    dut->clk = 1; dut->eval(); sim_time += CLK_HALF;
}

// Forward declaration
struct JpegCapture;

// ---------------------------------------------------------------------------
// AXI-Lite write (blocking, optionally captures JPEG output during ticks)
// ---------------------------------------------------------------------------
static void axi_write(Vmjpegzero_enc_top *dut, uint8_t addr, uint32_t data,
                       JpegCapture *cap = nullptr);

// ---------------------------------------------------------------------------
// AXI-Lite read (blocking, optionally captures JPEG output during ticks)
// ---------------------------------------------------------------------------
static uint32_t axi_read(Vmjpegzero_enc_top *dut, uint8_t addr,
                          JpegCapture *cap = nullptr);

// ---------------------------------------------------------------------------
// Load hex test vectors
// ---------------------------------------------------------------------------
static bool load_hex(const char *path, std::vector<uint16_t> &out) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "ERROR: cannot open %s\n", path); return false; }
    char line[64];
    while (fgets(line, sizeof(line), f)) {
        unsigned val;
        if (sscanf(line, "%x", &val) == 1)
            out.push_back(static_cast<uint16_t>(val));
    }
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// Capture output byte helper
// ---------------------------------------------------------------------------
struct JpegCapture {
    FILE    *fout;
    int      output_bytes;
    bool     saw_soi, saw_eoi;
    uint8_t  prev_byte;

    JpegCapture() : fout(nullptr), output_bytes(0),
                    saw_soi(false), saw_eoi(false), prev_byte(0) {}

    void open(const char *path) {
        fout = fopen(path, "wb");
        output_bytes = 0; saw_soi = false; saw_eoi = false; prev_byte = 0;
    }
    void close() { if (fout) { fclose(fout); fout = nullptr; } }

    void sample(Vmjpegzero_enc_top *dut) {
        if (dut->m_axis_jpg_tvalid) {
            uint8_t b = dut->m_axis_jpg_tdata;
            if (fout) fputc(b, fout);
            if (output_bytes == 1 && prev_byte == 0xFF && b == 0xD8) saw_soi = true;
            if (output_bytes >  2 && prev_byte == 0xFF && b == 0xD9) saw_eoi = true;
            prev_byte = b;
            output_bytes++;
        }
    }
};

// ---------------------------------------------------------------------------
// AXI-Lite write implementation
// ---------------------------------------------------------------------------
static void axi_write(Vmjpegzero_enc_top *dut, uint8_t addr, uint32_t data,
                       JpegCapture *cap) {
    dut->s_axi_awaddr  = addr;
    dut->s_axi_awvalid = 1;
    dut->s_axi_wdata   = data;
    dut->s_axi_wstrb   = 0xF;
    dut->s_axi_wvalid  = 1;
    dut->s_axi_bready  = 1;

    for (int i = 0; i < 20; i++) {
        tick(dut);
        if (cap) cap->sample(dut);
        if (dut->s_axi_awready && dut->s_axi_wready) break;
    }
    dut->s_axi_awvalid = 0;
    dut->s_axi_wvalid  = 0;

    for (int i = 0; i < 20; i++) {
        tick(dut);
        if (cap) cap->sample(dut);
        if (dut->s_axi_bvalid) break;
    }
    dut->s_axi_bready = 0;
    tick(dut);
    if (cap) cap->sample(dut);
}

// ---------------------------------------------------------------------------
// AXI-Lite read implementation
// ---------------------------------------------------------------------------
static uint32_t axi_read(Vmjpegzero_enc_top *dut, uint8_t addr,
                          JpegCapture *cap) {
    dut->s_axi_araddr  = addr;
    dut->s_axi_arvalid = 1;
    dut->s_axi_rready  = 1;

    for (int i = 0; i < 20; i++) {
        tick(dut);
        if (cap) cap->sample(dut);
        if (dut->s_axi_arready) break;
    }
    dut->s_axi_arvalid = 0;

    for (int i = 0; i < 20; i++) {
        tick(dut);
        if (cap) cap->sample(dut);
        if (dut->s_axi_rvalid) break;
    }
    uint32_t val = dut->s_axi_rdata;
    dut->s_axi_rready = 0;
    tick(dut);
    if (cap) cap->sample(dut);
    return val;
}

// ---------------------------------------------------------------------------
// Feed one frame of pixels, capturing output along the way
// ---------------------------------------------------------------------------
static void feed_frame(Vmjpegzero_enc_top *dut, const std::vector<uint16_t> &yuyv,
                        JpegCapture &cap) {
    int pixel_idx = 0;
    for (int y = 0; y < IMG_HEIGHT; y++) {
        for (int x = 0; x < IMG_WIDTH; x++) {
            dut->s_axis_vid_tvalid = 1;
            dut->s_axis_vid_tuser  = (x == 0 && y == 0) ? 1 : 0;
            dut->s_axis_vid_tlast  = (x == IMG_WIDTH - 1) ? 1 : 0;
            dut->s_axis_vid_tdata  = yuyv[pixel_idx++];

            do {
                tick(dut);
                cap.sample(dut);
            } while (!dut->s_axis_vid_tready);
        }
    }
    dut->s_axis_vid_tvalid = 0;
    dut->s_axis_vid_tlast  = 0;
    dut->s_axis_vid_tuser  = 0;
}

// ---------------------------------------------------------------------------
// Flush pipeline until tlast or EOI
// ---------------------------------------------------------------------------
static void flush_pipeline(Vmjpegzero_enc_top *dut, JpegCapture &cap, int max_cycles = 500000) {
    for (int i = 0; i < max_cycles; i++) {
        tick(dut);
        cap.sample(dut);
        if ((dut->m_axis_jpg_tlast && dut->m_axis_jpg_tvalid) || cap.saw_eoi) {
            for (int j = 0; j < 100; j++) tick(dut);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Parse optional args
    std::string tv_path   = "test_vectors/yuyv_input.hex";
    std::string out_path  = "sim_output.jpg";
    std::string cov_path  = "coverage.dat";
    int         quality   = 95;

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "+tv=",  4)) tv_path  = argv[i] + 4;
        if (!strncmp(argv[i], "+out=", 5)) out_path = argv[i] + 5;
        if (!strncmp(argv[i], "+cov=", 5)) cov_path = argv[i] + 5;
        if (!strncmp(argv[i], "+q=",   3)) quality  = atoi(argv[i] + 3);
    }

    // Load test vectors
    std::vector<uint16_t> yuyv;
    if (!load_hex(tv_path.c_str(), yuyv)) return 1;
    if ((int)yuyv.size() < NUM_PIXELS) {
        fprintf(stderr, "ERROR: expected %d pixels, got %d\n", NUM_PIXELS, (int)yuyv.size());
        return 1;
    }

    auto *dut = new Vmjpegzero_enc_top;
    JpegCapture cap;
    cap.open(out_path.c_str());

    // -----------------------------------------------------------------------
    // Reset
    // -----------------------------------------------------------------------
    dut->rst_n             = 0;
    dut->clk               = 0;
    dut->s_axis_vid_tdata  = 0;
    dut->s_axis_vid_tvalid = 0;
    dut->s_axis_vid_tlast  = 0;
    dut->s_axis_vid_tuser  = 0;
    dut->s_axi_awaddr      = 0;
    dut->s_axi_awvalid     = 0;
    dut->s_axi_wdata       = 0;
    dut->s_axi_wstrb       = 0;
    dut->s_axi_wvalid      = 0;
    dut->s_axi_bready      = 0;
    dut->s_axi_araddr      = 0;
    dut->s_axi_arvalid     = 0;
    dut->s_axi_rready      = 0;

    for (int i = 0; i < 10; i++) tick(dut);
    dut->rst_n = 1;
    for (int i = 0; i < 5; i++) tick(dut);

    // -----------------------------------------------------------------------
    // Read all registers before enabling (initial state)
    // -----------------------------------------------------------------------
    printf("Reading initial register state...\n");
    uint32_t r_ctrl    = axi_read(dut, 0x00);
    uint32_t r_status  = axi_read(dut, 0x04);
    uint32_t r_fcnt    = axi_read(dut, 0x08);
    uint32_t r_quality = axi_read(dut, 0x0C);
    uint32_t r_restart = axi_read(dut, 0x10);
    uint32_t r_fsize   = axi_read(dut, 0x14);
    printf("  CTRL=0x%x STATUS=0x%x FCNT=%d Q=%d RST_INT=%d FSIZE=%d\n",
           r_ctrl, r_status, r_fcnt, r_quality, r_restart, r_fsize);

    // -----------------------------------------------------------------------
    // Configure: enable, quality, restart interval
    // -----------------------------------------------------------------------
    axi_write(dut, 0x00, 1);           // CTRL: enable
    axi_write(dut, 0x0C, quality);     // QUALITY
    axi_write(dut, 0x10, 2);           // RESTART: every 2 MCUs

    for (int i = 0; i < 600; i++) tick(dut); // Wait for Q-table update

    // Read status during idle (should show busy=0)
    r_status = axi_read(dut, 0x04);
    printf("  STATUS after config: 0x%x\n", r_status);

    // -----------------------------------------------------------------------
    // Frame 1: feed pixels with restart markers enabled
    // -----------------------------------------------------------------------
    printf("Frame 1: Feeding %d pixels (Q=%d, restart_interval=2)...\n", NUM_PIXELS, quality);
    feed_frame(dut, yuyv, cap);

    // Read status during encoding (should show busy=1)
    r_status = axi_read(dut, 0x04, &cap);
    printf("  STATUS during encode: 0x%x\n", r_status);

    flush_pipeline(dut, cap);
    cap.close();

    printf("  Frame 1: %d bytes, SOI=%d EOI=%d\n", cap.output_bytes, cap.saw_soi, cap.saw_eoi);

    // Read registers after frame 1
    r_status = axi_read(dut, 0x04);
    r_fcnt   = axi_read(dut, 0x08);
    r_fsize  = axi_read(dut, 0x14);
    printf("  STATUS=0x%x FCNT=%d FSIZE=%d\n", r_status, r_fcnt, r_fsize);

    // Clear frame_done via W1C write to STATUS register
    axi_write(dut, 0x04, r_status);  // W1C: write 1 to clear
    r_status = axi_read(dut, 0x04);
    printf("  STATUS after W1C: 0x%x\n", r_status);

    // -----------------------------------------------------------------------
    // Soft reset
    // -----------------------------------------------------------------------
    printf("Soft reset...\n");
    axi_write(dut, 0x00, 0x3);  // enable + soft_reset
    for (int i = 0; i < 10; i++) tick(dut);
    axi_write(dut, 0x00, 0x1);  // deassert soft_reset, keep enable
    for (int i = 0; i < 10; i++) tick(dut);

    // -----------------------------------------------------------------------
    // Frame 2: feed again after soft reset (no restart markers)
    // -----------------------------------------------------------------------
    axi_write(dut, 0x10, 0);           // Disable restart markers
    axi_write(dut, 0x0C, quality);     // Re-set quality
    for (int i = 0; i < 600; i++) tick(dut);

    printf("Frame 2: Feeding %d pixels (Q=%d, no restart)...\n", NUM_PIXELS, quality);

    // Open a dummy output for frame 2 (overwrite)
    std::string out2 = out_path + ".frame2.jpg";
    JpegCapture cap2;
    cap2.open(out2.c_str());
    feed_frame(dut, yuyv, cap2);
    flush_pipeline(dut, cap2);
    cap2.close();

    printf("  Frame 2: %d bytes, SOI=%d EOI=%d\n", cap2.output_bytes, cap2.saw_soi, cap2.saw_eoi);

    // Read frame count (should be 2 now)
    r_fcnt = axi_read(dut, 0x08);
    r_fsize = axi_read(dut, 0x14);
    printf("  FCNT=%d FSIZE=%d\n", r_fcnt, r_fsize);

    // -----------------------------------------------------------------------
    // Validation (based on frame 1, the primary output)
    // -----------------------------------------------------------------------
    printf("\n====================================\n");
    printf("VALIDATION\n");
    printf("====================================\n");
    printf("Frame 1 output bytes: %d\n", cap.output_bytes);

    int pass = 0, fail = 0;

    if (cap.saw_soi) { printf("PASS: SOI marker (FFD8) found\n"); pass++; }
    else             { printf("FAIL: SOI marker not found\n");     fail++; }

    if (cap.saw_eoi) { printf("PASS: EOI marker (FFD9) found\n"); pass++; }
    else             { printf("FAIL: EOI marker not found\n");     fail++; }

    if (cap.output_bytes > 100 && cap.output_bytes < 10000)
        { printf("PASS: Output size %d bytes is reasonable\n", cap.output_bytes); pass++; }
    else
        { printf("FAIL: Output size %d bytes unexpected\n", cap.output_bytes); fail++; }

    if (cap.output_bytes > 0) { printf("PASS: Encoder produced output\n"); pass++; }
    else                      { printf("FAIL: No output produced\n");      fail++; }

    // Frame 2 should also produce valid output
    if (cap2.saw_soi && cap2.saw_eoi && cap2.output_bytes > 100) {
        printf("PASS: Frame 2 also valid (%d bytes)\n", cap2.output_bytes);
        pass++;
    } else {
        printf("FAIL: Frame 2 invalid (bytes=%d soi=%d eoi=%d)\n",
               cap2.output_bytes, cap2.saw_soi, cap2.saw_eoi);
        fail++;
    }

    printf("------------------------------------\n");
    printf("Tests passed: %d\n", pass);
    printf("Tests failed: %d\n", fail);
    printf("====================================\n");

    if (fail == 0) printf("ALL TESTS PASSED\n");
    else           printf("SOME TESTS FAILED\n");

    // -----------------------------------------------------------------------
    // Coverage output (only when compiled with --coverage)
    // -----------------------------------------------------------------------
#if VM_COVERAGE
    VerilatedCov::write(cov_path.c_str());
    printf("Coverage data written to %s\n", cov_path.c_str());
#else
    (void)cov_path;
#endif

    dut->final();
    delete dut;

    return (fail > 0) ? 1 : 0;
}
