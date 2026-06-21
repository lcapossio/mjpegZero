// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// ============================================================================
// axis_frame_buffer.v - per-frame store-and-forward for a bursty AXIS source
// ============================================================================
// emacZero's eth_mac_tx is CUT-THROUGH: once a frame starts it requires a new
// byte every cycle, and a mid-frame s_axis_tvalid bubble makes it inject a
// 0x00 with gmii_tx_er (corrupting the frame). jpeg_rtp_tx, however, bubbles
// for one cycle at every 32-bit BRAM word boundary. This buffer absorbs those
// bubbles: it captures a complete frame (up to DEPTH bytes) and only then
// streams it to the MAC with tvalid held continuously high until tlast, so the
// MAC never underruns.
//
// Single-frame store-and-forward: while EMITting, s_tready is low so the source
// (jpeg_rtp_tx) backpressures. Async-read distributed RAM + combinational
// valid/last/data give trivially gap-free output. Frames must be <= DEPTH.
//
// Verilog 2001.
// ============================================================================

`timescale 1ns / 1ps

module axis_frame_buffer #(
    parameter AW = 11   // 2^11 = 2048 bytes; holds one max RTP frame (<1518)
)(
    input  wire       clk,
    input  wire       rst_n,
    // slave (from jpeg_rtp_tx) - may bubble mid-frame
    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    input  wire       s_tlast,
    output wire       s_tready,
    // master (to TX arbiter / MAC) - gap-free per frame
    output wire [7:0] m_tdata,
    output wire       m_tvalid,
    output wire       m_tlast,
    input  wire       m_tready
);

    localparam DEPTH = (1 << AW);
    (* ram_style = "distributed" *) reg [7:0] mem [0:DEPTH-1];

    reg [AW-1:0] wr, rd, last_idx;
    reg          state;
    localparam WRITE = 1'b0, EMIT = 1'b1;

    // Combinational AXIS outputs (aligned: data/valid/last all reflect rd/state)
    assign s_tready = (state == WRITE);
    assign m_tdata  = mem[rd];
    assign m_tvalid = (state == EMIT);
    assign m_tlast  = (state == EMIT) && (rd == last_idx);

    wire wr_en = s_tvalid && s_tready;

    always @(posedge clk) begin
        if (wr_en)
            mem[wr] <= s_tdata;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= WRITE;
            wr       <= {AW{1'b0}};
            rd       <= {AW{1'b0}};
            last_idx <= {AW{1'b0}};
        end else begin
            case (state)
                WRITE: begin
                    if (wr_en) begin
                        if (s_tlast) begin
                            last_idx <= wr;        // index of the final byte
                            rd       <= {AW{1'b0}};
                            wr       <= {AW{1'b0}};
                            state    <= EMIT;
                        end else begin
                            wr <= wr + 1'b1;
                        end
                    end
                end

                EMIT: begin
                    if (m_tready) begin            // m_tvalid is 1 throughout EMIT
                        if (rd == last_idx)
                            state <= WRITE;
                        else
                            rd <= rd + 1'b1;
                    end
                end

                default: state <= WRITE;
            endcase
        end
    end

endmodule
