// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// ============================================================================
// mac_csr_init.v - One-shot AXI4-Lite master to bring up emacZero eth_mac_sys
// ============================================================================
// After reset, writes three CSRs in order, then asserts init_done:
//   MAC_LO (0x0C) = MAC_ADDR[31:0]
//   MAC_HI (0x10) = MAC_ADDR[47:32]
//   CTRL   (0x04) = CTRL_VAL   (default 0x2B = tx_en|rx_en|speed=01(100M)|fdx)
// MAC address is written before CTRL so the link comes up configured. The MAC
// is live once tx_en/rx_en are set (no separate go bit).
//
// Modeled on example_proj/common/rtl/axi_init.v. Verilog 2001.
// ============================================================================

`timescale 1ns / 1ps

module mac_csr_init #(
    parameter [47:0] MAC_ADDR = 48'h02_00_00_00_00_01,
    parameter [8:0]  CTRL_VAL = 9'h02B   // tx_en|rx_en|speed=100M|full_duplex
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite master -> eth_mac_sys CSR (8-bit byte address)
    output reg  [7:0]  m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,

    // Read channel (unused)
    output wire [7:0]  m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output reg         init_done
);

    assign m_axi_araddr  = 8'h00;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b0;

    localparam NWRITES = 3;

    localparam [1:0] S_ADDR = 2'd0, S_RESP = 2'd1, S_NEXT = 2'd2, S_DONE = 2'd3;
    reg [1:0] state;
    reg [1:0] step;
    reg       aw_done, w_done;

    // Per-step address/data lookup
    reg [7:0]  step_addr;
    reg [31:0] step_data;
    always @* begin
        case (step)
            2'd0: begin step_addr = 8'h0C; step_data = MAC_ADDR[31:0];          end // MAC_LO
            2'd1: begin step_addr = 8'h10; step_data = {16'd0, MAC_ADDR[47:32]}; end // MAC_HI
            default: begin step_addr = 8'h04; step_data = {23'd0, CTRL_VAL};     end // CTRL
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_ADDR;
            step          <= 2'd0;
            m_axi_awaddr  <= 8'h00;
            m_axi_awvalid <= 1'b0;
            m_axi_wdata   <= 32'd0;
            m_axi_wstrb   <= 4'h0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            aw_done       <= 1'b0;
            w_done        <= 1'b0;
            init_done     <= 1'b0;
        end else begin
            case (state)
                S_ADDR: begin
                    m_axi_awaddr  <= step_addr;
                    m_axi_wdata   <= step_data;
                    m_axi_wstrb   <= 4'hF;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    aw_done       <= 1'b0;
                    w_done        <= 1'b0;
                    state         <= S_RESP;
                end

                S_RESP: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        aw_done       <= 1'b1;
                    end
                    if (m_axi_wready && m_axi_wvalid) begin
                        m_axi_wvalid <= 1'b0;
                        w_done       <= 1'b1;
                    end
                    if (m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        state        <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (step == NWRITES - 1) begin
                        state <= S_DONE;
                    end else begin
                        step  <= step + 2'd1;
                        state <= S_ADDR;
                    end
                end

                S_DONE: init_done <= 1'b1;

                default: state <= S_DONE;
            endcase
        end
    end

endmodule
