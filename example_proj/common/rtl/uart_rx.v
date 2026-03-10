// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// uart_rx.v — 8N1 UART receiver
// BAUD_DIV = clk_freq / baud_rate  (default 163 = 150 MHz / 921600)
// Verilog 2001

`timescale 1ns / 1ps

module uart_rx #(
    parameter BAUD_DIV = 163
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,          // UART RX pin (async input)
    output reg  [7:0] rx_data,     // received byte
    output reg        rx_valid     // 1-cycle pulse when rx_data is valid
);

    // Synchronise rx to clk domain (2FF)
    reg rx_s0, rx_s1;
    always @(posedge clk) begin
        rx_s0 <= rx;
        rx_s1 <= rx_s0;
    end

    // States
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [7:0]  baud_cnt;
    reg [7:0]  shift;
    reg [2:0]  bit_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            baud_cnt <= 8'd0;
            shift    <= 8'd0;
            bit_idx  <= 3'd0;
            rx_data  <= 8'd0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (!rx_s1) begin           // falling edge = start bit
                        // sample at mid-bit: wait 1.5 bit periods
                        baud_cnt <= BAUD_DIV[7:0] + (BAUD_DIV[7:0] >> 1);
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (baud_cnt == 8'd0) begin
                        if (!rx_s1) begin       // start bit still low — valid
                            bit_idx  <= 3'd0;
                            baud_cnt <= BAUD_DIV[7:0] - 8'd1;
                            state    <= S_DATA;
                        end else begin
                            state <= S_IDLE;    // glitch — abort
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 8'd1;
                    end
                end

                S_DATA: begin
                    if (baud_cnt == 8'd0) begin
                        shift    <= {rx_s1, shift[7:1]}; // LSB first
                        baud_cnt <= BAUD_DIV[7:0] - 8'd1;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 8'd1;
                    end
                end

                S_STOP: begin
                    if (baud_cnt == 8'd0) begin
                        if (rx_s1) begin        // stop bit high — valid frame
                            rx_data  <= shift;
                            rx_valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt - 8'd1;
                    end
                end
            endcase
        end
    end

endmodule
