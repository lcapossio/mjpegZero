// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// vtpg_stream_control.v - Autonomous frame sequencing and JPEG buffer
// rate-control loop for demo_top_vtpg_eth.
// Verilog 2001.

`timescale 1ns / 1ps

module vtpg_stream_control #(
    parameter [18:0] JPEG_CAP_BYTES     = 19'd262144,
    parameter [6:0]  RC_Q_INIT          = 7'd75,
    parameter [6:0]  RC_Q_MIN           = 7'd5,
    parameter [6:0]  RC_Q_MAX           = 7'd95,
    parameter [6:0]  RC_Q_NEAR_STEP     = 7'd5,
    parameter [6:0]  RC_Q_OVF_STEP      = 7'd20,
    parameter [2:0]  RC_GOOD_FRAMES     = 3'd4,
    parameter [9:0]  RC_Q_SETTLE_CYCLES = 10'd600
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_loop,
    input  wire        stop_loop,
    input  wire        single_req,

    input  wire        init_done,
    output reg         enc_quality_req,
    output reg  [6:0]  enc_quality_value,
    input  wire        enc_quality_busy,
    input  wire        enc_quality_done,

    output reg         frame_kick,
    output reg         cap_reset,
    input  wire        cap_done,
    input  wire        jpeg_overflow,
    input  wire [18:0] jpeg_byte_cnt,

    output reg         rtp_start,
    input  wire        rtp_busy,
    input  wire        rtp_done,

    output reg  [3:0]  vstate,
    output reg  [31:0] frame_cnt,
    output reg         loop_en,
    output reg  [6:0]  rc_quality,
    output reg  [15:0] rc_dropped_frames
);

    localparam [18:0] RC_HIGH_BYTES = JPEG_CAP_BYTES - (JPEG_CAP_BYTES >> 3);
    localparam [18:0] RC_LOW_BYTES  = JPEG_CAP_BYTES >> 1;

    localparam [3:0] V_IDLE   = 4'd0;
    localparam [3:0] V_QWRITE = 4'd1;
    localparam [3:0] V_QWAIT  = 4'd2;
    localparam [3:0] V_KICK   = 4'd3;
    localparam [3:0] V_KWAIT  = 4'd4;
    localparam [3:0] V_ENC    = 4'd5;
    localparam [3:0] V_STREAM = 4'd6;
    localparam [3:0] V_WAIT   = 4'd7;

    reg       single_pend;
    reg [2:0] rc_good_frames;
    reg [9:0] rc_qwait_cnt;

    function [6:0] rc_quality_sub;
        input [6:0] q;
        input [6:0] delta;
        reg [7:0] min_plus_delta;
        begin
            min_plus_delta = {1'b0, RC_Q_MIN} + {1'b0, delta};
            if ({1'b0, q} <= min_plus_delta)
                rc_quality_sub = RC_Q_MIN;
            else
                rc_quality_sub = q - delta;
        end
    endfunction

    function [6:0] rc_quality_inc;
        input [6:0] q;
        begin
            if (q >= RC_Q_MAX)
                rc_quality_inc = RC_Q_MAX;
            else
                rc_quality_inc = q + 7'd1;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            vstate            <= V_IDLE;
            frame_kick        <= 1'b0;
            cap_reset         <= 1'b0;
            rtp_start         <= 1'b0;
            enc_quality_req   <= 1'b0;
            enc_quality_value <= RC_Q_INIT;
            rc_quality        <= RC_Q_INIT;
            rc_good_frames    <= 3'd0;
            rc_qwait_cnt      <= 10'd0;
            rc_dropped_frames <= 16'd0;
            frame_cnt         <= 32'd0;
            loop_en           <= 1'b0;
            single_pend       <= 1'b0;
        end else begin
            frame_kick      <= 1'b0;
            cap_reset       <= 1'b0;
            rtp_start       <= 1'b0;
            enc_quality_req <= 1'b0;

            if (stop_loop) begin
                loop_en     <= 1'b0;
                single_pend <= 1'b0;
            end else begin
                if (start_loop)
                    loop_en <= 1'b1;
                if (single_req)
                    single_pend <= 1'b1;
            end

            case (vstate)
                V_IDLE: begin
                    if ((loop_en || single_pend) && init_done) begin
                        single_pend <= 1'b0;
                        vstate      <= V_QWRITE;
                    end
                end

                V_QWRITE: begin
                    enc_quality_value <= rc_quality;
                    if (enc_quality_done) begin
                        rc_qwait_cnt <= 10'd0;
                        vstate       <= V_QWAIT;
                    end else if (!enc_quality_busy) begin
                        enc_quality_req <= 1'b1;
                    end
                end

                V_QWAIT: begin
                    if (rc_qwait_cnt == RC_Q_SETTLE_CYCLES)
                        vstate <= V_KICK;
                    else
                        rc_qwait_cnt <= rc_qwait_cnt + 10'd1;
                end

                V_KICK: begin
                    cap_reset  <= 1'b1;
                    frame_kick <= 1'b1;
                    vstate     <= V_KWAIT;
                end

                V_KWAIT: begin
                    vstate <= V_ENC;
                end

                V_ENC: begin
                    if (cap_done) begin
                        if (jpeg_overflow) begin
                            rc_quality        <= rc_quality_sub(rc_quality, RC_Q_OVF_STEP);
                            rc_good_frames    <= 3'd0;
                            rc_dropped_frames <= rc_dropped_frames + 16'd1;
                            vstate            <= loop_en ? V_QWRITE : V_IDLE;
                        end else begin
                            if (jpeg_byte_cnt > RC_HIGH_BYTES) begin
                                rc_quality     <= rc_quality_sub(rc_quality, RC_Q_NEAR_STEP);
                                rc_good_frames <= 3'd0;
                            end else if (jpeg_byte_cnt < RC_LOW_BYTES) begin
                                if (rc_good_frames == (RC_GOOD_FRAMES - 3'd1)) begin
                                    rc_quality     <= rc_quality_inc(rc_quality);
                                    rc_good_frames <= 3'd0;
                                end else begin
                                    rc_good_frames <= rc_good_frames + 3'd1;
                                end
                            end else begin
                                rc_good_frames <= 3'd0;
                            end
                            vstate <= V_STREAM;
                        end
                    end
                end

                V_STREAM: begin
                    rtp_start <= 1'b1;
                    if (rtp_busy)
                        vstate <= V_WAIT;
                end

                V_WAIT: begin
                    if (rtp_done) begin
                        frame_cnt <= frame_cnt + 32'd1;
                        vstate    <= loop_en ? V_QWRITE : V_IDLE;
                    end
                end

                default: begin
                    vstate <= V_IDLE;
                end
            endcase
        end
    end

endmodule
