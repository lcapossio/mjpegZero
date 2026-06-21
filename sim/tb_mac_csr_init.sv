// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_mac_csr_init.sv - unit test for mac_csr_init against a simple AXI4-Lite
// register-file slave. Verifies the three CSR writes land at the right offsets
// with the right values (MAC_LO@0x0C, MAC_HI@0x10, CTRL@0x04=0x2B).

`timescale 1ns / 1ps

module tb_mac_csr_init;
    localparam [47:0] MAC = 48'h02_DE_AD_BE_EF_01;
    localparam [8:0]  CTRL = 9'h02B;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire [7:0]  awaddr;  wire awvalid;  reg awready;
    wire [31:0] wdata;   wire [3:0] wstrb; wire wvalid; reg wready;
    reg  [1:0]  bresp;   reg bvalid;     wire bready;
    wire        init_done;

    mac_csr_init #(.MAC_ADDR(MAC), .CTRL_VAL(CTRL)) dut (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awaddr(awaddr), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_araddr(), .m_axi_arvalid(), .m_axi_arready(1'b1),
        .m_axi_rdata(32'd0), .m_axi_rresp(2'd0), .m_axi_rvalid(1'b0), .m_axi_rready(),
        .init_done(init_done)
    );

    // simple AXI4-Lite slave: register file indexed by word address
    reg [31:0] regfile [0:63];
    reg aw_seen, w_seen;
    reg [7:0] aw_addr_l;
    integer k;
    initial begin
        awready = 1'b1; wready = 1'b1; bvalid = 1'b0; bresp = 2'b00;
        aw_seen = 0; w_seen = 0;
        for (k = 0; k < 64; k = k + 1) regfile[k] = 32'hDEADC0DE;
    end

    always @(posedge clk) begin
        if (awvalid && awready) begin aw_addr_l <= awaddr; aw_seen <= 1'b1; end
        if (wvalid  && wready)  begin w_seen <= 1'b1; end
        if (aw_seen && w_seen && !bvalid) begin
            regfile[aw_addr_l[7:2]] <= wdata;
            bvalid <= 1'b1;
            aw_seen <= 1'b0; w_seen <= 1'b0;
        end
        if (bvalid && bready) bvalid <= 1'b0;
    end

    integer errors = 0;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        wait (init_done === 1'b1);
        repeat (2) @(posedge clk);

        if (regfile[8'h0C >> 2] !== MAC[31:0]) begin
            $display("FAIL MAC_LO(0x0C)=%08x exp %08x", regfile[3], MAC[31:0]); errors=errors+1;
        end
        if (regfile[8'h10 >> 2] !== {16'd0, MAC[47:32]}) begin
            $display("FAIL MAC_HI(0x10)=%08x exp %08x", regfile[4], {16'd0,MAC[47:32]}); errors=errors+1;
        end
        if (regfile[8'h04 >> 2] !== {23'd0, CTRL}) begin
            $display("FAIL CTRL(0x04)=%08x exp %08x", regfile[1], {23'd0,CTRL}); errors=errors+1;
        end

        if (errors == 0)
            $display("[tb_mac_csr_init] PASS: MAC_LO=%08x MAC_HI=%08x CTRL=%08x",
                     regfile[3], regfile[4], regfile[1]);
        else
            $display("[tb_mac_csr_init] FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin #100000; $display("[tb_mac_csr_init] TIMEOUT"); $finish; end
endmodule
