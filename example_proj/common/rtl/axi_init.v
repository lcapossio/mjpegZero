// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// axi_init.v — One-shot AXI4-Lite master that enables the mjpegZero encoder.
// Writes CTRL register (addr 0x00) = 0x01 (enable=1) after reset.
// In LITE_MODE the quality is fixed at synthesis time; no QUALITY write needed.
// Verilog 2001

`timescale 1ns / 1ps

module axi_init (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite master outputs → encoder slave
    output reg  [4:0]  m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,
    output wire [4:0]  m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output reg         init_done   // stays high once init is complete
);

    // Tie off read channel (unused)
    assign m_axi_araddr  = 5'h0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b0;

    // States
    localparam S_RESET = 3'd0;
    localparam S_ADDR  = 3'd1;   // drive awvalid + wvalid together
    localparam S_RESP  = 3'd2;   // wait for bvalid
    localparam S_DONE  = 3'd3;

    reg [2:0] state;
    reg       aw_done, w_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_RESET;
            m_axi_awaddr  <= 5'h00;
            m_axi_awvalid <= 1'b0;
            m_axi_wdata   <= 32'h0;
            m_axi_wstrb   <= 4'h0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            init_done     <= 1'b0;
            aw_done       <= 1'b0;
            w_done        <= 1'b0;
        end else begin
            case (state)
                S_RESET: begin
                    // Wait one cycle after reset before issuing transaction
                    m_axi_awaddr  <= 5'h00;       // CTRL register
                    m_axi_wdata   <= 32'h00000001; // enable = 1
                    m_axi_wstrb   <= 4'hF;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    aw_done       <= 1'b0;
                    w_done        <= 1'b0;
                    state         <= S_ADDR;
                end

                S_ADDR: begin
                    // AW channel
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        aw_done       <= 1'b1;
                    end
                    // W channel
                    if (m_axi_wready && m_axi_wvalid) begin
                        m_axi_wvalid <= 1'b0;
                        w_done       <= 1'b1;
                    end
                    // Both accepted → wait for response
                    if ((aw_done || (m_axi_awready && m_axi_awvalid)) &&
                        (w_done  || (m_axi_wready  && m_axi_wvalid))) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b0;
                        state         <= S_RESP;
                    end
                end

                S_RESP: begin
                    if (m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        state        <= S_DONE;
                    end
                end

                S_DONE: begin
                    init_done <= 1'b1;
                end

                default: state <= S_DONE;
            endcase
        end
    end

endmodule
