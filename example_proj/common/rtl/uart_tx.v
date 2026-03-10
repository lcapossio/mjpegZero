// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// uart_tx.v — 8N1 UART transmitter
// BAUD_DIV = clk_freq / baud_rate  (default 163 = 150 MHz / 921600)
// Verilog 2001

`timescale 1ns / 1ps

module uart_tx #(
    parameter BAUD_DIV = 163
) (
    input  wire       clk,
    input  wire       rst_n,
    output reg        tx,          // UART TX pin
    input  wire [7:0] tx_data,     // byte to transmit
    input  wire       tx_valid,    // pulse to start transmission
    output wire       tx_ready     // high when idle and ready to accept
);

    localparam S_IDLE = 2'd0;
    localparam S_DATA = 2'd1;
    localparam S_STOP = 2'd2;

    reg [1:0]  state;
    reg [7:0]  baud_cnt;
    reg [9:0]  shift;    // {stop, data[7:0], start} = 10 bits
    reg [3:0]  bit_cnt;

    assign tx_ready = (state == S_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tx       <= 1'b1;
            baud_cnt <= 8'd0;
            shift    <= 10'h3FF;
            bit_cnt  <= 4'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (tx_valid) begin
                        // {stop=1, data MSB…LSB, start=0}
                        shift    <= {1'b1, tx_data, 1'b0};
                        baud_cnt <= BAUD_DIV[7:0] - 8'd1;
                        bit_cnt  <= 4'd0;
                        state    <= S_DATA;
                    end
                end

                S_DATA: begin
                    tx <= shift[0];
                    if (baud_cnt == 8'd0) begin
                        shift    <= {1'b1, shift[9:1]}; // shift right
                        baud_cnt <= BAUD_DIV[7:0] - 8'd1;
                        if (bit_cnt == 4'd9) begin       // all 10 bits sent
                            state <= S_IDLE;
                        end else begin
                            bit_cnt <= bit_cnt + 4'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 8'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
