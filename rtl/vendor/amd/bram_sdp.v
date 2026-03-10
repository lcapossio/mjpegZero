// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Xilinx 7-series explicit RAMB36E1 Simple Dual-Port BRAM
// ============================================================================
// Instantiates ceil(DEPTH/4096) RAMB36E1 tiles in TDP mode configured as
// write-only port A + read-only port B, with DOB_REG=1.
//
// Why explicit instantiation?
//   Vivado's behavioural inference creates depth-cascaded BRAM groups with an
//   internal cascade MUX *before* the output register, blocking DOB_REG
//   absorption (Synth 8-7052).  At 150 MHz this causes Vivado to duplicate
//   every tile for timing, doubling BRAM count.
//
//   With explicit primitives, DOB_REG=1 is guaranteed, the cascade MUX lives
//   in fabric *after* the registered BRAM output, and Vivado has no reason
//   to duplicate tiles.
//
// Read latency: 2 clock cycles (BRAM array read → DOB_REG output).
//
// Targets: Spartan-7, Artix-7, Kintex-7, Virtex-7, Zynq-7000 (7-series).
//          For UltraScale/UltraScale+ replace RAMB36E1 with RAMB36E2.
// ============================================================================

module bram_sdp #(
    parameter DEPTH = 8192,
    parameter WIDTH = 8         // only 8 supported (maps to 9-bit BRAM port)
) (
    input  wire                       clk,
    // Write port
    input  wire                       we,
    input  wire [$clog2(DEPTH)-1:0]   waddr,
    input  wire [WIDTH-1:0]           wdata,
    // Read port  (2-cycle latency)
    input  wire [$clog2(DEPTH)-1:0]   raddr,
    output wire [WIDTH-1:0]           rdata
);

    // ----------------------------------------------------------------
    // Tile geometry
    // ----------------------------------------------------------------
    localparam TILE_DEPTH = 4096;           // RAMB36E1 @ 9-bit port
    localparam N_TILES    = (DEPTH + TILE_DEPTH - 1) / TILE_DEPTH;
    localparam ADDR_W     = $clog2(DEPTH);
    localparam SEL_BITS   = (N_TILES <= 1) ? 1 : $clog2(N_TILES);
    // Bits used for tile-internal addressing (max 12 for 4096-deep tile)
    localparam INNER_W    = (N_TILES <= 1) ? ADDR_W : (ADDR_W - SEL_BITS);

    // ----------------------------------------------------------------
    // Tile select — delayed 2 cycles to match DOB_REG latency
    // ----------------------------------------------------------------
    wire [SEL_BITS-1:0] rsel_now;
    reg  [SEL_BITS-1:0] rsel_d1, rsel_d2;

    generate
        if (N_TILES <= 1) begin : g_sel_one
            assign rsel_now = 1'b0;
        end else begin : g_sel_multi
            assign rsel_now = raddr[ADDR_W-1 -: SEL_BITS];
        end
    endgenerate

    always @(posedge clk) begin
        rsel_d1 <= rsel_now;
        rsel_d2 <= rsel_d1;
    end

    // ----------------------------------------------------------------
    // Per-tile DOB_REG outputs
    // ----------------------------------------------------------------
    wire [WIDTH-1:0] tile_dout [0:N_TILES-1];

    // ----------------------------------------------------------------
    // Generate RAMB36E1 tiles
    // ----------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < N_TILES; gi = gi + 1) begin : g_tile

            // Write-enable: decode upper address bits
            wire tile_we;
            if (N_TILES == 1) begin : g_we_one
                assign tile_we = we;
            end else begin : g_we_multi
                assign tile_we = we &&
                    (waddr[ADDR_W-1 -: SEL_BITS] == gi[SEL_BITS-1:0]);
            end

            // RAMB36E1 address format for 9-bit port (READ_WIDTH / WRITE_WIDTH = 9):
            //   [15]    = 1 (selects upper half of RAMB36 vs RAMB18)
            //   [14:3]  = 12-bit entry address (0..4095)
            //   [2:0]   = 0 (byte-lane, not used for 9-bit port)
            // Zero-pad narrow addresses to 12 bits to avoid out-of-range
            // part-selects when ADDR_W < 12 (e.g. small test images).
            wire [11:0] inner_wa = {{(12-INNER_W){1'b0}}, waddr[INNER_W-1:0]};
            wire [11:0] inner_ra = {{(12-INNER_W){1'b0}}, raddr[INNER_W-1:0]};
            wire [15:0] addr_a = {1'b1, inner_wa, 3'b000};
            wire [15:0] addr_b = {1'b1, inner_ra, 3'b000};

            wire [31:0] dob_out;

            RAMB36E1 #(
                .RAM_MODE              ("TDP"),
                .READ_WIDTH_A          (9),     // unused but must match WRITE_WIDTH_A
                .READ_WIDTH_B          (9),
                .WRITE_WIDTH_A         (9),
                .WRITE_WIDTH_B         (9),     // unused but must match READ_WIDTH_B
                .DOA_REG               (0),
                .DOB_REG               (1),     // *** the whole point ***
                .WRITE_MODE_A          ("NO_CHANGE"),
                .WRITE_MODE_B          ("WRITE_FIRST"),
                .RDADDR_COLLISION_HWCONFIG ("DELAYED_WRITE"),
                .RSTREG_PRIORITY_A     ("REGCE"),
                .RSTREG_PRIORITY_B     ("REGCE"),
                .SIM_COLLISION_CHECK   ("NONE"),
                .SIM_DEVICE            ("7SERIES"),
                .INIT_A                (36'h000000000),
                .INIT_B                (36'h000000000),
                .SRVAL_A               (36'h000000000),
                .SRVAL_B               (36'h000000000),
                .EN_ECC_READ           ("FALSE"),
                .EN_ECC_WRITE          ("FALSE"),
                .IS_CLKARDCLK_INVERTED (1'b0),
                .IS_CLKBWRCLK_INVERTED (1'b0),
                .IS_ENARDEN_INVERTED   (1'b0),
                .IS_ENBWREN_INVERTED   (1'b0),
                .IS_RSTRAMARSTRAM_INVERTED (1'b0),
                .IS_RSTRAMB_INVERTED   (1'b0),
                .IS_RSTREGARSTREG_INVERTED (1'b0),
                .IS_RSTREGB_INVERTED   (1'b0)
            ) u_bram (
                // Port A — write only
                .CLKARDCLK      (clk),
                .ENARDEN         (tile_we),
                .WEA             (4'b0001),      // byte-0 write enable
                .ADDRARDADDR     (addr_a),
                .DIADI           ({24'd0, wdata}),
                .DIPADIP         (4'd0),
                .DOADO           (),              // not reading port A
                .DOPADOP         (),
                .REGCEAREGCE     (1'b0),

                // Port B — read only (DOB_REG = 1)
                .CLKBWRCLK      (clk),
                .ENBWREN         (1'b1),          // always enabled
                .WEBWE           (8'd0),          // no writes
                .ADDRBWRADDR     (addr_b),
                .DIBDI           (32'd0),
                .DIPBDIP         (4'd0),
                .DOBDO           (dob_out),
                .DOPBDOP         (),
                .REGCEB          (1'b1),          // DOB_REG always clocked

                // Resets — all inactive
                .RSTRAMARSTRAM   (1'b0),
                .RSTRAMB         (1'b0),
                .RSTREGARSTREG   (1'b0),
                .RSTREGB         (1'b0),

                // Cascade — unused
                .CASCADEINA      (1'b0),
                .CASCADEINB      (1'b0),
                .CASCADEOUTA     (),
                .CASCADEOUTB     (),

                // ECC — unused
                .DBITERR         (),
                .SBITERR         (),
                .ECCPARITY       (),
                .RDADDRECC       (),
                .INJECTDBITERR   (1'b0),
                .INJECTSBITERR   (1'b0)
            );

            assign tile_dout[gi] = dob_out[WIDTH-1:0];

        end // g_tile
    endgenerate

    // ----------------------------------------------------------------
    // Output MUX — selects correct tile using rsel_d2 (2-cycle delayed)
    // ----------------------------------------------------------------
    generate
        if (N_TILES == 1) begin : g_out_one
            assign rdata = tile_dout[0];
        end else begin : g_out_mux
            reg [WIDTH-1:0] rdata_r;
            integer mi;
            always @(*) begin
                rdata_r = tile_dout[0];
                for (mi = 1; mi < N_TILES; mi = mi + 1)
                    if (rsel_d2 == mi[SEL_BITS-1:0])
                        rdata_r = tile_dout[mi];
            end
            assign rdata = rdata_r;
        end
    endgenerate

endmodule
