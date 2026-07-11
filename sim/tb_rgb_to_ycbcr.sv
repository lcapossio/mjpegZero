// ============================================================================
// Testbench: rgb_to_ycbcr
// ============================================================================
// Feeds known RGB colors through the converter and dumps a VCD waveform
// (tb_rgb_to_ycbcr.vcd) for viewing in Surfer/GTKWave.
//
// Expected BT.601 full-range values (Y, Cb, Cr):
//   Black (0,0,0)       -> (  0, 128, 128)
//   White (255,255,255) -> (255, 128, 128)
//   Red   (255,0,0)     -> ( 76,  85, 255)
//   Green (0,255,0)     -> (150,  44,  21)
//   Blue  (0,0,255)     -> ( 29, 255, 107)
//   Gray  (128,128,128) -> (128, 128, 128)
//
// Run:
//   iverilog -g2012 -o sim/tb_rgb_to_ycbcr.vvp rtl/rgb_to_ycbcr.v sim/tb_rgb_to_ycbcr.sv
//   vvp sim/tb_rgb_to_ycbcr.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_rgb_to_ycbcr;

    reg         clk = 0;
    reg         rst_n = 0;

    reg  [23:0] s_tdata = 0;
    reg         s_tvalid = 0;
    reg         s_tlast = 0;
    reg         s_tuser = 0;
    wire        s_tready;

    wire [15:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready = 1;
    wire        m_tlast;
    wire        m_tuser;

    rgb_to_ycbcr dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .s_axis_tuser  (s_tuser),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast),
        .m_axis_tuser  (m_tuser)
    );

    // 100 MHz clock
    always #5 clk = ~clk;

    // Test pixels: {R, G, B} pairs (even pixel emits {Cb,Y}, odd emits {Cr,Y})
    localparam integer NPIX = 8;
    reg [23:0] pixels [0:NPIX-1];
    initial begin
        pixels[0] = 24'h000000;  // black
        pixels[1] = 24'hFFFFFF;  // white
        pixels[2] = 24'hFF0000;  // red
        pixels[3] = 24'hFF0000;  // red   (pair with red -> clean Cr)
        pixels[4] = 24'h00FF00;  // green
        pixels[5] = 24'h00FF00;  // green
        pixels[6] = 24'h0000FF;  // blue
        pixels[7] = 24'h808080;  // gray
    end

    integer i;
    integer out_count = 0;

    // Drive input stream
    initial begin
        $dumpfile("sim/tb_rgb_to_ycbcr.vcd");
        $dumpvars(0, tb_rgb_to_ycbcr);

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (i = 0; i < NPIX; i = i + 1) begin
            s_tdata  <= pixels[i];
            s_tvalid <= 1'b1;
            s_tuser  <= (i == 0);         // start of frame
            s_tlast  <= (i == NPIX - 1);  // end of scanline
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
        s_tuser  <= 1'b0;

        // Drain the 3-stage pipeline
        repeat (10) @(posedge clk);
        $display("Done: %0d output words captured", out_count);
        $finish;
    end

    // Log outputs
    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            $display("[%0t] out[%0d] = %04h  (C=%0d Y=%0d)%s%s",
                     $time, out_count, m_tdata, m_tdata[15:8], m_tdata[7:0],
                     m_tuser ? "  SOF" : "", m_tlast ? "  EOL" : "");
            out_count = out_count + 1;
        end
    end

endmodule
