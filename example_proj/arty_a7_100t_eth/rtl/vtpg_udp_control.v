// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// vtpg_udp_control.v - Decode host UDP control packets for demo_top_vtpg_eth.
//
// TRIGGER_PORT payload byte 0 controls the stream:
//   'G'/other -> start continuous, 'S'/'s'/0 -> stop, '1'/2 -> single frame.
// VTPG_CTRL_PORT payloads are KV260-style register writes:
//   byte 0 = register offset, bytes 1..4 = 32-bit big-endian value.
// Verilog 2001.

`timescale 1ns / 1ps

module vtpg_udp_control #(
    parameter [15:0] TRIGGER_PORT   = 16'd9999,
    parameter [15:0] VTPG_CTRL_PORT = 16'd9998
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  udp_data,
    input  wire        udp_valid,
    input  wire        udp_last,
    input  wire [15:0] udp_dst_port,

    output reg         start_loop,
    output reg         stop_loop,
    output reg         single_req,

    output reg  [3:0]  cfg_pattern,
    output reg  [23:0] solid_color,
    output reg  [23:0] box_color,
    output reg  [15:0] box_w,
    output reg  [15:0] box_h,
    output reg  [15:0] box_dx,
    output reg  [15:0] box_dy,
    output reg  [15:0] grid_spacing,
    output reg  [15:0] checker_size,
    output reg  [31:0] box_img_x_step,
    output reg  [31:0] box_img_y_step
);

    localparam [7:0] OP_STOP_0 = 8'h00;
    localparam [7:0] OP_STOP_S = 8'h53;
    localparam [7:0] OP_STOP_s = 8'h73;
    localparam [7:0] OP_ONE_0  = 8'h02;
    localparam [7:0] OP_ONE_1  = 8'h31;

    reg        in_pkt;
    reg [7:0]  opcode;
    reg [31:0] value;
    reg [2:0]  byte_idx;

    reg        pend_start;
    reg        pend_stop;
    reg        pend_single;
    reg        pend_vtpg;
    reg [7:0]  pend_reg;
    reg [31:0] pend_value;

    always @(posedge clk) begin
        if (!rst_n) begin
            in_pkt         <= 1'b0;
            opcode         <= 8'd0;
            value          <= 32'd0;
            byte_idx       <= 3'd0;
            start_loop     <= 1'b0;
            stop_loop      <= 1'b0;
            single_req     <= 1'b0;
            pend_start     <= 1'b0;
            pend_stop      <= 1'b0;
            pend_single    <= 1'b0;
            pend_vtpg      <= 1'b0;
            pend_reg       <= 8'd0;
            pend_value     <= 32'd0;
            cfg_pattern    <= 4'd0;
            box_w          <= 16'd96;
            box_h          <= 16'd64;
            box_dx         <= 16'd4;
            box_dy         <= 16'd3;
            box_color      <= 24'hEB_80_80;
            solid_color    <= 24'hEB_80_80;
            grid_spacing   <= 16'd32;
            checker_size   <= 16'd32;
            box_img_x_step <= 32'd21845; // (32 << 16) / 96
            box_img_y_step <= 32'd32768; // (32 << 16) / 64
        end else begin
            start_loop <= pend_start;
            stop_loop  <= pend_stop;
            single_req <= pend_single;

            if (pend_vtpg) begin
                case (pend_reg)
                    8'h18: cfg_pattern    <= pend_value[3:0];
                    8'h20: solid_color    <= pend_value[23:0];
                    8'h24: box_color      <= pend_value[23:0];
                    8'h28: begin box_w  <= pend_value[31:16]; box_h  <= pend_value[15:0]; end
                    8'h2C: begin box_dx <= pend_value[31:16]; box_dy <= pend_value[15:0]; end
                    8'h34: grid_spacing   <= pend_value[15:0];
                    8'h3C: checker_size   <= pend_value[15:0];
                    8'h54: box_img_x_step <= pend_value;
                    8'h58: box_img_y_step <= pend_value;
                    default: ;
                endcase
            end

            pend_start  <= 1'b0;
            pend_stop   <= 1'b0;
            pend_single <= 1'b0;
            pend_vtpg   <= 1'b0;

            if (udp_valid) begin
                if (!in_pkt) begin
                    in_pkt   <= 1'b1;
                    opcode   <= udp_data;
                    value    <= 32'd0;
                    byte_idx <= 3'd1;
                end else begin
                    if (byte_idx <= 3'd4)
                        value <= {value[23:0], udp_data};
                    if (byte_idx != 3'd7)
                        byte_idx <= byte_idx + 3'd1;
                end

                if (udp_last) begin
                    in_pkt <= 1'b0;

                    if (udp_dst_port == TRIGGER_PORT) begin
                        if ((!in_pkt && (udp_data == OP_STOP_0 || udp_data == OP_STOP_S || udp_data == OP_STOP_s)) ||
                            ( in_pkt && (opcode   == OP_STOP_0 || opcode   == OP_STOP_S || opcode   == OP_STOP_s))) begin
                            pend_stop <= 1'b1;
                        end else if ((!in_pkt && (udp_data == OP_ONE_0 || udp_data == OP_ONE_1)) ||
                                     ( in_pkt && (opcode   == OP_ONE_0 || opcode   == OP_ONE_1))) begin
                            pend_single <= 1'b1;
                        end else begin
                            pend_start <= 1'b1;
                        end
                    end

                    if (udp_dst_port == VTPG_CTRL_PORT) begin
                        pend_vtpg <= 1'b1;
                        pend_reg  <= in_pkt ? opcode : udp_data;
                        if (!in_pkt)
                            pend_value <= 32'd0;
                        else if (byte_idx <= 3'd4)
                            pend_value <= {value[23:0], udp_data};
                        else
                            pend_value <= value;
                    end
                end
            end
        end
    end

endmodule
