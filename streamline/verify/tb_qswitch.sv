// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_qswitch.sv — mid-stream quality change, full encoder, per-frame capture
// ============================================================================
// Encodes frames of the same content in runtime-quality mode,
// writing a new quality through AXI-Lite between frames per the schedule in
// qsched.hex (one 7-bit value per frame). The write lands immediately after
// the previous frame's JPEG completes and the next frame's pixels start on
// the very next cycle — the tight case: the quantizer's ~132-clock shadow
// rebuild must finish inside the input buffer's 8-line fill (8*W clocks).
// Each frame's bytes go to frame_<n>.jpg for byte-exact comparison against
// single-quality runs.
// ============================================================================

`timescale 1ns / 1ps

module tb_qswitch;

    localparam W = `TB_W;
    localparam H = `TB_H;
    localparam NF = `TB_NF;
    localparam NUM_PIXELS = W * H;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [15:0] s_axis_vid_tdata = 0;
    reg         s_axis_vid_tvalid = 0;
    wire        s_axis_vid_tready;
    reg         s_axis_vid_tlast = 0, s_axis_vid_tuser = 0;
    wire        m_axis_jpg_tvalid, m_axis_jpg_tlast;
    wire [7:0]  m_axis_jpg_tdata;
    reg  [4:0]  s_axi_awaddr = 0;
    reg         s_axi_awvalid = 0;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata = 0;
    reg  [3:0]  s_axi_wstrb = 0;
    reg         s_axi_wvalid = 0;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready = 0;
    reg  [4:0]  s_axi_araddr = 0;
    reg         s_axi_arvalid = 0;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready = 0;

    mjpegzero_enc_top #(
        .IMG_WIDTH(W), .IMG_HEIGHT(H), .LITE_MODE(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_vid_tdata(s_axis_vid_tdata), .s_axis_vid_tvalid(s_axis_vid_tvalid),
        .s_axis_vid_tready(s_axis_vid_tready), .s_axis_vid_tlast(s_axis_vid_tlast),
        .s_axis_vid_tuser(s_axis_vid_tuser),
        .m_axis_jpg_tvalid(m_axis_jpg_tvalid), .m_axis_jpg_tdata(m_axis_jpg_tdata),
        .m_axis_jpg_tlast(m_axis_jpg_tlast),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready)
    );

    reg [15:0] vid_data [0:NUM_PIXELS-1];
    reg [6:0]  qsched [0:NF-1];
    initial begin
        $readmemh(`TV_HEX_FILE, vid_data);
        $readmemh("qsched.hex", qsched);
    end

    // Per-frame output capture
    integer out_f;
    integer frames_done = 0;
    reg [255:0] fname;
    initial begin
        $sformat(fname, "frame_0.jpg");
        out_f = $fopen("frame_0.jpg", "wb");
    end
    // tlast rides on the frame's final byte (the EOI's D9), so the byte
    // is written before the split.
    always @(posedge clk) begin
        if (m_axis_jpg_tvalid) begin
            $fwrite(out_f, "%c", m_axis_jpg_tdata);
            if (m_axis_jpg_tlast) begin
                $fclose(out_f);
                frames_done = frames_done + 1;
                if (frames_done < NF) begin
                    $sformat(fname, "frame_%0d.jpg", frames_done);
                    out_f = $fopen(fname, "wb");
                end
            end
        end
    end

    task axi_write(input [4:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr = addr;  s_axi_awvalid = 1;
            s_axi_wdata  = data;  s_axi_wstrb = 4'hF;
            s_axi_wvalid = 1;     s_axi_bready = 1;
            fork
                begin wait(s_axi_awready); @(posedge clk); s_axi_awvalid = 0; end
                begin wait(s_axi_wready);  @(posedge clk); s_axi_wvalid = 0;  end
            join
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    integer f, x, y, pixel_idx, guard;

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        axi_write(5'h00, 32'h1);                       // enable
        axi_write(5'h0C, {25'd0, qsched[0]});          // initial quality
`ifdef TB_DRI
        axi_write(5'h10, `TB_DRI);                     // restart interval
`endif
        repeat (600) @(posedge clk);                   // first table build

        for (f = 0; f < NF; f = f + 1) begin
            pixel_idx = 0;
            for (y = 0; y < H; y = y + 1)
                for (x = 0; x < W; x = x + 1) begin
                    @(negedge clk);
                    s_axis_vid_tvalid = 1;
                    s_axis_vid_tuser  = (x == 0 && y == 0);
                    s_axis_vid_tlast  = (x == W - 1);
                    s_axis_vid_tdata  = vid_data[pixel_idx];
                    pixel_idx = pixel_idx + 1;
                    while (!s_axis_vid_tready) @(negedge clk);
                end
            @(posedge clk); #1;
            s_axis_vid_tvalid = 0;
            s_axis_vid_tlast  = 0;
            s_axis_vid_tuser  = 0;

            // Wait for this frame's JPEG, then apply the next quality and
            // start feeding on the next cycle — no settle time (tight case).
            guard = 0;
            while (frames_done < f + 1 && guard < 4000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 4000000) begin
                $display("FAIL: frame %0d never completed", f);
                $finish;
            end
            if (f + 1 < NF && qsched[f + 1] != qsched[f])
                axi_write(5'h0C, {25'd0, qsched[f + 1]});
        end

        $display("DONE: %0d frames captured", frames_done);
        $finish;
    end

    // Debug visibility (harmless in normal runs)
`ifdef TB_DEBUG
    initial begin
        #30000000;
        $display("DBG mcu_count=%0d total=%0d frames_done=%0d",
                 dut.mcu_count, dut.TOTAL_BLOCKS, frames_done);
        $finish;
    end
`endif

endmodule
