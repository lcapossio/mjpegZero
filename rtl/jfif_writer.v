// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// JFIF Writer - JPEG File Header/Trailer Generation
// ============================================================================
// Generates JPEG/JFIF file headers before scan data and EOI after.
// Multiplexes header bytes and scan data onto output AXI4-Stream.
//
// LITE_MODE=0 (default): Dynamic DQT sections read from quantizer
//   - 14-state FSM, dynamic Q-table readout via qt_rd_* port
//   - Supports DRI marker (restart intervals)
//
// LITE_MODE=1: Fixed 623-byte header ROM (LITE_QUALITY param)
//   - Simplified FSM, no quantizer read port usage
//   - DQT and SOF0 parameterized via initial block computation
//   - DRI marker still supported (inserted between SOF0 and DHT)
// ============================================================================

module jfif_writer #(
    parameter IMG_WIDTH    = 1280,
    parameter IMG_HEIGHT   = 720,
    parameter LITE_MODE    = 0,
    parameter LITE_QUALITY = 95    // Quality 1-100, used when LITE_MODE=1
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        frame_start,       // Pulse to start a new frame
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        frame_done,        // Pulse when scan data is complete
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [15:0] restart_interval,  // 0 = no DRI marker

    // Q-table read port (from quantizer)
    output reg  [5:0]  qt_rd_addr,
    output reg         qt_rd_is_chroma,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  qt_rd_data,
    /* verilator lint_on UNUSEDSIGNAL */

    // Scan data input (from bitstream packer)
    input  wire        scan_valid,
    input  wire [7:0]  scan_data,
    input  wire        scan_last,         // End of scan data
    output wire        scan_ready,

    // Output AXI4-Stream (no backpressure — consumer must always accept)
    output reg         m_axis_tvalid,
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tlast,

    // Status
    output wire        headers_done    // High when scan data can flow
);

generate
if (LITE_MODE == 0) begin : g_full_header
    // ====================================================================
    // FULL MODE: Dynamic DQT, multi-state FSM
    // ====================================================================

    // Zigzag order ROM (raster-to-zigzag index mapping for DQT output)
    reg [5:0] zigzag_order [0:63];
    /* verilator coverage_off */
    initial begin
        zigzag_order[ 0]=6'd0;  zigzag_order[ 1]=6'd1;  zigzag_order[ 2]=6'd8;  zigzag_order[ 3]=6'd16;
        zigzag_order[ 4]=6'd9;  zigzag_order[ 5]=6'd2;  zigzag_order[ 6]=6'd3;  zigzag_order[ 7]=6'd10;
        zigzag_order[ 8]=6'd17; zigzag_order[ 9]=6'd24; zigzag_order[10]=6'd32; zigzag_order[11]=6'd25;
        zigzag_order[12]=6'd18; zigzag_order[13]=6'd11; zigzag_order[14]=6'd4;  zigzag_order[15]=6'd5;
        zigzag_order[16]=6'd12; zigzag_order[17]=6'd19; zigzag_order[18]=6'd26; zigzag_order[19]=6'd33;
        zigzag_order[20]=6'd40; zigzag_order[21]=6'd48; zigzag_order[22]=6'd41; zigzag_order[23]=6'd34;
        zigzag_order[24]=6'd27; zigzag_order[25]=6'd20; zigzag_order[26]=6'd13; zigzag_order[27]=6'd6;
        zigzag_order[28]=6'd7;  zigzag_order[29]=6'd14; zigzag_order[30]=6'd21; zigzag_order[31]=6'd28;
        zigzag_order[32]=6'd35; zigzag_order[33]=6'd42; zigzag_order[34]=6'd49; zigzag_order[35]=6'd56;
        zigzag_order[36]=6'd57; zigzag_order[37]=6'd50; zigzag_order[38]=6'd43; zigzag_order[39]=6'd36;
        zigzag_order[40]=6'd29; zigzag_order[41]=6'd22; zigzag_order[42]=6'd15; zigzag_order[43]=6'd23;
        zigzag_order[44]=6'd30; zigzag_order[45]=6'd37; zigzag_order[46]=6'd44; zigzag_order[47]=6'd51;
        zigzag_order[48]=6'd58; zigzag_order[49]=6'd59; zigzag_order[50]=6'd52; zigzag_order[51]=6'd45;
        zigzag_order[52]=6'd38; zigzag_order[53]=6'd31; zigzag_order[54]=6'd39; zigzag_order[55]=6'd46;
        zigzag_order[56]=6'd53; zigzag_order[57]=6'd60; zigzag_order[58]=6'd61; zigzag_order[59]=6'd54;
        zigzag_order[60]=6'd47; zigzag_order[61]=6'd55; zigzag_order[62]=6'd62; zigzag_order[63]=6'd63;
    end
    /* verilator coverage_on */

    // DHT ROM - all 4 Huffman tables (432 bytes)
    localparam DHT_SIZE = 432;
    reg [7:0] dht_rom [0:DHT_SIZE-1];

    /* verilator coverage_off */
    initial begin : dht_init
        integer idx, i;
        idx = 0;

        // --- DHT DC Luminance (class=0, id=0) --- Length=31
        dht_rom[idx]=8'hFF; idx=idx+1; dht_rom[idx]=8'hC4; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h1F; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h05; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        for (i = 0; i < 12; i = i + 1) begin
            dht_rom[idx] = i[7:0]; idx = idx + 1;
        end

        // --- DHT AC Luminance (class=1, id=0) --- Length=181
        dht_rom[idx]=8'hFF; idx=idx+1; dht_rom[idx]=8'hC4; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'hB5; idx=idx+1;
        dht_rom[idx]=8'h10; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h02; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h03; idx=idx+1;
        dht_rom[idx]=8'h03; idx=idx+1; dht_rom[idx]=8'h02; idx=idx+1;
        dht_rom[idx]=8'h04; idx=idx+1; dht_rom[idx]=8'h03; idx=idx+1;
        dht_rom[idx]=8'h05; idx=idx+1; dht_rom[idx]=8'h05; idx=idx+1;
        dht_rom[idx]=8'h04; idx=idx+1; dht_rom[idx]=8'h04; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h7D; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h02; idx=idx+1;
        dht_rom[idx]=8'h03; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h04; idx=idx+1; dht_rom[idx]=8'h11; idx=idx+1;
        dht_rom[idx]=8'h05; idx=idx+1; dht_rom[idx]=8'h12; idx=idx+1;
        dht_rom[idx]=8'h21; idx=idx+1; dht_rom[idx]=8'h31; idx=idx+1;
        dht_rom[idx]=8'h41; idx=idx+1; dht_rom[idx]=8'h06; idx=idx+1;
        dht_rom[idx]=8'h13; idx=idx+1; dht_rom[idx]=8'h51; idx=idx+1;
        dht_rom[idx]=8'h61; idx=idx+1; dht_rom[idx]=8'h07; idx=idx+1;
        dht_rom[idx]=8'h22; idx=idx+1; dht_rom[idx]=8'h71; idx=idx+1;
        dht_rom[idx]=8'h14; idx=idx+1; dht_rom[idx]=8'h32; idx=idx+1;
        dht_rom[idx]=8'h81; idx=idx+1; dht_rom[idx]=8'h91; idx=idx+1;
        dht_rom[idx]=8'hA1; idx=idx+1; dht_rom[idx]=8'h08; idx=idx+1;
        dht_rom[idx]=8'h23; idx=idx+1; dht_rom[idx]=8'h42; idx=idx+1;
        dht_rom[idx]=8'hB1; idx=idx+1; dht_rom[idx]=8'hC1; idx=idx+1;
        dht_rom[idx]=8'h15; idx=idx+1; dht_rom[idx]=8'h52; idx=idx+1;
        dht_rom[idx]=8'hD1; idx=idx+1; dht_rom[idx]=8'hF0; idx=idx+1;
        dht_rom[idx]=8'h24; idx=idx+1; dht_rom[idx]=8'h33; idx=idx+1;
        dht_rom[idx]=8'h62; idx=idx+1; dht_rom[idx]=8'h72; idx=idx+1;
        dht_rom[idx]=8'h82; idx=idx+1; dht_rom[idx]=8'h09; idx=idx+1;
        dht_rom[idx]=8'h0A; idx=idx+1; dht_rom[idx]=8'h16; idx=idx+1;
        dht_rom[idx]=8'h17; idx=idx+1; dht_rom[idx]=8'h18; idx=idx+1;
        dht_rom[idx]=8'h19; idx=idx+1; dht_rom[idx]=8'h1A; idx=idx+1;
        dht_rom[idx]=8'h25; idx=idx+1; dht_rom[idx]=8'h26; idx=idx+1;
        dht_rom[idx]=8'h27; idx=idx+1; dht_rom[idx]=8'h28; idx=idx+1;
        dht_rom[idx]=8'h29; idx=idx+1; dht_rom[idx]=8'h2A; idx=idx+1;
        dht_rom[idx]=8'h34; idx=idx+1; dht_rom[idx]=8'h35; idx=idx+1;
        dht_rom[idx]=8'h36; idx=idx+1; dht_rom[idx]=8'h37; idx=idx+1;
        dht_rom[idx]=8'h38; idx=idx+1; dht_rom[idx]=8'h39; idx=idx+1;
        dht_rom[idx]=8'h3A; idx=idx+1; dht_rom[idx]=8'h43; idx=idx+1;
        dht_rom[idx]=8'h44; idx=idx+1; dht_rom[idx]=8'h45; idx=idx+1;
        dht_rom[idx]=8'h46; idx=idx+1; dht_rom[idx]=8'h47; idx=idx+1;
        dht_rom[idx]=8'h48; idx=idx+1; dht_rom[idx]=8'h49; idx=idx+1;
        dht_rom[idx]=8'h4A; idx=idx+1; dht_rom[idx]=8'h53; idx=idx+1;
        dht_rom[idx]=8'h54; idx=idx+1; dht_rom[idx]=8'h55; idx=idx+1;
        dht_rom[idx]=8'h56; idx=idx+1; dht_rom[idx]=8'h57; idx=idx+1;
        dht_rom[idx]=8'h58; idx=idx+1; dht_rom[idx]=8'h59; idx=idx+1;
        dht_rom[idx]=8'h5A; idx=idx+1; dht_rom[idx]=8'h63; idx=idx+1;
        dht_rom[idx]=8'h64; idx=idx+1; dht_rom[idx]=8'h65; idx=idx+1;
        dht_rom[idx]=8'h66; idx=idx+1; dht_rom[idx]=8'h67; idx=idx+1;
        dht_rom[idx]=8'h68; idx=idx+1; dht_rom[idx]=8'h69; idx=idx+1;
        dht_rom[idx]=8'h6A; idx=idx+1; dht_rom[idx]=8'h73; idx=idx+1;
        dht_rom[idx]=8'h74; idx=idx+1; dht_rom[idx]=8'h75; idx=idx+1;
        dht_rom[idx]=8'h76; idx=idx+1; dht_rom[idx]=8'h77; idx=idx+1;
        dht_rom[idx]=8'h78; idx=idx+1; dht_rom[idx]=8'h79; idx=idx+1;
        dht_rom[idx]=8'h7A; idx=idx+1; dht_rom[idx]=8'h83; idx=idx+1;
        dht_rom[idx]=8'h84; idx=idx+1; dht_rom[idx]=8'h85; idx=idx+1;
        dht_rom[idx]=8'h86; idx=idx+1; dht_rom[idx]=8'h87; idx=idx+1;
        dht_rom[idx]=8'h88; idx=idx+1; dht_rom[idx]=8'h89; idx=idx+1;
        dht_rom[idx]=8'h8A; idx=idx+1; dht_rom[idx]=8'h92; idx=idx+1;
        dht_rom[idx]=8'h93; idx=idx+1; dht_rom[idx]=8'h94; idx=idx+1;
        dht_rom[idx]=8'h95; idx=idx+1; dht_rom[idx]=8'h96; idx=idx+1;
        dht_rom[idx]=8'h97; idx=idx+1; dht_rom[idx]=8'h98; idx=idx+1;
        dht_rom[idx]=8'h99; idx=idx+1; dht_rom[idx]=8'h9A; idx=idx+1;
        dht_rom[idx]=8'hA2; idx=idx+1; dht_rom[idx]=8'hA3; idx=idx+1;
        dht_rom[idx]=8'hA4; idx=idx+1; dht_rom[idx]=8'hA5; idx=idx+1;
        dht_rom[idx]=8'hA6; idx=idx+1; dht_rom[idx]=8'hA7; idx=idx+1;
        dht_rom[idx]=8'hA8; idx=idx+1; dht_rom[idx]=8'hA9; idx=idx+1;
        dht_rom[idx]=8'hAA; idx=idx+1; dht_rom[idx]=8'hB2; idx=idx+1;
        dht_rom[idx]=8'hB3; idx=idx+1; dht_rom[idx]=8'hB4; idx=idx+1;
        dht_rom[idx]=8'hB5; idx=idx+1; dht_rom[idx]=8'hB6; idx=idx+1;
        dht_rom[idx]=8'hB7; idx=idx+1; dht_rom[idx]=8'hB8; idx=idx+1;
        dht_rom[idx]=8'hB9; idx=idx+1; dht_rom[idx]=8'hBA; idx=idx+1;
        dht_rom[idx]=8'hC2; idx=idx+1; dht_rom[idx]=8'hC3; idx=idx+1;
        dht_rom[idx]=8'hC4; idx=idx+1; dht_rom[idx]=8'hC5; idx=idx+1;
        dht_rom[idx]=8'hC6; idx=idx+1; dht_rom[idx]=8'hC7; idx=idx+1;
        dht_rom[idx]=8'hC8; idx=idx+1; dht_rom[idx]=8'hC9; idx=idx+1;
        dht_rom[idx]=8'hCA; idx=idx+1; dht_rom[idx]=8'hD2; idx=idx+1;
        dht_rom[idx]=8'hD3; idx=idx+1; dht_rom[idx]=8'hD4; idx=idx+1;
        dht_rom[idx]=8'hD5; idx=idx+1; dht_rom[idx]=8'hD6; idx=idx+1;
        dht_rom[idx]=8'hD7; idx=idx+1; dht_rom[idx]=8'hD8; idx=idx+1;
        dht_rom[idx]=8'hD9; idx=idx+1; dht_rom[idx]=8'hDA; idx=idx+1;
        dht_rom[idx]=8'hE1; idx=idx+1; dht_rom[idx]=8'hE2; idx=idx+1;
        dht_rom[idx]=8'hE3; idx=idx+1; dht_rom[idx]=8'hE4; idx=idx+1;
        dht_rom[idx]=8'hE5; idx=idx+1; dht_rom[idx]=8'hE6; idx=idx+1;
        dht_rom[idx]=8'hE7; idx=idx+1; dht_rom[idx]=8'hE8; idx=idx+1;
        dht_rom[idx]=8'hE9; idx=idx+1; dht_rom[idx]=8'hEA; idx=idx+1;
        dht_rom[idx]=8'hF1; idx=idx+1; dht_rom[idx]=8'hF2; idx=idx+1;
        dht_rom[idx]=8'hF3; idx=idx+1; dht_rom[idx]=8'hF4; idx=idx+1;
        dht_rom[idx]=8'hF5; idx=idx+1; dht_rom[idx]=8'hF6; idx=idx+1;
        dht_rom[idx]=8'hF7; idx=idx+1; dht_rom[idx]=8'hF8; idx=idx+1;
        dht_rom[idx]=8'hF9; idx=idx+1; dht_rom[idx]=8'hFA; idx=idx+1;

        // --- DHT DC Chrominance (class=0, id=1) --- Length=31
        dht_rom[idx]=8'hFF; idx=idx+1; dht_rom[idx]=8'hC4; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h1F; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h03; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h00; idx=idx+1;
        for (i = 0; i < 12; i = i + 1) begin
            dht_rom[idx] = i[7:0]; idx = idx + 1;
        end

        // --- DHT AC Chrominance (class=1, id=1) --- Length=181
        dht_rom[idx]=8'hFF; idx=idx+1; dht_rom[idx]=8'hC4; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'hB5; idx=idx+1;
        dht_rom[idx]=8'h11; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h02; idx=idx+1;
        dht_rom[idx]=8'h01; idx=idx+1; dht_rom[idx]=8'h02; idx=idx+1;
        dht_rom[idx]=8'h04; idx=idx+1; dht_rom[idx]=8'h04; idx=idx+1;
        dht_rom[idx]=8'h03; idx=idx+1; dht_rom[idx]=8'h04; idx=idx+1;
        dht_rom[idx]=8'h07; idx=idx+1; dht_rom[idx]=8'h05; idx=idx+1;
        dht_rom[idx]=8'h04; idx=idx+1; dht_rom[idx]=8'h04; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h02; idx=idx+1; dht_rom[idx]=8'h77; idx=idx+1;
        dht_rom[idx]=8'h00; idx=idx+1; dht_rom[idx]=8'h01; idx=idx+1;
        dht_rom[idx]=8'h02; idx=idx+1; dht_rom[idx]=8'h03; idx=idx+1;
        dht_rom[idx]=8'h11; idx=idx+1; dht_rom[idx]=8'h04; idx=idx+1;
        dht_rom[idx]=8'h05; idx=idx+1; dht_rom[idx]=8'h21; idx=idx+1;
        dht_rom[idx]=8'h31; idx=idx+1; dht_rom[idx]=8'h06; idx=idx+1;
        dht_rom[idx]=8'h12; idx=idx+1; dht_rom[idx]=8'h41; idx=idx+1;
        dht_rom[idx]=8'h51; idx=idx+1; dht_rom[idx]=8'h07; idx=idx+1;
        dht_rom[idx]=8'h61; idx=idx+1; dht_rom[idx]=8'h71; idx=idx+1;
        dht_rom[idx]=8'h13; idx=idx+1; dht_rom[idx]=8'h22; idx=idx+1;
        dht_rom[idx]=8'h32; idx=idx+1; dht_rom[idx]=8'h81; idx=idx+1;
        dht_rom[idx]=8'h08; idx=idx+1; dht_rom[idx]=8'h14; idx=idx+1;
        dht_rom[idx]=8'h42; idx=idx+1; dht_rom[idx]=8'h91; idx=idx+1;
        dht_rom[idx]=8'hA1; idx=idx+1; dht_rom[idx]=8'hB1; idx=idx+1;
        dht_rom[idx]=8'hC1; idx=idx+1; dht_rom[idx]=8'h09; idx=idx+1;
        dht_rom[idx]=8'h23; idx=idx+1; dht_rom[idx]=8'h33; idx=idx+1;
        dht_rom[idx]=8'h52; idx=idx+1; dht_rom[idx]=8'hF0; idx=idx+1;
        dht_rom[idx]=8'h15; idx=idx+1; dht_rom[idx]=8'h62; idx=idx+1;
        dht_rom[idx]=8'h72; idx=idx+1; dht_rom[idx]=8'hD1; idx=idx+1;
        dht_rom[idx]=8'h0A; idx=idx+1; dht_rom[idx]=8'h16; idx=idx+1;
        dht_rom[idx]=8'h24; idx=idx+1; dht_rom[idx]=8'h34; idx=idx+1;
        dht_rom[idx]=8'hE1; idx=idx+1; dht_rom[idx]=8'h25; idx=idx+1;
        dht_rom[idx]=8'hF1; idx=idx+1; dht_rom[idx]=8'h17; idx=idx+1;
        dht_rom[idx]=8'h18; idx=idx+1; dht_rom[idx]=8'h19; idx=idx+1;
        dht_rom[idx]=8'h1A; idx=idx+1; dht_rom[idx]=8'h26; idx=idx+1;
        dht_rom[idx]=8'h27; idx=idx+1; dht_rom[idx]=8'h28; idx=idx+1;
        dht_rom[idx]=8'h29; idx=idx+1; dht_rom[idx]=8'h2A; idx=idx+1;
        dht_rom[idx]=8'h35; idx=idx+1; dht_rom[idx]=8'h36; idx=idx+1;
        dht_rom[idx]=8'h37; idx=idx+1; dht_rom[idx]=8'h38; idx=idx+1;
        dht_rom[idx]=8'h39; idx=idx+1; dht_rom[idx]=8'h3A; idx=idx+1;
        dht_rom[idx]=8'h43; idx=idx+1; dht_rom[idx]=8'h44; idx=idx+1;
        dht_rom[idx]=8'h45; idx=idx+1; dht_rom[idx]=8'h46; idx=idx+1;
        dht_rom[idx]=8'h47; idx=idx+1; dht_rom[idx]=8'h48; idx=idx+1;
        dht_rom[idx]=8'h49; idx=idx+1; dht_rom[idx]=8'h4A; idx=idx+1;
        dht_rom[idx]=8'h53; idx=idx+1; dht_rom[idx]=8'h54; idx=idx+1;
        dht_rom[idx]=8'h55; idx=idx+1; dht_rom[idx]=8'h56; idx=idx+1;
        dht_rom[idx]=8'h57; idx=idx+1; dht_rom[idx]=8'h58; idx=idx+1;
        dht_rom[idx]=8'h59; idx=idx+1; dht_rom[idx]=8'h5A; idx=idx+1;
        dht_rom[idx]=8'h63; idx=idx+1; dht_rom[idx]=8'h64; idx=idx+1;
        dht_rom[idx]=8'h65; idx=idx+1; dht_rom[idx]=8'h66; idx=idx+1;
        dht_rom[idx]=8'h67; idx=idx+1; dht_rom[idx]=8'h68; idx=idx+1;
        dht_rom[idx]=8'h69; idx=idx+1; dht_rom[idx]=8'h6A; idx=idx+1;
        dht_rom[idx]=8'h73; idx=idx+1; dht_rom[idx]=8'h74; idx=idx+1;
        dht_rom[idx]=8'h75; idx=idx+1; dht_rom[idx]=8'h76; idx=idx+1;
        dht_rom[idx]=8'h77; idx=idx+1; dht_rom[idx]=8'h78; idx=idx+1;
        dht_rom[idx]=8'h79; idx=idx+1; dht_rom[idx]=8'h7A; idx=idx+1;
        dht_rom[idx]=8'h82; idx=idx+1; dht_rom[idx]=8'h83; idx=idx+1;
        dht_rom[idx]=8'h84; idx=idx+1; dht_rom[idx]=8'h85; idx=idx+1;
        dht_rom[idx]=8'h86; idx=idx+1; dht_rom[idx]=8'h87; idx=idx+1;
        dht_rom[idx]=8'h88; idx=idx+1; dht_rom[idx]=8'h89; idx=idx+1;
        dht_rom[idx]=8'h8A; idx=idx+1; dht_rom[idx]=8'h92; idx=idx+1;
        dht_rom[idx]=8'h93; idx=idx+1; dht_rom[idx]=8'h94; idx=idx+1;
        dht_rom[idx]=8'h95; idx=idx+1; dht_rom[idx]=8'h96; idx=idx+1;
        dht_rom[idx]=8'h97; idx=idx+1; dht_rom[idx]=8'h98; idx=idx+1;
        dht_rom[idx]=8'h99; idx=idx+1; dht_rom[idx]=8'h9A; idx=idx+1;
        dht_rom[idx]=8'hA2; idx=idx+1; dht_rom[idx]=8'hA3; idx=idx+1;
        dht_rom[idx]=8'hA4; idx=idx+1; dht_rom[idx]=8'hA5; idx=idx+1;
        dht_rom[idx]=8'hA6; idx=idx+1; dht_rom[idx]=8'hA7; idx=idx+1;
        dht_rom[idx]=8'hA8; idx=idx+1; dht_rom[idx]=8'hA9; idx=idx+1;
        dht_rom[idx]=8'hAA; idx=idx+1; dht_rom[idx]=8'hB2; idx=idx+1;
        dht_rom[idx]=8'hB3; idx=idx+1; dht_rom[idx]=8'hB4; idx=idx+1;
        dht_rom[idx]=8'hB5; idx=idx+1; dht_rom[idx]=8'hB6; idx=idx+1;
        dht_rom[idx]=8'hB7; idx=idx+1; dht_rom[idx]=8'hB8; idx=idx+1;
        dht_rom[idx]=8'hB9; idx=idx+1; dht_rom[idx]=8'hBA; idx=idx+1;
        dht_rom[idx]=8'hC2; idx=idx+1; dht_rom[idx]=8'hC3; idx=idx+1;
        dht_rom[idx]=8'hC4; idx=idx+1; dht_rom[idx]=8'hC5; idx=idx+1;
        dht_rom[idx]=8'hC6; idx=idx+1; dht_rom[idx]=8'hC7; idx=idx+1;
        dht_rom[idx]=8'hC8; idx=idx+1; dht_rom[idx]=8'hC9; idx=idx+1;
        dht_rom[idx]=8'hCA; idx=idx+1; dht_rom[idx]=8'hD2; idx=idx+1;
        dht_rom[idx]=8'hD3; idx=idx+1; dht_rom[idx]=8'hD4; idx=idx+1;
        dht_rom[idx]=8'hD5; idx=idx+1; dht_rom[idx]=8'hD6; idx=idx+1;
        dht_rom[idx]=8'hD7; idx=idx+1; dht_rom[idx]=8'hD8; idx=idx+1;
        dht_rom[idx]=8'hD9; idx=idx+1; dht_rom[idx]=8'hDA; idx=idx+1;
        dht_rom[idx]=8'hE2; idx=idx+1; dht_rom[idx]=8'hE3; idx=idx+1;
        dht_rom[idx]=8'hE4; idx=idx+1; dht_rom[idx]=8'hE5; idx=idx+1;
        dht_rom[idx]=8'hE6; idx=idx+1; dht_rom[idx]=8'hE7; idx=idx+1;
        dht_rom[idx]=8'hE8; idx=idx+1; dht_rom[idx]=8'hE9; idx=idx+1;
        dht_rom[idx]=8'hEA; idx=idx+1; dht_rom[idx]=8'hF2; idx=idx+1;
        dht_rom[idx]=8'hF3; idx=idx+1; dht_rom[idx]=8'hF4; idx=idx+1;
        dht_rom[idx]=8'hF5; idx=idx+1; dht_rom[idx]=8'hF6; idx=idx+1;
        dht_rom[idx]=8'hF7; idx=idx+1; dht_rom[idx]=8'hF8; idx=idx+1;
        dht_rom[idx]=8'hF9; idx=idx+1; dht_rom[idx]=8'hFA; idx=idx+1;
    end

    // SOF0 data (19 bytes)
    reg [7:0] sof0_rom [0:18];
    initial begin
        sof0_rom[ 0] = 8'hFF; sof0_rom[ 1] = 8'hC0;
        sof0_rom[ 2] = 8'h00; sof0_rom[ 3] = 8'h11;
        sof0_rom[ 4] = 8'h08;
        sof0_rom[ 5] = IMG_HEIGHT[15:8]; sof0_rom[ 6] = IMG_HEIGHT[7:0];
        sof0_rom[ 7] = IMG_WIDTH[15:8];  sof0_rom[ 8] = IMG_WIDTH[7:0];
        sof0_rom[ 9] = 8'h03;
        sof0_rom[10] = 8'h01; sof0_rom[11] = 8'h21; sof0_rom[12] = 8'h00;
        sof0_rom[13] = 8'h02; sof0_rom[14] = 8'h11; sof0_rom[15] = 8'h01;
        sof0_rom[16] = 8'h03; sof0_rom[17] = 8'h11; sof0_rom[18] = 8'h01;
    end

    // SOS data (14 bytes)
    reg [7:0] sos_rom [0:13];
    initial begin
        sos_rom[ 0] = 8'hFF; sos_rom[ 1] = 8'hDA;
        sos_rom[ 2] = 8'h00; sos_rom[ 3] = 8'h0C;
        sos_rom[ 4] = 8'h03;
        sos_rom[ 5] = 8'h01; sos_rom[ 6] = 8'h00;
        sos_rom[ 7] = 8'h02; sos_rom[ 8] = 8'h11;
        sos_rom[ 9] = 8'h03; sos_rom[10] = 8'h11;
        sos_rom[11] = 8'h00; sos_rom[12] = 8'h3F; sos_rom[13] = 8'h00;
    end

    // SOI + APP0 (20 bytes)
    reg [7:0] soi_app0_rom [0:19];
    initial begin
        soi_app0_rom[ 0] = 8'hFF; soi_app0_rom[ 1] = 8'hD8;
        soi_app0_rom[ 2] = 8'hFF; soi_app0_rom[ 3] = 8'hE0;
        soi_app0_rom[ 4] = 8'h00; soi_app0_rom[ 5] = 8'h10;
        soi_app0_rom[ 6] = 8'h4A; soi_app0_rom[ 7] = 8'h46;
        soi_app0_rom[ 8] = 8'h49; soi_app0_rom[ 9] = 8'h46;
        soi_app0_rom[10] = 8'h00; soi_app0_rom[11] = 8'h01;
        soi_app0_rom[12] = 8'h01; soi_app0_rom[13] = 8'h00;
        soi_app0_rom[14] = 8'h00; soi_app0_rom[15] = 8'h01;
        soi_app0_rom[16] = 8'h00; soi_app0_rom[17] = 8'h01;
        soi_app0_rom[18] = 8'h00; soi_app0_rom[19] = 8'h00;
    end
    /* verilator coverage_on */

    // State machine
    localparam S_IDLE         = 4'd0;
    localparam S_SOI_APP0     = 4'd1;
    localparam S_DQT_L_HDR   = 4'd2;
    localparam S_DQT_L_DATA  = 4'd3;
    localparam S_DQT_C_HDR   = 4'd4;
    localparam S_DQT_C_DATA  = 4'd5;
    localparam S_SOF0        = 4'd6;
    localparam S_DRI         = 4'd7;
    localparam S_DHT         = 4'd8;
    localparam S_SOS         = 4'd9;
    localparam S_SCAN_DATA   = 4'd10;
    localparam S_EOI_0       = 4'd11;
    localparam S_EOI_1       = 4'd12;
    localparam S_DONE        = 4'd13;

    reg [3:0]  state;
    reg [9:0]  seg_idx;
    reg        qt_data_valid;

    assign scan_ready = (state == S_SCAN_DATA);
    assign headers_done = (state == S_SCAN_DATA) || (state == S_EOI_0) ||
                          (state == S_EOI_1) || (state == S_DONE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            seg_idx       <= 10'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 8'd0;
            m_axis_tlast  <= 1'b0;
            qt_rd_addr    <= 6'd0;
            qt_rd_is_chroma <= 1'b0;
            qt_data_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    qt_data_valid <= 1'b0;
                    if (frame_start) begin
                        state   <= S_SOI_APP0;
                        seg_idx <= 10'd0;
                    end
                end

                S_SOI_APP0: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= soi_app0_rom[seg_idx[4:0]];
                    if (seg_idx == 10'd19) begin
                        state   <= S_DQT_L_HDR;
                        seg_idx <= 10'd0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_DQT_L_HDR: begin
                    m_axis_tvalid <= 1'b1;
                    case (seg_idx[2:0])
                        3'd0: m_axis_tdata <= 8'hFF;
                        3'd1: m_axis_tdata <= 8'hDB;
                        3'd2: m_axis_tdata <= 8'h00;
                        3'd3: m_axis_tdata <= 8'h43;
                        3'd4: m_axis_tdata <= 8'h00;
                        default: m_axis_tdata <= 8'h00;
                    endcase
                    if (seg_idx == 10'd4) begin
                        state   <= S_DQT_L_DATA;
                        seg_idx <= 10'd0;
                        qt_rd_addr      <= zigzag_order[0];
                        qt_rd_is_chroma <= 1'b0;
                        qt_data_valid   <= 1'b0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_DQT_L_DATA: begin
                    if (!qt_data_valid) begin
                        m_axis_tvalid <= 1'b0;
                        qt_data_valid <= 1'b1;
                        if (seg_idx < 10'd63)
                            qt_rd_addr <= zigzag_order[seg_idx[5:0] + 6'd1];
                    end else begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata  <= qt_rd_data;
                        if (seg_idx == 10'd63) begin
                            state   <= S_DQT_C_HDR;
                            seg_idx <= 10'd0;
                            qt_data_valid <= 1'b0;
                        end else begin
                            seg_idx <= seg_idx + 10'd1;
                            if (seg_idx + 10'd1 < 10'd63)
                                qt_rd_addr <= zigzag_order[seg_idx[5:0] + 6'd2];
                            else
                                qt_rd_addr <= zigzag_order[63];
                        end
                    end
                end

                S_DQT_C_HDR: begin
                    m_axis_tvalid <= 1'b1;
                    case (seg_idx[2:0])
                        3'd0: m_axis_tdata <= 8'hFF;
                        3'd1: m_axis_tdata <= 8'hDB;
                        3'd2: m_axis_tdata <= 8'h00;
                        3'd3: m_axis_tdata <= 8'h43;
                        3'd4: m_axis_tdata <= 8'h01;
                        default: m_axis_tdata <= 8'h00;
                    endcase
                    if (seg_idx == 10'd4) begin
                        state   <= S_DQT_C_DATA;
                        seg_idx <= 10'd0;
                        qt_rd_addr      <= zigzag_order[0];
                        qt_rd_is_chroma <= 1'b1;
                        qt_data_valid   <= 1'b0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_DQT_C_DATA: begin
                    if (!qt_data_valid) begin
                        m_axis_tvalid <= 1'b0;
                        qt_data_valid <= 1'b1;
                        if (seg_idx < 10'd63)
                            qt_rd_addr <= zigzag_order[seg_idx[5:0] + 6'd1];
                    end else begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata  <= qt_rd_data;
                        if (seg_idx == 10'd63) begin
                            state   <= S_SOF0;
                            seg_idx <= 10'd0;
                            qt_data_valid <= 1'b0;
                        end else begin
                            seg_idx <= seg_idx + 10'd1;
                            if (seg_idx + 10'd1 < 10'd63)
                                qt_rd_addr <= zigzag_order[seg_idx[5:0] + 6'd2];
                            else
                                qt_rd_addr <= zigzag_order[63];
                        end
                    end
                end

                S_SOF0: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= sof0_rom[seg_idx[4:0]];
                    if (seg_idx == 10'd18) begin
                        seg_idx <= 10'd0;
                        if (restart_interval != 16'd0)
                            state <= S_DRI;
                        else
                            state <= S_DHT;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_DRI: begin
                    m_axis_tvalid <= 1'b1;
                    case (seg_idx[2:0])
                        3'd0: m_axis_tdata <= 8'hFF;
                        3'd1: m_axis_tdata <= 8'hDD;
                        3'd2: m_axis_tdata <= 8'h00;
                        3'd3: m_axis_tdata <= 8'h04;
                        3'd4: m_axis_tdata <= restart_interval[15:8];
                        3'd5: m_axis_tdata <= restart_interval[7:0];
                        default: m_axis_tdata <= 8'h00;
                    endcase
                    if (seg_idx == 10'd5) begin
                        state   <= S_DHT;
                        seg_idx <= 10'd0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_DHT: begin
                    m_axis_tvalid <= 1'b1;
                    /* verilator lint_off WIDTHTRUNC */
                    m_axis_tdata  <= dht_rom[seg_idx];
                    /* verilator lint_on WIDTHTRUNC */
                    if (seg_idx == DHT_SIZE[9:0] - 10'd1) begin
                        state   <= S_SOS;
                        seg_idx <= 10'd0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_SOS: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= sos_rom[seg_idx[3:0]];
                    if (seg_idx == 10'd13) begin
                        state   <= S_SCAN_DATA;
                        seg_idx <= 10'd0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                S_SCAN_DATA: begin
                    if (scan_valid && scan_last) begin
                        m_axis_tvalid <= 1'b0;
                        state <= S_EOI_0;
                    end else begin
                        m_axis_tvalid <= scan_valid;
                        m_axis_tdata  <= scan_data;
                        m_axis_tlast  <= 1'b0;
                    end
                end

                S_EOI_0: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;
                    state <= S_EOI_1;
                end

                S_EOI_1: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= 8'hD9;
                    m_axis_tlast  <= 1'b1;
                    state <= S_DONE;
                end

                S_DONE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

end else begin : g_lite_header
    // ====================================================================
    // LITE MODE: Fixed header ROM (LITE_QUALITY param), simplified FSM
    // ====================================================================

    // Fixed JFIF header ROM (DQT computed from LITE_QUALITY at elaboration)
    // SOI(2) + APP0(18) + DQT_L(69) + DQT_C(69) + SOF0(19) + DHT(432) + SOS(14) = 623
    // SOF0 ends at byte 176, DHT starts at byte 177
    localparam HEADER_SIZE = 623;
    localparam SOF0_END    = 176;   // Last byte of SOF0 (index 176)
    localparam DHT_START   = 177;   // First byte of DHT section

    reg [7:0] header_rom [0:HEADER_SIZE-1];

    /* verilator coverage_off */
    initial begin : init_lite_header
        integer scale, sq;

        // Compute quality scale factor (standard JPEG formula)
        if (LITE_QUALITY >= 50)
            scale = 200 - 2 * LITE_QUALITY;
        else if (LITE_QUALITY >= 1)
            scale = 5000 / LITE_QUALITY;
        else
            scale = 5000;

        // SOI + APP0 (20 bytes)
        header_rom[  0] = 8'hFF; header_rom[  1] = 8'hD8;
        header_rom[  2] = 8'hFF; header_rom[  3] = 8'hE0;
        header_rom[  4] = 8'h00; header_rom[  5] = 8'h10;
        header_rom[  6] = 8'h4A; header_rom[  7] = 8'h46;
        header_rom[  8] = 8'h49; header_rom[  9] = 8'h46;
        header_rom[ 10] = 8'h00; header_rom[ 11] = 8'h01;
        header_rom[ 12] = 8'h01; header_rom[ 13] = 8'h00;
        header_rom[ 14] = 8'h00; header_rom[ 15] = 8'h01;
        header_rom[ 16] = 8'h00; header_rom[ 17] = 8'h01;
        header_rom[ 18] = 8'h00; header_rom[ 19] = 8'h00;
        // DQT Luma header (5 bytes)
        header_rom[ 20] = 8'hFF; header_rom[ 21] = 8'hDB;
        header_rom[ 22] = 8'h00; header_rom[ 23] = 8'h43; header_rom[ 24] = 8'h00;
        // DQT Luma data (64 bytes, unrolled in zigzag order; literals avoid variable-indexed array reads
        // that Vivado cannot evaluate in initial blocks during synthesis elaboration)
        sq=(16*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[25]=sq[7:0];
        sq=(11*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[26]=sq[7:0];
        sq=(12*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[27]=sq[7:0];
        sq=(14*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[28]=sq[7:0];
        sq=(12*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[29]=sq[7:0];
        sq=(10*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[30]=sq[7:0];
        sq=(16*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[31]=sq[7:0];
        sq=(14*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[32]=sq[7:0];
        sq=(13*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[33]=sq[7:0];
        sq=(14*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[34]=sq[7:0];
        sq=(18*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[35]=sq[7:0];
        sq=(17*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[36]=sq[7:0];
        sq=(16*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[37]=sq[7:0];
        sq=(19*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[38]=sq[7:0];
        sq=(24*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[39]=sq[7:0];
        sq=(40*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[40]=sq[7:0];
        sq=(26*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[41]=sq[7:0];
        sq=(24*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[42]=sq[7:0];
        sq=(22*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[43]=sq[7:0];
        sq=(22*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[44]=sq[7:0];
        sq=(24*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[45]=sq[7:0];
        sq=(49*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[46]=sq[7:0];
        sq=(35*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[47]=sq[7:0];
        sq=(37*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[48]=sq[7:0];
        sq=(29*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[49]=sq[7:0];
        sq=(40*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[50]=sq[7:0];
        sq=(58*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[51]=sq[7:0];
        sq=(51*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[52]=sq[7:0];
        sq=(61*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[53]=sq[7:0];
        sq=(60*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[54]=sq[7:0];
        sq=(57*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[55]=sq[7:0];
        sq=(51*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[56]=sq[7:0];
        sq=(56*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[57]=sq[7:0];
        sq=(55*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[58]=sq[7:0];
        sq=(64*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[59]=sq[7:0];
        sq=(72*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[60]=sq[7:0];
        sq=(92*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[61]=sq[7:0];
        sq=(78*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[62]=sq[7:0];
        sq=(64*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[63]=sq[7:0];
        sq=(68*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[64]=sq[7:0];
        sq=(87*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[65]=sq[7:0];
        sq=(69*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[66]=sq[7:0];
        sq=(55*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[67]=sq[7:0];
        sq=(56*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[68]=sq[7:0];
        sq=(80*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[69]=sq[7:0];
        sq=(109*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[70]=sq[7:0];
        sq=(81*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[71]=sq[7:0];
        sq=(87*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[72]=sq[7:0];
        sq=(95*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[73]=sq[7:0];
        sq=(98*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[74]=sq[7:0];
        sq=(103*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[75]=sq[7:0];
        sq=(104*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[76]=sq[7:0];
        sq=(103*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[77]=sq[7:0];
        sq=(62*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[78]=sq[7:0];
        sq=(77*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[79]=sq[7:0];
        sq=(113*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[80]=sq[7:0];
        sq=(121*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[81]=sq[7:0];
        sq=(112*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[82]=sq[7:0];
        sq=(100*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[83]=sq[7:0];
        sq=(120*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[84]=sq[7:0];
        sq=(92*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[85]=sq[7:0];
        sq=(101*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[86]=sq[7:0];
        sq=(103*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[87]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[88]=sq[7:0];
        // DQT Chroma header (5 bytes)
        header_rom[ 89] = 8'hFF; header_rom[ 90] = 8'hDB;
        header_rom[ 91] = 8'h00; header_rom[ 92] = 8'h43; header_rom[ 93] = 8'h01;
        // DQT Chroma data (64 bytes, unrolled in zigzag order)
        sq=(17*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[94]=sq[7:0];
        sq=(18*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[95]=sq[7:0];
        sq=(18*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[96]=sq[7:0];
        sq=(24*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[97]=sq[7:0];
        sq=(21*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[98]=sq[7:0];
        sq=(24*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[99]=sq[7:0];
        sq=(47*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[100]=sq[7:0];
        sq=(26*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[101]=sq[7:0];
        sq=(26*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[102]=sq[7:0];
        sq=(47*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[103]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[104]=sq[7:0];
        sq=(66*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[105]=sq[7:0];
        sq=(56*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[106]=sq[7:0];
        sq=(66*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[107]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[108]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[109]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[110]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[111]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[112]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[113]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[114]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[115]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[116]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[117]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[118]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[119]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[120]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[121]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[122]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[123]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[124]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[125]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[126]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[127]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[128]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[129]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[130]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[131]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[132]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[133]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[134]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[135]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[136]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[137]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[138]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[139]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[140]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[141]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[142]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[143]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[144]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[145]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[146]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[147]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[148]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[149]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[150]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[151]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[152]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[153]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[154]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[155]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[156]=sq[7:0];
        sq=(99*scale+50)/100; if(sq<1)sq=1; if(sq>255)sq=255; header_rom[157]=sq[7:0];
        // SOF0 (19 bytes, indices 158-176)
        header_rom[158] = 8'hFF; header_rom[159] = 8'hC0;
        header_rom[160] = 8'h00; header_rom[161] = 8'h11;
        header_rom[162] = 8'h08;
        // Parameterized dimensions (override default 1280x720)
        header_rom[163] = IMG_HEIGHT[15:8];
        header_rom[164] = IMG_HEIGHT[7:0];
        header_rom[165] = IMG_WIDTH[15:8];
        header_rom[166] = IMG_WIDTH[7:0];
        header_rom[167] = 8'h03;
        header_rom[168] = 8'h01; header_rom[169] = 8'h21; header_rom[170] = 8'h00;
        header_rom[171] = 8'h02; header_rom[172] = 8'h11; header_rom[173] = 8'h01;
        header_rom[174] = 8'h03; header_rom[175] = 8'h11; header_rom[176] = 8'h01;
        // DHT tables (432 bytes, indices 177-608)
        header_rom[177] = 8'hFF; header_rom[178] = 8'hC4;
        header_rom[179] = 8'h00; header_rom[180] = 8'h1F; header_rom[181] = 8'h00;
        header_rom[182] = 8'h00; header_rom[183] = 8'h01; header_rom[184] = 8'h05;
        header_rom[185] = 8'h01; header_rom[186] = 8'h01; header_rom[187] = 8'h01;
        header_rom[188] = 8'h01; header_rom[189] = 8'h01; header_rom[190] = 8'h01;
        header_rom[191] = 8'h00; header_rom[192] = 8'h00; header_rom[193] = 8'h00;
        header_rom[194] = 8'h00; header_rom[195] = 8'h00; header_rom[196] = 8'h00;
        header_rom[197] = 8'h00; header_rom[198] = 8'h00; header_rom[199] = 8'h01;
        header_rom[200] = 8'h02; header_rom[201] = 8'h03; header_rom[202] = 8'h04;
        header_rom[203] = 8'h05; header_rom[204] = 8'h06; header_rom[205] = 8'h07;
        header_rom[206] = 8'h08; header_rom[207] = 8'h09; header_rom[208] = 8'h0A;
        header_rom[209] = 8'h0B;
        // AC Luma DHT
        header_rom[210] = 8'hFF; header_rom[211] = 8'hC4;
        header_rom[212] = 8'h00; header_rom[213] = 8'hB5; header_rom[214] = 8'h10;
        header_rom[215] = 8'h00; header_rom[216] = 8'h02; header_rom[217] = 8'h01;
        header_rom[218] = 8'h03; header_rom[219] = 8'h03; header_rom[220] = 8'h02;
        header_rom[221] = 8'h04; header_rom[222] = 8'h03; header_rom[223] = 8'h05;
        header_rom[224] = 8'h05; header_rom[225] = 8'h04; header_rom[226] = 8'h04;
        header_rom[227] = 8'h00; header_rom[228] = 8'h00; header_rom[229] = 8'h01;
        header_rom[230] = 8'h7D;
        header_rom[231] = 8'h01; header_rom[232] = 8'h02; header_rom[233] = 8'h03;
        header_rom[234] = 8'h00; header_rom[235] = 8'h04; header_rom[236] = 8'h11;
        header_rom[237] = 8'h05; header_rom[238] = 8'h12; header_rom[239] = 8'h21;
        header_rom[240] = 8'h31; header_rom[241] = 8'h41; header_rom[242] = 8'h06;
        header_rom[243] = 8'h13; header_rom[244] = 8'h51; header_rom[245] = 8'h61;
        header_rom[246] = 8'h07; header_rom[247] = 8'h22; header_rom[248] = 8'h71;
        header_rom[249] = 8'h14; header_rom[250] = 8'h32; header_rom[251] = 8'h81;
        header_rom[252] = 8'h91; header_rom[253] = 8'hA1; header_rom[254] = 8'h08;
        header_rom[255] = 8'h23; header_rom[256] = 8'h42; header_rom[257] = 8'hB1;
        header_rom[258] = 8'hC1; header_rom[259] = 8'h15; header_rom[260] = 8'h52;
        header_rom[261] = 8'hD1; header_rom[262] = 8'hF0; header_rom[263] = 8'h24;
        header_rom[264] = 8'h33; header_rom[265] = 8'h62; header_rom[266] = 8'h72;
        header_rom[267] = 8'h82; header_rom[268] = 8'h09; header_rom[269] = 8'h0A;
        header_rom[270] = 8'h16; header_rom[271] = 8'h17; header_rom[272] = 8'h18;
        header_rom[273] = 8'h19; header_rom[274] = 8'h1A; header_rom[275] = 8'h25;
        header_rom[276] = 8'h26; header_rom[277] = 8'h27; header_rom[278] = 8'h28;
        header_rom[279] = 8'h29; header_rom[280] = 8'h2A; header_rom[281] = 8'h34;
        header_rom[282] = 8'h35; header_rom[283] = 8'h36; header_rom[284] = 8'h37;
        header_rom[285] = 8'h38; header_rom[286] = 8'h39; header_rom[287] = 8'h3A;
        header_rom[288] = 8'h43; header_rom[289] = 8'h44; header_rom[290] = 8'h45;
        header_rom[291] = 8'h46; header_rom[292] = 8'h47; header_rom[293] = 8'h48;
        header_rom[294] = 8'h49; header_rom[295] = 8'h4A; header_rom[296] = 8'h53;
        header_rom[297] = 8'h54; header_rom[298] = 8'h55; header_rom[299] = 8'h56;
        header_rom[300] = 8'h57; header_rom[301] = 8'h58; header_rom[302] = 8'h59;
        header_rom[303] = 8'h5A; header_rom[304] = 8'h63; header_rom[305] = 8'h64;
        header_rom[306] = 8'h65; header_rom[307] = 8'h66; header_rom[308] = 8'h67;
        header_rom[309] = 8'h68; header_rom[310] = 8'h69; header_rom[311] = 8'h6A;
        header_rom[312] = 8'h73; header_rom[313] = 8'h74; header_rom[314] = 8'h75;
        header_rom[315] = 8'h76; header_rom[316] = 8'h77; header_rom[317] = 8'h78;
        header_rom[318] = 8'h79; header_rom[319] = 8'h7A; header_rom[320] = 8'h83;
        header_rom[321] = 8'h84; header_rom[322] = 8'h85; header_rom[323] = 8'h86;
        header_rom[324] = 8'h87; header_rom[325] = 8'h88; header_rom[326] = 8'h89;
        header_rom[327] = 8'h8A; header_rom[328] = 8'h92; header_rom[329] = 8'h93;
        header_rom[330] = 8'h94; header_rom[331] = 8'h95; header_rom[332] = 8'h96;
        header_rom[333] = 8'h97; header_rom[334] = 8'h98; header_rom[335] = 8'h99;
        header_rom[336] = 8'h9A; header_rom[337] = 8'hA2; header_rom[338] = 8'hA3;
        header_rom[339] = 8'hA4; header_rom[340] = 8'hA5; header_rom[341] = 8'hA6;
        header_rom[342] = 8'hA7; header_rom[343] = 8'hA8; header_rom[344] = 8'hA9;
        header_rom[345] = 8'hAA; header_rom[346] = 8'hB2; header_rom[347] = 8'hB3;
        header_rom[348] = 8'hB4; header_rom[349] = 8'hB5; header_rom[350] = 8'hB6;
        header_rom[351] = 8'hB7; header_rom[352] = 8'hB8; header_rom[353] = 8'hB9;
        header_rom[354] = 8'hBA; header_rom[355] = 8'hC2; header_rom[356] = 8'hC3;
        header_rom[357] = 8'hC4; header_rom[358] = 8'hC5; header_rom[359] = 8'hC6;
        header_rom[360] = 8'hC7; header_rom[361] = 8'hC8; header_rom[362] = 8'hC9;
        header_rom[363] = 8'hCA; header_rom[364] = 8'hD2; header_rom[365] = 8'hD3;
        header_rom[366] = 8'hD4; header_rom[367] = 8'hD5; header_rom[368] = 8'hD6;
        header_rom[369] = 8'hD7; header_rom[370] = 8'hD8; header_rom[371] = 8'hD9;
        header_rom[372] = 8'hDA; header_rom[373] = 8'hE1; header_rom[374] = 8'hE2;
        header_rom[375] = 8'hE3; header_rom[376] = 8'hE4; header_rom[377] = 8'hE5;
        header_rom[378] = 8'hE6; header_rom[379] = 8'hE7; header_rom[380] = 8'hE8;
        header_rom[381] = 8'hE9; header_rom[382] = 8'hEA; header_rom[383] = 8'hF1;
        header_rom[384] = 8'hF2; header_rom[385] = 8'hF3; header_rom[386] = 8'hF4;
        header_rom[387] = 8'hF5; header_rom[388] = 8'hF6; header_rom[389] = 8'hF7;
        header_rom[390] = 8'hF8; header_rom[391] = 8'hF9; header_rom[392] = 8'hFA;
        // DC Chroma DHT
        header_rom[393] = 8'hFF; header_rom[394] = 8'hC4;
        header_rom[395] = 8'h00; header_rom[396] = 8'h1F; header_rom[397] = 8'h01;
        header_rom[398] = 8'h00; header_rom[399] = 8'h03; header_rom[400] = 8'h01;
        header_rom[401] = 8'h01; header_rom[402] = 8'h01; header_rom[403] = 8'h01;
        header_rom[404] = 8'h01; header_rom[405] = 8'h01; header_rom[406] = 8'h01;
        header_rom[407] = 8'h01; header_rom[408] = 8'h01; header_rom[409] = 8'h00;
        header_rom[410] = 8'h00; header_rom[411] = 8'h00; header_rom[412] = 8'h00;
        header_rom[413] = 8'h00; header_rom[414] = 8'h00; header_rom[415] = 8'h01;
        header_rom[416] = 8'h02; header_rom[417] = 8'h03; header_rom[418] = 8'h04;
        header_rom[419] = 8'h05; header_rom[420] = 8'h06; header_rom[421] = 8'h07;
        header_rom[422] = 8'h08; header_rom[423] = 8'h09; header_rom[424] = 8'h0A;
        header_rom[425] = 8'h0B;
        // AC Chroma DHT
        header_rom[426] = 8'hFF; header_rom[427] = 8'hC4;
        header_rom[428] = 8'h00; header_rom[429] = 8'hB5; header_rom[430] = 8'h11;
        header_rom[431] = 8'h00; header_rom[432] = 8'h02; header_rom[433] = 8'h01;
        header_rom[434] = 8'h02; header_rom[435] = 8'h04; header_rom[436] = 8'h04;
        header_rom[437] = 8'h03; header_rom[438] = 8'h04; header_rom[439] = 8'h07;
        header_rom[440] = 8'h05; header_rom[441] = 8'h04; header_rom[442] = 8'h04;
        header_rom[443] = 8'h00; header_rom[444] = 8'h01; header_rom[445] = 8'h02;
        header_rom[446] = 8'h77;
        header_rom[447] = 8'h00; header_rom[448] = 8'h01; header_rom[449] = 8'h02;
        header_rom[450] = 8'h03; header_rom[451] = 8'h11; header_rom[452] = 8'h04;
        header_rom[453] = 8'h05; header_rom[454] = 8'h21; header_rom[455] = 8'h31;
        header_rom[456] = 8'h06; header_rom[457] = 8'h12; header_rom[458] = 8'h41;
        header_rom[459] = 8'h51; header_rom[460] = 8'h07; header_rom[461] = 8'h61;
        header_rom[462] = 8'h71; header_rom[463] = 8'h13; header_rom[464] = 8'h22;
        header_rom[465] = 8'h32; header_rom[466] = 8'h81; header_rom[467] = 8'h08;
        header_rom[468] = 8'h14; header_rom[469] = 8'h42; header_rom[470] = 8'h91;
        header_rom[471] = 8'hA1; header_rom[472] = 8'hB1; header_rom[473] = 8'hC1;
        header_rom[474] = 8'h09; header_rom[475] = 8'h23; header_rom[476] = 8'h33;
        header_rom[477] = 8'h52; header_rom[478] = 8'hF0; header_rom[479] = 8'h15;
        header_rom[480] = 8'h62; header_rom[481] = 8'h72; header_rom[482] = 8'hD1;
        header_rom[483] = 8'h0A; header_rom[484] = 8'h16; header_rom[485] = 8'h24;
        header_rom[486] = 8'h34; header_rom[487] = 8'hE1; header_rom[488] = 8'h25;
        header_rom[489] = 8'hF1; header_rom[490] = 8'h17; header_rom[491] = 8'h18;
        header_rom[492] = 8'h19; header_rom[493] = 8'h1A; header_rom[494] = 8'h26;
        header_rom[495] = 8'h27; header_rom[496] = 8'h28; header_rom[497] = 8'h29;
        header_rom[498] = 8'h2A; header_rom[499] = 8'h35; header_rom[500] = 8'h36;
        header_rom[501] = 8'h37; header_rom[502] = 8'h38; header_rom[503] = 8'h39;
        header_rom[504] = 8'h3A; header_rom[505] = 8'h43; header_rom[506] = 8'h44;
        header_rom[507] = 8'h45; header_rom[508] = 8'h46; header_rom[509] = 8'h47;
        header_rom[510] = 8'h48; header_rom[511] = 8'h49; header_rom[512] = 8'h4A;
        header_rom[513] = 8'h53; header_rom[514] = 8'h54; header_rom[515] = 8'h55;
        header_rom[516] = 8'h56; header_rom[517] = 8'h57; header_rom[518] = 8'h58;
        header_rom[519] = 8'h59; header_rom[520] = 8'h5A; header_rom[521] = 8'h63;
        header_rom[522] = 8'h64; header_rom[523] = 8'h65; header_rom[524] = 8'h66;
        header_rom[525] = 8'h67; header_rom[526] = 8'h68; header_rom[527] = 8'h69;
        header_rom[528] = 8'h6A; header_rom[529] = 8'h73; header_rom[530] = 8'h74;
        header_rom[531] = 8'h75; header_rom[532] = 8'h76; header_rom[533] = 8'h77;
        header_rom[534] = 8'h78; header_rom[535] = 8'h79; header_rom[536] = 8'h7A;
        header_rom[537] = 8'h82; header_rom[538] = 8'h83; header_rom[539] = 8'h84;
        header_rom[540] = 8'h85; header_rom[541] = 8'h86; header_rom[542] = 8'h87;
        header_rom[543] = 8'h88; header_rom[544] = 8'h89; header_rom[545] = 8'h8A;
        header_rom[546] = 8'h92; header_rom[547] = 8'h93; header_rom[548] = 8'h94;
        header_rom[549] = 8'h95; header_rom[550] = 8'h96; header_rom[551] = 8'h97;
        header_rom[552] = 8'h98; header_rom[553] = 8'h99; header_rom[554] = 8'h9A;
        header_rom[555] = 8'hA2; header_rom[556] = 8'hA3; header_rom[557] = 8'hA4;
        header_rom[558] = 8'hA5; header_rom[559] = 8'hA6; header_rom[560] = 8'hA7;
        header_rom[561] = 8'hA8; header_rom[562] = 8'hA9; header_rom[563] = 8'hAA;
        header_rom[564] = 8'hB2; header_rom[565] = 8'hB3; header_rom[566] = 8'hB4;
        header_rom[567] = 8'hB5; header_rom[568] = 8'hB6; header_rom[569] = 8'hB7;
        header_rom[570] = 8'hB8; header_rom[571] = 8'hB9; header_rom[572] = 8'hBA;
        header_rom[573] = 8'hC2; header_rom[574] = 8'hC3; header_rom[575] = 8'hC4;
        header_rom[576] = 8'hC5; header_rom[577] = 8'hC6; header_rom[578] = 8'hC7;
        header_rom[579] = 8'hC8; header_rom[580] = 8'hC9; header_rom[581] = 8'hCA;
        header_rom[582] = 8'hD2; header_rom[583] = 8'hD3; header_rom[584] = 8'hD4;
        header_rom[585] = 8'hD5; header_rom[586] = 8'hD6; header_rom[587] = 8'hD7;
        header_rom[588] = 8'hD8; header_rom[589] = 8'hD9; header_rom[590] = 8'hDA;
        header_rom[591] = 8'hE2; header_rom[592] = 8'hE3; header_rom[593] = 8'hE4;
        header_rom[594] = 8'hE5; header_rom[595] = 8'hE6; header_rom[596] = 8'hE7;
        header_rom[597] = 8'hE8; header_rom[598] = 8'hE9; header_rom[599] = 8'hEA;
        header_rom[600] = 8'hF2; header_rom[601] = 8'hF3; header_rom[602] = 8'hF4;
        header_rom[603] = 8'hF5; header_rom[604] = 8'hF6; header_rom[605] = 8'hF7;
        header_rom[606] = 8'hF8; header_rom[607] = 8'hF9; header_rom[608] = 8'hFA;
        // SOS (14 bytes, indices 609-622)
        header_rom[609] = 8'hFF; header_rom[610] = 8'hDA;
        header_rom[611] = 8'h00; header_rom[612] = 8'h0C; header_rom[613] = 8'h03;
        header_rom[614] = 8'h01; header_rom[615] = 8'h00;
        header_rom[616] = 8'h02; header_rom[617] = 8'h11;
        header_rom[618] = 8'h03; header_rom[619] = 8'h11;
        header_rom[620] = 8'h00; header_rom[621] = 8'h3F; header_rom[622] = 8'h00;
    end
    /* verilator coverage_on */

    // Simplified state machine
    // Output ROM bytes 0..176 (pre-SOF0), optional DRI, ROM bytes 177..622 (DHT+SOS)
    localparam SL_IDLE      = 3'd0;
    localparam SL_HDR_PRE   = 3'd1;  // bytes 0..176 (SOI+APP0+DQT_L+DQT_C+SOF0)
    localparam SL_DRI       = 3'd2;  // optional 6 bytes
    localparam SL_HDR_POST  = 3'd3;  // bytes 177..622 (DHT+SOS)
    localparam SL_SCAN_DATA = 3'd4;
    localparam SL_EOI_0     = 3'd5;
    localparam SL_EOI_1     = 3'd6;
    localparam SL_DONE      = 3'd7;

    reg [2:0]  state;
    reg [9:0]  seg_idx;

    assign scan_ready = (state == SL_SCAN_DATA);
    assign headers_done = (state == SL_SCAN_DATA) || (state == SL_EOI_0) ||
                          (state == SL_EOI_1) || (state == SL_DONE);

    // Q-table read port unused in lite mode
    always @(posedge clk) begin
        qt_rd_addr      <= 6'd0;
        qt_rd_is_chroma <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= SL_IDLE;
            seg_idx       <= 10'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 8'd0;
            m_axis_tlast  <= 1'b0;
        end else begin
            case (state)
                SL_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (frame_start) begin
                        state   <= SL_HDR_PRE;
                        seg_idx <= 10'd0;
                    end
                end

                // Output bytes 0..176 (SOI+APP0+DQT_L+DQT_C+SOF0)
                SL_HDR_PRE: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= header_rom[seg_idx];
                    if (seg_idx == SOF0_END[9:0]) begin
                        seg_idx <= 10'd0;
                        if (restart_interval != 16'd0)
                            state <= SL_DRI;
                        else begin
                            state   <= SL_HDR_POST;
                            seg_idx <= DHT_START[9:0];
                        end
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                // Optional DRI marker (6 bytes)
                SL_DRI: begin
                    m_axis_tvalid <= 1'b1;
                    case (seg_idx[2:0])
                        3'd0: m_axis_tdata <= 8'hFF;
                        3'd1: m_axis_tdata <= 8'hDD;
                        3'd2: m_axis_tdata <= 8'h00;
                        3'd3: m_axis_tdata <= 8'h04;
                        3'd4: m_axis_tdata <= restart_interval[15:8];
                        3'd5: m_axis_tdata <= restart_interval[7:0];
                        default: m_axis_tdata <= 8'h00;
                    endcase
                    if (seg_idx == 10'd5) begin
                        state   <= SL_HDR_POST;
                        seg_idx <= DHT_START[9:0];
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                // Output bytes 177..622 (DHT + SOS)
                SL_HDR_POST: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= header_rom[seg_idx];
                    if (seg_idx == (HEADER_SIZE[9:0] - 10'd1)) begin
                        state   <= SL_SCAN_DATA;
                        seg_idx <= 10'd0;
                    end else begin
                        seg_idx <= seg_idx + 10'd1;
                    end
                end

                SL_SCAN_DATA: begin
                    if (scan_valid && scan_last) begin
                        m_axis_tvalid <= 1'b0;
                        state <= SL_EOI_0;
                    end else begin
                        m_axis_tvalid <= scan_valid;
                        m_axis_tdata  <= scan_data;
                        m_axis_tlast  <= 1'b0;
                    end
                end

                SL_EOI_0: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;
                    state <= SL_EOI_1;
                end

                SL_EOI_1: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= 8'hD9;
                    m_axis_tlast  <= 1'b1;
                    state <= SL_DONE;
                end

                SL_DONE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    state <= SL_IDLE;
                end

                default: state <= SL_IDLE;
            endcase
        end
    end

end
endgenerate

endmodule
