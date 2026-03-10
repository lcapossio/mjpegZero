// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// RGB to YCbCr Color Space Converter
// ============================================================================
// Converts 24-bit RGB pixels to YCbCr (BT.601) and outputs as 16-bit YUYV
// packed format compatible with the MJPEG encoder's AXI4-Stream input.
//
// BT.601 equations (full range):
//   Y  =  0.299*R + 0.587*G + 0.114*B
//   Cb = -0.169*R - 0.331*G + 0.500*B + 128
//   Cr =  0.500*R - 0.419*G - 0.081*B + 128
//
// Fixed-point (2^16): multiply by 65536
//   Y  =  (19595*R + 38470*G +  7471*B + 32768) >> 16
//   Cb = (-11056*R - 21712*G + 32768*B + 32768) >> 16 + 128
//   Cr = ( 32768*R - 27440*G -  5328*B + 32768) >> 16 + 128
//
// Output: YUYV packed 16-bit words on AXI4-Stream
//   Even pixels: {Cb, Y0}
//   Odd pixels:  {Cr, Y1}
//   Cb/Cr are averaged over each pixel pair (horizontal 4:2:2)
//
// Pipeline: 3-stage (register inputs, multiply+add, shift+pack)
// ============================================================================

module rgb_to_ycbcr (
    input  wire        clk,
    input  wire        rst_n,

    // Input: 24-bit RGB AXI4-Stream
    input  wire [23:0] s_axis_tdata,   // {R[23:16], G[15:8], B[7:0]}
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,   // End of scanline
    input  wire        s_axis_tuser,   // Start of frame

    // Output: 16-bit YUYV AXI4-Stream
    output reg  [15:0] m_axis_tdata,   // {Cb/Cr[15:8], Y[7:0]}
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser
);

    // Always ready (no backpressure in this simple version)
    assign s_axis_tready = m_axis_tready || !m_axis_tvalid;

    // ========================================================================
    // Pipeline stage 1: Register inputs, extract R/G/B
    // ========================================================================
    reg [7:0] p1_r, p1_g, p1_b;
    reg       p1_valid, p1_last, p1_user;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_last  <= 1'b0;
            p1_user  <= 1'b0;
        end else if (s_axis_tready) begin
            p1_valid <= s_axis_tvalid;
            p1_r     <= s_axis_tdata[23:16];
            p1_g     <= s_axis_tdata[15:8];
            p1_b     <= s_axis_tdata[7:0];
            p1_last  <= s_axis_tlast;
            p1_user  <= s_axis_tuser;
        end
    end

    // ========================================================================
    // Pipeline stage 2: Multiply and add (uses DSP48)
    // ========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [25:0] p2_y_raw;
    reg signed [25:0] p2_cb_raw;
    reg signed [25:0] p2_cr_raw;
    /* verilator lint_on UNUSEDSIGNAL */
    reg        p2_valid, p2_last, p2_user;

    always @(posedge clk) begin
        if (!rst_n) begin
            p2_valid <= 1'b0;
            p2_last  <= 1'b0;
            p2_user  <= 1'b0;
        end else if (s_axis_tready) begin
            p2_valid  <= p1_valid;
            p2_last   <= p1_last;
            p2_user   <= p1_user;
            // Y = 0.299*R + 0.587*G + 0.114*B (fixed point 2^16)
            p2_y_raw  <= $signed({1'b0, 17'd19595}) * $signed({1'b0, p1_r}) +
                         $signed({1'b0, 17'd38470}) * $signed({1'b0, p1_g}) +
                         $signed({1'b0, 17'd7471})  * $signed({1'b0, p1_b}) +
                         $signed(26'd32768);
            // Cb = -0.169*R - 0.331*G + 0.500*B
            /* verilator lint_off WIDTHEXPAND */
            p2_cb_raw <= -$signed({1'b0, 17'd11056}) * $signed({1'b0, p1_r}) +
                         -$signed({1'b0, 17'd21712}) * $signed({1'b0, p1_g}) +
                          $signed({1'b0, 17'd32768}) * $signed({1'b0, p1_b}) +
                          $signed(26'd32768);
            // Cr = 0.500*R - 0.419*G - 0.081*B
            p2_cr_raw <=  $signed({1'b0, 17'd32768}) * $signed({1'b0, p1_r}) +
                         -$signed({1'b0, 17'd27440}) * $signed({1'b0, p1_g}) +
                         -$signed({1'b0, 17'd5328})  * $signed({1'b0, p1_b}) +
                          $signed(26'd32768);
            /* verilator lint_on WIDTHEXPAND */
        end
    end

    // ========================================================================
    // Pipeline stage 3: Shift, clamp, pack YUYV
    // ========================================================================
    // Track even/odd pixel for YUYV packing
    reg        pixel_odd;  // 0=even (output Cb,Y), 1=odd (output Cr,Y)

    wire [7:0] y_clamped;
    wire [7:0] cb_clamped;
    wire [7:0] cr_clamped;

    // Shift right by 16 and clamp to 0-255
    wire signed [9:0] y_shifted  = p2_y_raw[25:16];
    wire signed [9:0] cb_shifted = p2_cb_raw[25:16] + 10'sd128;
    wire signed [9:0] cr_shifted = p2_cr_raw[25:16] + 10'sd128;

    assign y_clamped  = (y_shifted  < 0) ? 8'd0 : (y_shifted  > 255) ? 8'd255 : y_shifted[7:0];
    assign cb_clamped = (cb_shifted < 0) ? 8'd0 : (cb_shifted > 255) ? 8'd255 : cb_shifted[7:0];
    assign cr_clamped = (cr_shifted < 0) ? 8'd0 : (cr_shifted > 255) ? 8'd255 : cr_shifted[7:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            pixel_odd     <= 1'b0;
        end else if (s_axis_tready) begin
            m_axis_tvalid <= p2_valid;
            m_axis_tlast  <= p2_last;
            m_axis_tuser  <= p2_user;

            if (p2_valid) begin
                if (!pixel_odd) begin
                    // Even pixel: output {Cb, Y0}
                    m_axis_tdata <= {cb_clamped, y_clamped};
                    pixel_odd    <= 1'b1;
                end else begin
                    // Odd pixel: output {Cr, Y1}
                    m_axis_tdata <= {cr_clamped, y_clamped};
                    pixel_odd    <= 1'b0;
                end

                // Reset on start of frame
                if (p2_user)
                    pixel_odd <= 1'b0;
            end
        end
    end

endmodule
