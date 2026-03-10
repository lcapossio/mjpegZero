// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Quantizer - DCT Coefficient Quantization with Runtime Quality Scaling
// ============================================================================
// Divides each DCT coefficient by the corresponding quantization table value.
// Uses multiply-by-reciprocal: Q[i] = (DCT[i] * recip[i] + round) >> 16
//
// LITE_MODE=0 (default): Runtime quality scaling via AXI4-Lite register
//   1. Base Q tables (Annex K) stored in ROM
//   2. Scale factor: Q>=50 -> 200-2*Q, Q<50 -> 5000/Q (ROM, 100 entries)
//   3. Scaled Q = max(1, (base * scale + 50) / 100)
//   4. Reciprocal = round(65536 / scaled_Q) from LUT (256 entries)
//   5. Update state machine recomputes tables when quality changes (~384 clks)
//
// LITE_MODE=1: Fixed tables at LITE_QUALITY, no runtime scaling
//   Tables computed at elaboration from LITE_QUALITY param. No UPD FSM.
//
// 4-stage pipeline for 150MHz timing:
//   P1: Register inputs + read reciprocal from table
//   P2: Absolute value + register reciprocal
//   P3: Multiply (DSP48)
//   P4: Shift, round, apply sign
//
// Q-table read port for JFIF writer (dynamic DQT sections).
// ============================================================================

module quantizer #(
    parameter LITE_MODE    = 0,    // 1 = fixed quality, no runtime scaling
    parameter LITE_QUALITY = 95    // Quality 1-100, used when LITE_MODE=1
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire [1:0]  comp_id,        // 0,1 = luminance, 2,3 = chrominance
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [6:0]  quality,        // Quality factor 1-100
    /* verilator lint_on UNUSEDSIGNAL */

    // Input
    input  wire        in_valid,
    input  wire signed [15:0] in_data, // DCT coefficient
    input  wire        in_sof,         // Start of frame
    input  wire        in_sob,         // Start of block

    // Output
    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_sof,
    output reg         out_sob,

    // Q-table read port (for JFIF writer to read current Q values)
    input  wire [5:0]  qt_rd_addr,
    input  wire        qt_rd_is_chroma,
    output reg  [7:0]  qt_rd_data
);

    // ========================================================================
    // Q-table storage (shared between LITE and FULL modes)
    // ========================================================================
    reg [15:0] recip_luma [0:63];
    reg [15:0] recip_chroma [0:63];
    reg [7:0]  qtable_luma [0:63];   // Current scaled Q values (for JFIF DQT)
    reg [7:0]  qtable_chroma [0:63]; // Current scaled Q values (for JFIF DQT)

    // ========================================================================
    // Quality scaling: FULL mode (dynamic) vs LITE mode (fixed Q95)
    // ========================================================================
generate
if (LITE_MODE == 0) begin : g_full_quality
    // ------------------------------------------------------------------
    // Standard quantization base tables (ITU-T T.81 Annex K)
    // ------------------------------------------------------------------
    reg [7:0] base_luma [0:63];
    reg [7:0] base_chroma [0:63];

    initial begin
        base_luma[ 0] = 8'd16; base_luma[ 1] = 8'd11; base_luma[ 2] = 8'd10; base_luma[ 3] = 8'd16;
        base_luma[ 4] = 8'd24; base_luma[ 5] = 8'd40; base_luma[ 6] = 8'd51; base_luma[ 7] = 8'd61;
        base_luma[ 8] = 8'd12; base_luma[ 9] = 8'd12; base_luma[10] = 8'd14; base_luma[11] = 8'd19;
        base_luma[12] = 8'd26; base_luma[13] = 8'd58; base_luma[14] = 8'd60; base_luma[15] = 8'd55;
        base_luma[16] = 8'd14; base_luma[17] = 8'd13; base_luma[18] = 8'd16; base_luma[19] = 8'd24;
        base_luma[20] = 8'd40; base_luma[21] = 8'd57; base_luma[22] = 8'd69; base_luma[23] = 8'd56;
        base_luma[24] = 8'd14; base_luma[25] = 8'd17; base_luma[26] = 8'd22; base_luma[27] = 8'd29;
        base_luma[28] = 8'd51; base_luma[29] = 8'd87; base_luma[30] = 8'd80; base_luma[31] = 8'd62;
        base_luma[32] = 8'd18; base_luma[33] = 8'd22; base_luma[34] = 8'd37; base_luma[35] = 8'd56;
        base_luma[36] = 8'd68; base_luma[37] = 8'd109;base_luma[38] = 8'd103;base_luma[39] = 8'd77;
        base_luma[40] = 8'd24; base_luma[41] = 8'd35; base_luma[42] = 8'd55; base_luma[43] = 8'd64;
        base_luma[44] = 8'd81; base_luma[45] = 8'd104;base_luma[46] = 8'd113;base_luma[47] = 8'd92;
        base_luma[48] = 8'd49; base_luma[49] = 8'd64; base_luma[50] = 8'd78; base_luma[51] = 8'd87;
        base_luma[52] = 8'd103;base_luma[53] = 8'd121;base_luma[54] = 8'd120;base_luma[55] = 8'd101;
        base_luma[56] = 8'd72; base_luma[57] = 8'd92; base_luma[58] = 8'd95; base_luma[59] = 8'd98;
        base_luma[60] = 8'd112;base_luma[61] = 8'd100;base_luma[62] = 8'd103;base_luma[63] = 8'd99;

        base_chroma[ 0] = 8'd17; base_chroma[ 1] = 8'd18; base_chroma[ 2] = 8'd24; base_chroma[ 3] = 8'd47;
        base_chroma[ 4] = 8'd99; base_chroma[ 5] = 8'd99; base_chroma[ 6] = 8'd99; base_chroma[ 7] = 8'd99;
        base_chroma[ 8] = 8'd18; base_chroma[ 9] = 8'd21; base_chroma[10] = 8'd26; base_chroma[11] = 8'd66;
        base_chroma[12] = 8'd99; base_chroma[13] = 8'd99; base_chroma[14] = 8'd99; base_chroma[15] = 8'd99;
        base_chroma[16] = 8'd24; base_chroma[17] = 8'd26; base_chroma[18] = 8'd56; base_chroma[19] = 8'd99;
        base_chroma[20] = 8'd99; base_chroma[21] = 8'd99; base_chroma[22] = 8'd99; base_chroma[23] = 8'd99;
        base_chroma[24] = 8'd47; base_chroma[25] = 8'd66; base_chroma[26] = 8'd99; base_chroma[27] = 8'd99;
        base_chroma[28] = 8'd99; base_chroma[29] = 8'd99; base_chroma[30] = 8'd99; base_chroma[31] = 8'd99;
        base_chroma[32] = 8'd99; base_chroma[33] = 8'd99; base_chroma[34] = 8'd99; base_chroma[35] = 8'd99;
        base_chroma[36] = 8'd99; base_chroma[37] = 8'd99; base_chroma[38] = 8'd99; base_chroma[39] = 8'd99;
        base_chroma[40] = 8'd99; base_chroma[41] = 8'd99; base_chroma[42] = 8'd99; base_chroma[43] = 8'd99;
        base_chroma[44] = 8'd99; base_chroma[45] = 8'd99; base_chroma[46] = 8'd99; base_chroma[47] = 8'd99;
        base_chroma[48] = 8'd99; base_chroma[49] = 8'd99; base_chroma[50] = 8'd99; base_chroma[51] = 8'd99;
        base_chroma[52] = 8'd99; base_chroma[53] = 8'd99; base_chroma[54] = 8'd99; base_chroma[55] = 8'd99;
        base_chroma[56] = 8'd99; base_chroma[57] = 8'd99; base_chroma[58] = 8'd99; base_chroma[59] = 8'd99;
        base_chroma[60] = 8'd99; base_chroma[61] = 8'd99; base_chroma[62] = 8'd99; base_chroma[63] = 8'd99;
    end

    // ------------------------------------------------------------------
    // Scale factor ROM: quality -> scale factor
    // ------------------------------------------------------------------
    reg [12:0] scale_factor;
    reg [12:0] scale_factor_comb;

    always @(*) begin
        if (quality >= 7'd50)
            scale_factor_comb = 13'd200 - {6'd0, quality[6:0]} - {6'd0, quality[6:0]};
        else if (quality >= 7'd1)
            case (quality)
                7'd1:  scale_factor_comb = 13'd5000;
                7'd2:  scale_factor_comb = 13'd2500;
                7'd3:  scale_factor_comb = 13'd1667;
                7'd4:  scale_factor_comb = 13'd1250;
                7'd5:  scale_factor_comb = 13'd1000;
                7'd6:  scale_factor_comb = 13'd833;
                7'd7:  scale_factor_comb = 13'd714;
                7'd8:  scale_factor_comb = 13'd625;
                7'd9:  scale_factor_comb = 13'd556;
                7'd10: scale_factor_comb = 13'd500;
                7'd11: scale_factor_comb = 13'd455;
                7'd12: scale_factor_comb = 13'd417;
                7'd13: scale_factor_comb = 13'd385;
                7'd14: scale_factor_comb = 13'd357;
                7'd15: scale_factor_comb = 13'd333;
                7'd16: scale_factor_comb = 13'd313;
                7'd17: scale_factor_comb = 13'd294;
                7'd18: scale_factor_comb = 13'd278;
                7'd19: scale_factor_comb = 13'd263;
                7'd20: scale_factor_comb = 13'd250;
                7'd21: scale_factor_comb = 13'd238;
                7'd22: scale_factor_comb = 13'd227;
                7'd23: scale_factor_comb = 13'd217;
                7'd24: scale_factor_comb = 13'd208;
                7'd25: scale_factor_comb = 13'd200;
                7'd26: scale_factor_comb = 13'd192;
                7'd27: scale_factor_comb = 13'd185;
                7'd28: scale_factor_comb = 13'd179;
                7'd29: scale_factor_comb = 13'd172;
                7'd30: scale_factor_comb = 13'd167;
                7'd31: scale_factor_comb = 13'd161;
                7'd32: scale_factor_comb = 13'd156;
                7'd33: scale_factor_comb = 13'd152;
                7'd34: scale_factor_comb = 13'd147;
                7'd35: scale_factor_comb = 13'd143;
                7'd36: scale_factor_comb = 13'd139;
                7'd37: scale_factor_comb = 13'd135;
                7'd38: scale_factor_comb = 13'd132;
                7'd39: scale_factor_comb = 13'd128;
                7'd40: scale_factor_comb = 13'd125;
                7'd41: scale_factor_comb = 13'd122;
                7'd42: scale_factor_comb = 13'd119;
                7'd43: scale_factor_comb = 13'd116;
                7'd44: scale_factor_comb = 13'd114;
                7'd45: scale_factor_comb = 13'd111;
                7'd46: scale_factor_comb = 13'd109;
                7'd47: scale_factor_comb = 13'd106;
                7'd48: scale_factor_comb = 13'd104;
                7'd49: scale_factor_comb = 13'd102;
                default: scale_factor_comb = 13'd100;
            endcase
        else
            scale_factor_comb = 13'd5000;
    end

    // ------------------------------------------------------------------
    // Reciprocal LUT: recip[q] = round(65536/q) for q=1..255
    // ------------------------------------------------------------------
    reg [15:0] recip_lut [1:255];

    initial begin : init_recip_lut
        recip_lut[  1] = 16'd65535; recip_lut[  2] = 16'd32768; recip_lut[  3] = 16'd21845;
        recip_lut[  4] = 16'd16384; recip_lut[  5] = 16'd13107; recip_lut[  6] = 16'd10923;
        recip_lut[  7] = 16'd9362;  recip_lut[  8] = 16'd8192;  recip_lut[  9] = 16'd7282;
        recip_lut[ 10] = 16'd6554;  recip_lut[ 11] = 16'd5958;  recip_lut[ 12] = 16'd5461;
        recip_lut[ 13] = 16'd5041;  recip_lut[ 14] = 16'd4681;  recip_lut[ 15] = 16'd4369;
        recip_lut[ 16] = 16'd4096;  recip_lut[ 17] = 16'd3855;  recip_lut[ 18] = 16'd3641;
        recip_lut[ 19] = 16'd3449;  recip_lut[ 20] = 16'd3277;  recip_lut[ 21] = 16'd3121;
        recip_lut[ 22] = 16'd2979;  recip_lut[ 23] = 16'd2849;  recip_lut[ 24] = 16'd2731;
        recip_lut[ 25] = 16'd2621;  recip_lut[ 26] = 16'd2521;  recip_lut[ 27] = 16'd2427;
        recip_lut[ 28] = 16'd2341;  recip_lut[ 29] = 16'd2260;  recip_lut[ 30] = 16'd2185;
        recip_lut[ 31] = 16'd2114;  recip_lut[ 32] = 16'd2048;  recip_lut[ 33] = 16'd1986;
        recip_lut[ 34] = 16'd1928;  recip_lut[ 35] = 16'd1872;  recip_lut[ 36] = 16'd1820;
        recip_lut[ 37] = 16'd1771;  recip_lut[ 38] = 16'd1725;  recip_lut[ 39] = 16'd1680;
        recip_lut[ 40] = 16'd1638;  recip_lut[ 41] = 16'd1598;  recip_lut[ 42] = 16'd1560;
        recip_lut[ 43] = 16'd1524;  recip_lut[ 44] = 16'd1489;  recip_lut[ 45] = 16'd1456;
        recip_lut[ 46] = 16'd1425;  recip_lut[ 47] = 16'd1394;  recip_lut[ 48] = 16'd1365;
        recip_lut[ 49] = 16'd1337;  recip_lut[ 50] = 16'd1311;  recip_lut[ 51] = 16'd1285;
        recip_lut[ 52] = 16'd1260;  recip_lut[ 53] = 16'd1237;  recip_lut[ 54] = 16'd1214;
        recip_lut[ 55] = 16'd1192;  recip_lut[ 56] = 16'd1170;  recip_lut[ 57] = 16'd1150;
        recip_lut[ 58] = 16'd1130;  recip_lut[ 59] = 16'd1111;  recip_lut[ 60] = 16'd1092;
        recip_lut[ 61] = 16'd1074;  recip_lut[ 62] = 16'd1057;  recip_lut[ 63] = 16'd1040;
        recip_lut[ 64] = 16'd1024;  recip_lut[ 65] = 16'd1008;  recip_lut[ 66] = 16'd993;
        recip_lut[ 67] = 16'd978;   recip_lut[ 68] = 16'd964;   recip_lut[ 69] = 16'd950;
        recip_lut[ 70] = 16'd936;   recip_lut[ 71] = 16'd923;   recip_lut[ 72] = 16'd910;
        recip_lut[ 73] = 16'd898;   recip_lut[ 74] = 16'd886;   recip_lut[ 75] = 16'd874;
        recip_lut[ 76] = 16'd862;   recip_lut[ 77] = 16'd851;   recip_lut[ 78] = 16'd840;
        recip_lut[ 79] = 16'd829;   recip_lut[ 80] = 16'd819;   recip_lut[ 81] = 16'd809;
        recip_lut[ 82] = 16'd799;   recip_lut[ 83] = 16'd790;   recip_lut[ 84] = 16'd780;
        recip_lut[ 85] = 16'd771;   recip_lut[ 86] = 16'd762;   recip_lut[ 87] = 16'd753;
        recip_lut[ 88] = 16'd745;   recip_lut[ 89] = 16'd736;   recip_lut[ 90] = 16'd728;
        recip_lut[ 91] = 16'd720;   recip_lut[ 92] = 16'd712;   recip_lut[ 93] = 16'd705;
        recip_lut[ 94] = 16'd697;   recip_lut[ 95] = 16'd690;   recip_lut[ 96] = 16'd683;
        recip_lut[ 97] = 16'd676;   recip_lut[ 98] = 16'd669;   recip_lut[ 99] = 16'd662;
        recip_lut[100] = 16'd655;   recip_lut[101] = 16'd649;   recip_lut[102] = 16'd643;
        recip_lut[103] = 16'd636;   recip_lut[104] = 16'd630;   recip_lut[105] = 16'd624;
        recip_lut[106] = 16'd618;   recip_lut[107] = 16'd613;   recip_lut[108] = 16'd607;
        recip_lut[109] = 16'd601;   recip_lut[110] = 16'd596;   recip_lut[111] = 16'd591;
        recip_lut[112] = 16'd585;   recip_lut[113] = 16'd580;   recip_lut[114] = 16'd575;
        recip_lut[115] = 16'd570;   recip_lut[116] = 16'd565;   recip_lut[117] = 16'd560;
        recip_lut[118] = 16'd555;   recip_lut[119] = 16'd551;   recip_lut[120] = 16'd546;
        recip_lut[121] = 16'd542;   recip_lut[122] = 16'd537;   recip_lut[123] = 16'd533;
        recip_lut[124] = 16'd529;   recip_lut[125] = 16'd524;   recip_lut[126] = 16'd520;
        recip_lut[127] = 16'd516;   recip_lut[128] = 16'd512;   recip_lut[129] = 16'd508;
        recip_lut[130] = 16'd504;   recip_lut[131] = 16'd500;   recip_lut[132] = 16'd497;
        recip_lut[133] = 16'd493;   recip_lut[134] = 16'd489;   recip_lut[135] = 16'd486;
        recip_lut[136] = 16'd482;   recip_lut[137] = 16'd478;   recip_lut[138] = 16'd475;
        recip_lut[139] = 16'd472;   recip_lut[140] = 16'd468;   recip_lut[141] = 16'd465;
        recip_lut[142] = 16'd462;   recip_lut[143] = 16'd458;   recip_lut[144] = 16'd455;
        recip_lut[145] = 16'd452;   recip_lut[146] = 16'd449;   recip_lut[147] = 16'd446;
        recip_lut[148] = 16'd443;   recip_lut[149] = 16'd440;   recip_lut[150] = 16'd437;
        recip_lut[151] = 16'd434;   recip_lut[152] = 16'd431;   recip_lut[153] = 16'd428;
        recip_lut[154] = 16'd426;   recip_lut[155] = 16'd423;   recip_lut[156] = 16'd420;
        recip_lut[157] = 16'd417;   recip_lut[158] = 16'd415;   recip_lut[159] = 16'd412;
        recip_lut[160] = 16'd410;   recip_lut[161] = 16'd407;   recip_lut[162] = 16'd405;
        recip_lut[163] = 16'd402;   recip_lut[164] = 16'd400;   recip_lut[165] = 16'd397;
        recip_lut[166] = 16'd395;   recip_lut[167] = 16'd392;   recip_lut[168] = 16'd390;
        recip_lut[169] = 16'd388;   recip_lut[170] = 16'd385;   recip_lut[171] = 16'd383;
        recip_lut[172] = 16'd381;   recip_lut[173] = 16'd379;   recip_lut[174] = 16'd377;
        recip_lut[175] = 16'd374;   recip_lut[176] = 16'd372;   recip_lut[177] = 16'd370;
        recip_lut[178] = 16'd368;   recip_lut[179] = 16'd366;   recip_lut[180] = 16'd364;
        recip_lut[181] = 16'd362;   recip_lut[182] = 16'd360;   recip_lut[183] = 16'd358;
        recip_lut[184] = 16'd356;   recip_lut[185] = 16'd354;   recip_lut[186] = 16'd352;
        recip_lut[187] = 16'd351;   recip_lut[188] = 16'd349;   recip_lut[189] = 16'd347;
        recip_lut[190] = 16'd345;   recip_lut[191] = 16'd343;   recip_lut[192] = 16'd341;
        recip_lut[193] = 16'd340;   recip_lut[194] = 16'd338;   recip_lut[195] = 16'd336;
        recip_lut[196] = 16'd334;   recip_lut[197] = 16'd333;   recip_lut[198] = 16'd331;
        recip_lut[199] = 16'd329;   recip_lut[200] = 16'd328;   recip_lut[201] = 16'd326;
        recip_lut[202] = 16'd324;   recip_lut[203] = 16'd323;   recip_lut[204] = 16'd321;
        recip_lut[205] = 16'd320;   recip_lut[206] = 16'd318;   recip_lut[207] = 16'd316;
        recip_lut[208] = 16'd315;   recip_lut[209] = 16'd314;   recip_lut[210] = 16'd312;
        recip_lut[211] = 16'd311;   recip_lut[212] = 16'd309;   recip_lut[213] = 16'd308;
        recip_lut[214] = 16'd306;   recip_lut[215] = 16'd305;   recip_lut[216] = 16'd303;
        recip_lut[217] = 16'd302;   recip_lut[218] = 16'd301;   recip_lut[219] = 16'd299;
        recip_lut[220] = 16'd298;   recip_lut[221] = 16'd297;   recip_lut[222] = 16'd295;
        recip_lut[223] = 16'd294;   recip_lut[224] = 16'd293;   recip_lut[225] = 16'd291;
        recip_lut[226] = 16'd290;   recip_lut[227] = 16'd289;   recip_lut[228] = 16'd288;
        recip_lut[229] = 16'd286;   recip_lut[230] = 16'd285;   recip_lut[231] = 16'd284;
        recip_lut[232] = 16'd282;   recip_lut[233] = 16'd281;   recip_lut[234] = 16'd280;
        recip_lut[235] = 16'd279;   recip_lut[236] = 16'd278;   recip_lut[237] = 16'd277;
        recip_lut[238] = 16'd275;   recip_lut[239] = 16'd274;   recip_lut[240] = 16'd273;
        recip_lut[241] = 16'd272;   recip_lut[242] = 16'd271;   recip_lut[243] = 16'd270;
        recip_lut[244] = 16'd269;   recip_lut[245] = 16'd267;   recip_lut[246] = 16'd266;
        recip_lut[247] = 16'd265;   recip_lut[248] = 16'd264;   recip_lut[249] = 16'd263;
        recip_lut[250] = 16'd262;   recip_lut[251] = 16'd261;   recip_lut[252] = 16'd260;
        recip_lut[253] = 16'd259;   recip_lut[254] = 16'd258;   recip_lut[255] = 16'd257;
    end

    // ------------------------------------------------------------------
    // Intermediate computation registers
    // ------------------------------------------------------------------
    reg [20:0] scaled_raw;
    reg [20:0] scaled_plus50_r;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [31:0] div100_product_r;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0] div100_result;
    assign div100_result = (div100_product_r[31:17] > 15'd255) ? 8'd255 :
                           (div100_product_r[31:17] < 15'd1)   ? 8'd1  :
                           div100_product_r[24:17];

    // ------------------------------------------------------------------
    // Q-table update state machine
    // ------------------------------------------------------------------
    localparam UPD_IDLE     = 3'd0;
    localparam UPD_SCALE    = 3'd1;
    localparam UPD_ADD      = 3'd2;
    localparam UPD_DIV      = 3'd3;
    localparam UPD_RECIP    = 3'd4;

    reg [2:0] upd_state;
    reg       upd_is_chroma;
    reg [5:0] upd_pos;
    reg [6:0] last_quality;

    always @(posedge clk) begin
        if (!rst_n) begin
            upd_state    <= UPD_IDLE;
            last_quality <= 7'd0;
            upd_is_chroma <= 1'b0;
            upd_pos      <= 6'd0;
        end else begin
            case (upd_state)
                UPD_IDLE: begin
                    if (quality != last_quality) begin
                        last_quality  <= quality;
                        scale_factor  <= scale_factor_comb;
                        upd_is_chroma <= 1'b0;
                        upd_pos       <= 6'd0;
                        upd_state     <= UPD_SCALE;
                    end
                end
                UPD_SCALE: begin
                    if (upd_is_chroma)
                        scaled_raw <= {13'd0, base_chroma[upd_pos]} * {8'd0, scale_factor};
                    else
                        scaled_raw <= {13'd0, base_luma[upd_pos]} * {8'd0, scale_factor};
                    upd_state <= UPD_ADD;
                end
                UPD_ADD: begin
                    scaled_plus50_r <= scaled_raw + 21'd50;
                    upd_state <= UPD_DIV;
                end
                UPD_DIV: begin
                    div100_product_r <= {11'd0, scaled_plus50_r} * 32'd1311;
                    upd_state <= UPD_RECIP;
                end
                UPD_RECIP: begin
                    if (upd_is_chroma) begin
                        qtable_chroma[upd_pos] <= div100_result;
                        recip_chroma[upd_pos]  <= recip_lut[div100_result];
                    end else begin
                        qtable_luma[upd_pos] <= div100_result;
                        recip_luma[upd_pos]  <= recip_lut[div100_result];
                    end
                    if (upd_pos == 6'd63) begin
                        upd_pos <= 6'd0;
                        if (upd_is_chroma) begin
                            upd_state <= UPD_IDLE;
                        end else begin
                            upd_is_chroma <= 1'b1;
                            upd_state     <= UPD_SCALE;
                        end
                    end else begin
                        upd_pos   <= upd_pos + 6'd1;
                        upd_state <= UPD_SCALE;
                    end
                end
                default: upd_state <= UPD_IDLE;
            endcase
        end
    end

    // Initialize Q tables to Q=1 defaults (UPD FSM overwrites on first quality change)
    integer k;
    initial begin
        for (k = 0; k < 64; k = k + 1) begin
            qtable_luma[k]   = 8'd1;
            qtable_chroma[k] = 8'd1;
            recip_luma[k]    = 16'd65535;
            recip_chroma[k]  = 16'd65535;
        end
    end

end else begin : g_lite_quality
    // ------------------------------------------------------------------
    // LITE MODE: Fixed tables computed from LITE_QUALITY parameter
    // No update FSM, no base tables at runtime, no reciprocal LUT
    // Tables are computed at elaboration time by the initial block.
    // ------------------------------------------------------------------

    initial begin : init_lite_tables
        integer scale, scaled_q, recip_val;

        // Compute scale factor: Q>=50 -> 200-2*Q, Q<50 -> 5000/Q
        if (LITE_QUALITY >= 50)
            scale = 200 - 2 * LITE_QUALITY;
        else if (LITE_QUALITY >= 1)
            scale = 5000 / LITE_QUALITY;
        else
            scale = 5000;

        // Fully unrolled — variable-indexed reg array reads cannot be evaluated
        // by Vivado during initial-block elaboration; base values are inlined here.
        // Luma base table (ITU-T T.81 Annex K, raster order):
        scaled_q=(16*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[0]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[0]=recip_val[15:0];
        scaled_q=(11*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[1]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[1]=recip_val[15:0];
        scaled_q=(10*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[2]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[2]=recip_val[15:0];
        scaled_q=(16*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[3]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[3]=recip_val[15:0];
        scaled_q=(24*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[4]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[4]=recip_val[15:0];
        scaled_q=(40*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[5]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[5]=recip_val[15:0];
        scaled_q=(51*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[6]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[6]=recip_val[15:0];
        scaled_q=(61*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[7]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[7]=recip_val[15:0];
        scaled_q=(12*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[8]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[8]=recip_val[15:0];
        scaled_q=(12*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[9]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[9]=recip_val[15:0];
        scaled_q=(14*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[10]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[10]=recip_val[15:0];
        scaled_q=(19*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[11]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[11]=recip_val[15:0];
        scaled_q=(26*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[12]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[12]=recip_val[15:0];
        scaled_q=(58*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[13]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[13]=recip_val[15:0];
        scaled_q=(60*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[14]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[14]=recip_val[15:0];
        scaled_q=(55*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[15]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[15]=recip_val[15:0];
        scaled_q=(14*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[16]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[16]=recip_val[15:0];
        scaled_q=(13*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[17]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[17]=recip_val[15:0];
        scaled_q=(16*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[18]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[18]=recip_val[15:0];
        scaled_q=(24*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[19]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[19]=recip_val[15:0];
        scaled_q=(40*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[20]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[20]=recip_val[15:0];
        scaled_q=(57*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[21]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[21]=recip_val[15:0];
        scaled_q=(69*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[22]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[22]=recip_val[15:0];
        scaled_q=(56*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[23]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[23]=recip_val[15:0];
        scaled_q=(14*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[24]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[24]=recip_val[15:0];
        scaled_q=(17*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[25]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[25]=recip_val[15:0];
        scaled_q=(22*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[26]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[26]=recip_val[15:0];
        scaled_q=(29*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[27]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[27]=recip_val[15:0];
        scaled_q=(51*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[28]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[28]=recip_val[15:0];
        scaled_q=(87*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[29]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[29]=recip_val[15:0];
        scaled_q=(80*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[30]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[30]=recip_val[15:0];
        scaled_q=(62*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[31]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[31]=recip_val[15:0];
        scaled_q=(18*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[32]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[32]=recip_val[15:0];
        scaled_q=(22*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[33]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[33]=recip_val[15:0];
        scaled_q=(37*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[34]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[34]=recip_val[15:0];
        scaled_q=(56*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[35]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[35]=recip_val[15:0];
        scaled_q=(68*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[36]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[36]=recip_val[15:0];
        scaled_q=(109*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[37]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[37]=recip_val[15:0];
        scaled_q=(103*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[38]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[38]=recip_val[15:0];
        scaled_q=(77*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[39]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[39]=recip_val[15:0];
        scaled_q=(24*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[40]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[40]=recip_val[15:0];
        scaled_q=(35*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[41]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[41]=recip_val[15:0];
        scaled_q=(55*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[42]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[42]=recip_val[15:0];
        scaled_q=(64*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[43]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[43]=recip_val[15:0];
        scaled_q=(81*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[44]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[44]=recip_val[15:0];
        scaled_q=(104*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[45]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[45]=recip_val[15:0];
        scaled_q=(113*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[46]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[46]=recip_val[15:0];
        scaled_q=(92*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[47]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[47]=recip_val[15:0];
        scaled_q=(49*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[48]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[48]=recip_val[15:0];
        scaled_q=(64*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[49]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[49]=recip_val[15:0];
        scaled_q=(78*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[50]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[50]=recip_val[15:0];
        scaled_q=(87*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[51]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[51]=recip_val[15:0];
        scaled_q=(103*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[52]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[52]=recip_val[15:0];
        scaled_q=(121*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[53]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[53]=recip_val[15:0];
        scaled_q=(120*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[54]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[54]=recip_val[15:0];
        scaled_q=(101*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[55]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[55]=recip_val[15:0];
        scaled_q=(72*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[56]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[56]=recip_val[15:0];
        scaled_q=(92*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[57]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[57]=recip_val[15:0];
        scaled_q=(95*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[58]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[58]=recip_val[15:0];
        scaled_q=(98*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[59]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[59]=recip_val[15:0];
        scaled_q=(112*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[60]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[60]=recip_val[15:0];
        scaled_q=(100*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[61]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[61]=recip_val[15:0];
        scaled_q=(103*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[62]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[62]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_luma[63]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_luma[63]=recip_val[15:0];
        // Chroma base table (raster order):
        scaled_q=(17*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[0]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[0]=recip_val[15:0];
        scaled_q=(18*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[1]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[1]=recip_val[15:0];
        scaled_q=(24*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[2]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[2]=recip_val[15:0];
        scaled_q=(47*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[3]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[3]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[4]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[4]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[5]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[5]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[6]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[6]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[7]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[7]=recip_val[15:0];
        scaled_q=(18*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[8]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[8]=recip_val[15:0];
        scaled_q=(21*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[9]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[9]=recip_val[15:0];
        scaled_q=(26*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[10]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[10]=recip_val[15:0];
        scaled_q=(66*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[11]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[11]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[12]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[12]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[13]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[13]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[14]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[14]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[15]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[15]=recip_val[15:0];
        scaled_q=(24*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[16]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[16]=recip_val[15:0];
        scaled_q=(26*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[17]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[17]=recip_val[15:0];
        scaled_q=(56*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[18]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[18]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[19]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[19]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[20]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[20]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[21]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[21]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[22]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[22]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[23]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[23]=recip_val[15:0];
        scaled_q=(47*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[24]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[24]=recip_val[15:0];
        scaled_q=(66*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[25]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[25]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[26]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[26]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[27]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[27]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[28]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[28]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[29]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[29]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[30]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[30]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[31]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[31]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[32]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[32]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[33]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[33]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[34]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[34]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[35]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[35]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[36]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[36]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[37]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[37]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[38]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[38]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[39]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[39]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[40]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[40]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[41]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[41]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[42]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[42]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[43]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[43]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[44]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[44]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[45]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[45]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[46]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[46]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[47]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[47]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[48]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[48]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[49]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[49]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[50]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[50]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[51]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[51]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[52]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[52]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[53]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[53]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[54]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[54]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[55]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[55]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[56]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[56]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[57]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[57]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[58]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[58]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[59]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[59]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[60]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[60]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[61]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[61]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[62]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[62]=recip_val[15:0];
        scaled_q=(99*scale+50)/100; if(scaled_q<1)scaled_q=1; if(scaled_q>255)scaled_q=255; qtable_chroma[63]=scaled_q[7:0]; recip_val=(scaled_q==1)?65535:((65536+scaled_q/2)/scaled_q); if(recip_val>65535)recip_val=65535; recip_chroma[63]=recip_val[15:0];
    end
end
endgenerate

    // ========================================================================
    // Q-table read port (for JFIF writer)
    // ========================================================================
    always @(posedge clk) begin
        if (qt_rd_is_chroma)
            qt_rd_data <= qtable_chroma[qt_rd_addr];
        else
            qt_rd_data <= qtable_luma[qt_rd_addr];
    end

    // ========================================================================
    // Coefficient counter within block
    // ========================================================================
    reg [5:0] coeff_idx;

    always @(posedge clk) begin
        if (!rst_n)
            coeff_idx <= 6'd0;
        else if (in_valid) begin
            if (in_sob)
                coeff_idx <= 6'd1;
            else
                coeff_idx <= coeff_idx + 6'd1;
        end
    end

    // ========================================================================
    // Pipeline stage 1: Read reciprocal and register inputs
    // ========================================================================
    reg        p1_valid;
    reg signed [15:0] p1_data;
    reg [15:0] p1_recip;
    reg        p1_sof;
    reg        p1_sob;

    wire [5:0] lookup_idx = in_sob ? 6'd0 : coeff_idx;

    reg        latched_is_chroma;
    wire       is_chroma_now = (comp_id >= 2'd2);
    wire       use_chroma    = (in_valid && in_sob) ? is_chroma_now : latched_is_chroma;

    always @(posedge clk) begin
        if (!rst_n)
            latched_is_chroma <= 1'b0;
        else if (in_valid && in_sob)
            latched_is_chroma <= is_chroma_now;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_sof   <= 1'b0;
            p1_sob   <= 1'b0;
        end else begin
            p1_valid <= in_valid;
            p1_data  <= in_data;
            p1_sof   <= in_sof;
            p1_sob   <= in_sob;
            p1_recip <= use_chroma ? recip_chroma[lookup_idx] : recip_luma[lookup_idx];
        end
    end

    // ========================================================================
    // Pipeline stage 2: Compute absolute value, register reciprocal
    // (Extra stage for 150MHz timing)
    // ========================================================================
    reg        p2_valid;
    reg [15:0] p2_abs_data;
    reg        p2_sign;
    reg [15:0] p2_recip;
    reg        p2_sof;
    reg        p2_sob;

    always @(posedge clk) begin
        if (!rst_n) begin
            p2_valid <= 1'b0;
            p2_sof   <= 1'b0;
            p2_sob   <= 1'b0;
        end else begin
            p2_valid  <= p1_valid;
            p2_sof    <= p1_sof;
            p2_sob    <= p1_sob;
            p2_sign   <= p1_data[15];
            p2_abs_data <= p1_data[15] ? (-p1_data) : p1_data;
            p2_recip  <= p1_recip;
        end
    end

    // ========================================================================
    // Pipeline stage 3: Multiply (DSP48)
    // ========================================================================
    reg        p3_valid;
    reg [31:0] p3_product;
    reg        p3_sof;
    reg        p3_sob;
    reg        p3_sign;

    always @(posedge clk) begin
        if (!rst_n) begin
            p3_valid <= 1'b0;
            p3_sof   <= 1'b0;
            p3_sob   <= 1'b0;
        end else begin
            p3_valid   <= p2_valid;
            p3_sof     <= p2_sof;
            p3_sob     <= p2_sob;
            p3_sign    <= p2_sign;
            p3_product <= {16'd0, p2_abs_data} * {16'd0, p2_recip};
        end
    end

    // ========================================================================
    // Pipeline stage 4: Shift, round, apply sign
    // ========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] p3_rounded = p3_product + 32'd32768;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] rounded_result = p3_rounded[31:16];

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_sof   <= 1'b0;
            out_sob   <= 1'b0;
            out_data  <= 16'd0;
        end else begin
            out_valid <= p3_valid;
            out_sof   <= p3_sof;
            out_sob   <= p3_sob;
            if (p3_valid) begin
                /* verilator lint_off WIDTHTRUNC */
                if (p3_sign)
                    out_data <= -$signed({1'b0, rounded_result});
                else
                    out_data <= $signed({1'b0, rounded_result});
                /* verilator lint_on WIDTHTRUNC */
            end
        end
    end

endmodule
