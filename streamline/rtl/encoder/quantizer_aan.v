// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// quantizer (AAN-folded) — quantizes scaled DCT coefficients
//
// Function
//   Uniform quantization of ITU-T T.81 §A.3.4 for the AAN scaled DCT: the
//   incoming coefficient carries the AAN per-coefficient gain g_u * g_v,
//   and this quantizer folds its removal into the reciprocal at no extra
//   datapath cost:
//       out = sign(in) * ((|in| * recip_f + 2^15) >> 16)
//       recip_f = (round(2^16/step) * kf[pos] + 2^13) >> 14
//       kf[pos] = round(2^14 / (2 * g_u * g_v))   (x2: the DCT guard bit)
//   The step tables (and the DQT the decoder sees) are the standard T.81
//   Annex K values under the IJG quality mapping, exactly as in the
//   orthonormal quantizer — the fold is internal only.
//
// Interface
//   Fixed-latency, valid-only stream (no backpressure): in_valid/in_data with
//   in_sof/in_sob framing in, the same one stage later per pipeline register.
//   comp_id selects the table (0,1 = luma; 2,3 = chroma) and is sampled at
//   in_sob; the whole block then uses that table. The qt_rd port exposes the
//   active step tables to the JFIF writer for DQT emission (1-cycle read).
//
// Contract
//   Matched set: pairs with dct_2d_aan (scaled coefficients in); never mix
//   with the orthonormal dct_2d. One coefficient per clock, 4-cycle
//   latency, never stalls. In runtime mode (LITE_MODE=0) a quality change
//   rebuilds a shadow copy of the tables in ~132 clocks while the active
//   copy keeps serving; blocks beginning after
//   the rebuild completes use the new tables, blocks in flight finish on the
//   old ones. The DQT a frame advertises matches its blocks whenever quality
//   is held stable from header emission to the frame's last block, which the
//   register interface provides by applying quality writes between frames.
//   In LITE_MODE=1 the tables are fixed at elaboration from LITE_QUALITY.
//
// Position
//   Encoder coefficient path:
//   input_buffer → dct_2d → [quantizer] → zigzag_reorder →
//   huffman_encoder → bitstream_packer → jfif_writer
//   Side tap: the qt_rd port serves the jfif_writer's DQT segments.
// -----------------------------------------------------------------------------

// The module keeps the canonical name so the encoder top instantiates it
// unchanged; the _aan filename distinguishes the matched-set variant.
/* verilator lint_off DECLFILENAME */
module quantizer #(
    parameter LITE_MODE    = 0,   // 1 = tables fixed at elaboration
    parameter LITE_QUALITY = 95   // quality 1-100, used when LITE_MODE=1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  comp_id,        // 0,1 = luma, 2,3 = chroma
    // quality is sampled only in runtime mode; with LITE_MODE=1 the tables
    // are elaboration constants and the port is intentionally unread.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [6:0]  quality,        // quality factor 1-100
    /* verilator lint_on UNUSEDSIGNAL */

    input  wire        in_valid,
    input  wire signed [15:0] in_data, // DCT coefficient
    input  wire        in_sof,         // start of frame
    input  wire        in_sob,         // start of block

    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_sof,
    output reg         out_sob,

    // Step-table read port for the JFIF writer's DQT segments
    input  wire [5:0]  qt_rd_addr,
    input  wire        qt_rd_is_chroma,
    output reg  [7:0]  qt_rd_data
);

    // ========================================================================
    // Base step tables — ITU-T T.81 Annex K, raster order.
    // Constant functions are the single source for every consumer: the
    // runtime rebuild pipeline reads them as logic, the LITE-mode initial
    // block evaluates them at elaboration.
    // ========================================================================
    function [7:0] base_luma;
        input [5:0] i;
        case (i)
            6'd0 : base_luma = 8'd16;  6'd1 : base_luma = 8'd11;  6'd2 : base_luma = 8'd10;  6'd3 : base_luma = 8'd16;
            6'd4 : base_luma = 8'd24;  6'd5 : base_luma = 8'd40;  6'd6 : base_luma = 8'd51;  6'd7 : base_luma = 8'd61;
            6'd8 : base_luma = 8'd12;  6'd9 : base_luma = 8'd12;  6'd10: base_luma = 8'd14;  6'd11: base_luma = 8'd19;
            6'd12: base_luma = 8'd26;  6'd13: base_luma = 8'd58;  6'd14: base_luma = 8'd60;  6'd15: base_luma = 8'd55;
            6'd16: base_luma = 8'd14;  6'd17: base_luma = 8'd13;  6'd18: base_luma = 8'd16;  6'd19: base_luma = 8'd24;
            6'd20: base_luma = 8'd40;  6'd21: base_luma = 8'd57;  6'd22: base_luma = 8'd69;  6'd23: base_luma = 8'd56;
            6'd24: base_luma = 8'd14;  6'd25: base_luma = 8'd17;  6'd26: base_luma = 8'd22;  6'd27: base_luma = 8'd29;
            6'd28: base_luma = 8'd51;  6'd29: base_luma = 8'd87;  6'd30: base_luma = 8'd80;  6'd31: base_luma = 8'd62;
            6'd32: base_luma = 8'd18;  6'd33: base_luma = 8'd22;  6'd34: base_luma = 8'd37;  6'd35: base_luma = 8'd56;
            6'd36: base_luma = 8'd68;  6'd37: base_luma = 8'd109; 6'd38: base_luma = 8'd103; 6'd39: base_luma = 8'd77;
            6'd40: base_luma = 8'd24;  6'd41: base_luma = 8'd35;  6'd42: base_luma = 8'd55;  6'd43: base_luma = 8'd64;
            6'd44: base_luma = 8'd81;  6'd45: base_luma = 8'd104; 6'd46: base_luma = 8'd113; 6'd47: base_luma = 8'd92;
            6'd48: base_luma = 8'd49;  6'd49: base_luma = 8'd64;  6'd50: base_luma = 8'd78;  6'd51: base_luma = 8'd87;
            6'd52: base_luma = 8'd103; 6'd53: base_luma = 8'd121; 6'd54: base_luma = 8'd120; 6'd55: base_luma = 8'd101;
            6'd56: base_luma = 8'd72;  6'd57: base_luma = 8'd92;  6'd58: base_luma = 8'd95;  6'd59: base_luma = 8'd98;
            6'd60: base_luma = 8'd112; 6'd61: base_luma = 8'd100; 6'd62: base_luma = 8'd103; 6'd63: base_luma = 8'd99;
        endcase
    endfunction

    function [7:0] base_chroma;
        input [5:0] i;
        case (i)
            6'd0 : base_chroma = 8'd17; 6'd1 : base_chroma = 8'd18; 6'd2 : base_chroma = 8'd24; 6'd3 : base_chroma = 8'd47;
            6'd8 : base_chroma = 8'd18; 6'd9 : base_chroma = 8'd21; 6'd10: base_chroma = 8'd26; 6'd11: base_chroma = 8'd66;
            6'd16: base_chroma = 8'd24; 6'd17: base_chroma = 8'd26; 6'd18: base_chroma = 8'd56;
            6'd24: base_chroma = 8'd47; 6'd25: base_chroma = 8'd66;
            default: base_chroma = 8'd99;  // all remaining positions are 99
        endcase
    endfunction

    // recip_of(q) = round(2^16 / q), held to 16 bits at q = 1.
    // Evaluated at elaboration only (integer division does not reach logic).
    function [15:0] recip_of;
        input integer q;
        // Elaboration-only integer temporary; the result is at most 2^16 - 1
        // (q = 1 clamps to 65535, q >= 2 gives at most 32768).
        /* verilator lint_off UNUSEDSIGNAL */
        integer r;
        /* verilator lint_on UNUSEDSIGNAL */
        begin
            r = (q <= 1) ? 65535 : (65536 + q / 2) / q;
            recip_of = r[15:0];
        end
    endfunction

    // kf_of(pos) = round(2^14 / (2 * g_u * g_v)) for raster position
    // pos = {u, v}: the AAN gain correction, including the DCT's one
    // guard fraction bit (the factor 2), folded into every reciprocal.
    // Values derive from the measured per-pass gains in
    // verify/dct_aan_model.py::aan_gains (outer product).
    function [14:0] kf_of;
        input [5:0] i;
        case (i)
            6'd0 : kf_of = 15'd1024; 6'd1 : kf_of = 15'd738; 6'd2 : kf_of = 15'd784; 6'd3 : kf_of = 15'd871;
            6'd4 : kf_of = 15'd1024; 6'd5 : kf_of = 15'd1304; 6'd6 : kf_of = 15'd1892; 6'd7 : kf_of = 15'd3709;
            6'd8 : kf_of = 15'd738; 6'd9 : kf_of = 15'd532; 6'd10: kf_of = 15'd565; 6'd11: kf_of = 15'd628;
            6'd12: kf_of = 15'd738; 6'd13: kf_of = 15'd940; 6'd14: kf_of = 15'd1364; 6'd15: kf_of = 15'd2674;
            6'd16: kf_of = 15'd784; 6'd17: kf_of = 15'd565; 6'd18: kf_of = 15'd600; 6'd19: kf_of = 15'd667;
            6'd20: kf_of = 15'd784; 6'd21: kf_of = 15'd998; 6'd22: kf_of = 15'd1448; 6'd23: kf_of = 15'd2838;
            6'd24: kf_of = 15'd871; 6'd25: kf_of = 15'd628; 6'd26: kf_of = 15'd667; 6'd27: kf_of = 15'd741;
            6'd28: kf_of = 15'd871; 6'd29: kf_of = 15'd1109; 6'd30: kf_of = 15'd1609; 6'd31: kf_of = 15'd3155;
            6'd32: kf_of = 15'd1024; 6'd33: kf_of = 15'd738; 6'd34: kf_of = 15'd784; 6'd35: kf_of = 15'd871;
            6'd36: kf_of = 15'd1024; 6'd37: kf_of = 15'd1304; 6'd38: kf_of = 15'd1892; 6'd39: kf_of = 15'd3709;
            6'd40: kf_of = 15'd1304; 6'd41: kf_of = 15'd940; 6'd42: kf_of = 15'd998; 6'd43: kf_of = 15'd1109;
            6'd44: kf_of = 15'd1304; 6'd45: kf_of = 15'd1659; 6'd46: kf_of = 15'd2408; 6'd47: kf_of = 15'd4722;
            6'd48: kf_of = 15'd1892; 6'd49: kf_of = 15'd1364; 6'd50: kf_of = 15'd1448; 6'd51: kf_of = 15'd1609;
            6'd52: kf_of = 15'd1892; 6'd53: kf_of = 15'd2408; 6'd54: kf_of = 15'd3494; 6'd55: kf_of = 15'd6852;
            6'd56: kf_of = 15'd3709; 6'd57: kf_of = 15'd2674; 6'd58: kf_of = 15'd2838; 6'd59: kf_of = 15'd3155;
            6'd60: kf_of = 15'd3709; 6'd61: kf_of = 15'd4722; 6'd62: kf_of = 15'd6852; 6'd63: kf_of = 15'd13434;
        endcase
    endfunction

    // ========================================================================
    // Step and reciprocal storage.
    // Layout: {bank, chroma, position}. Runtime mode keeps two banks so a
    // rebuild writes the shadow bank while the active bank keeps serving;
    // LITE mode needs only bank 0.
    // ========================================================================
    localparam TBL_DEPTH = (LITE_MODE == 0) ? 256 : 128;

    reg [16:0] recip_tbl [0:TBL_DEPTH-1];   // folded: up to 107470
    reg [7:0]  qstep_tbl [0:TBL_DEPTH-1];

    wire bank_active;

    // ========================================================================
    // Table generation
    // ========================================================================
generate
if (LITE_MODE == 0) begin : g_runtime_tables

    // scale_of(q): the IJG quality mapping. For q >= 50 the arithmetic form;
    // for 1 <= q < 50 a ROM of round(5000/q) (rounded so that the mapping is
    // monotone through q = 50); q = 0 saturates to the q = 1 value.
    function [12:0] scale_of;
        input [6:0] q;
        if (q >= 7'd50)
            scale_of = 13'd200 - {6'd0, q} - {6'd0, q};
        else case (q)
            7'd1 : scale_of = 13'd5000; 7'd2 : scale_of = 13'd2500; 7'd3 : scale_of = 13'd1667;
            7'd4 : scale_of = 13'd1250; 7'd5 : scale_of = 13'd1000; 7'd6 : scale_of = 13'd833;
            7'd7 : scale_of = 13'd714;  7'd8 : scale_of = 13'd625;  7'd9 : scale_of = 13'd556;
            7'd10: scale_of = 13'd500;  7'd11: scale_of = 13'd455;  7'd12: scale_of = 13'd417;
            7'd13: scale_of = 13'd385;  7'd14: scale_of = 13'd357;  7'd15: scale_of = 13'd333;
            7'd16: scale_of = 13'd313;  7'd17: scale_of = 13'd294;  7'd18: scale_of = 13'd278;
            7'd19: scale_of = 13'd263;  7'd20: scale_of = 13'd250;  7'd21: scale_of = 13'd238;
            7'd22: scale_of = 13'd227;  7'd23: scale_of = 13'd217;  7'd24: scale_of = 13'd208;
            7'd25: scale_of = 13'd200;  7'd26: scale_of = 13'd192;  7'd27: scale_of = 13'd185;
            7'd28: scale_of = 13'd179;  7'd29: scale_of = 13'd172;  7'd30: scale_of = 13'd167;
            7'd31: scale_of = 13'd161;  7'd32: scale_of = 13'd156;  7'd33: scale_of = 13'd152;
            7'd34: scale_of = 13'd147;  7'd35: scale_of = 13'd143;  7'd36: scale_of = 13'd139;
            7'd37: scale_of = 13'd135;  7'd38: scale_of = 13'd132;  7'd39: scale_of = 13'd128;
            7'd40: scale_of = 13'd125;  7'd41: scale_of = 13'd122;  7'd42: scale_of = 13'd119;
            7'd43: scale_of = 13'd116;  7'd44: scale_of = 13'd114;  7'd45: scale_of = 13'd111;
            7'd46: scale_of = 13'd109;  7'd47: scale_of = 13'd106;  7'd48: scale_of = 13'd104;
            7'd49: scale_of = 13'd102;  default: scale_of = 13'd5000;
        endcase
    endfunction

    // Reciprocal lookup for the rebuild pipeline, indexed by clamped step.
    reg [15:0] recip_lut [1:255];

    /* verilator coverage_off */
    integer q;
    initial begin
        for (q = 1; q <= 255; q = q + 1)
            recip_lut[q] = recip_of(q);
    end
    /* verilator coverage_on */

    // --------------------------------------------------------------------
    // Shadow-bank rebuild: a 3-stage pipeline sweeps the 128 table entries
    // ({chroma, position}) at one entry per clock.
    //   R1: step = base * scale                     (8 x 13 multiply)
    //   R2: divide by 100 as x1311 >> 17 and clamp  (1311 = round(2^17/100);
    //       exact for every reachable product, which the clamp bounds to
    //       [1, 255] in any case)
    //   R3: fold the AAN gain correction: recip_lut[step] * kf_of(pos)
    //   R4: round the fold (+2^13 >> 14) and write the shadow bank
    // The active bank flips only after the final write, so readers always
    // see one complete, self-consistent table set.
    // --------------------------------------------------------------------
    reg        active_r;
    reg        rebuilding;
    reg        issuing;
    reg [6:0]  pos;                   // {chroma, position} sweep counter
    reg [6:0]  last_quality;
    reg [12:0] scale_r;

    reg        r1_v;
    reg [6:0]  r1_pos;
    reg [20:0] r1_step;               // 121 * 5000 needs 21 bits

    reg        r2_v;
    reg [6:0]  r2_pos;
    reg [7:0]  r2_q;

    reg        r3_v;
    reg [6:0]  r3_pos;
    reg [7:0]  r3_q;
    reg [30:0] r3_fold;               // 16-bit reciprocal x 15-bit kf

    // Bits [13:0] of the fold are the discarded Q14 fraction.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [30:0] r3_sum = r3_fold + 31'd8192;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [16:0] r3_rounded = r3_sum[30:14];

    // Bits [16:0] are the discarded fraction of the x1311 >> 17 divide.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] r2_scaled = ({11'd0, r1_step} + 32'd50) * 32'd1311;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0]  r2_clamped = (r2_scaled[31:17] > 15'd255) ? 8'd255 :
                             (r2_scaled[31:17] < 15'd1)   ? 8'd1   :
                             r2_scaled[24:17];

    always @(posedge clk) begin
        if (!rst_n) begin
            active_r     <= 1'b0;
            rebuilding   <= 1'b0;
            issuing      <= 1'b0;
            pos          <= 7'd0;
            last_quality <= 7'd0;
            r1_v         <= 1'b0;
            r2_v         <= 1'b0;
            r3_v         <= 1'b0;
        end else begin
            if (!rebuilding) begin
                r1_v <= 1'b0;
                if (quality != last_quality) begin
                    last_quality <= quality;
                    scale_r      <= scale_of(quality);
                    pos          <= 7'd0;
                    issuing      <= 1'b1;
                    rebuilding   <= 1'b1;
                end
            end else begin
                r1_v <= issuing;
                if (issuing) begin
                    r1_pos  <= pos;
                    r1_step <= {13'd0, pos[6] ? base_chroma(pos[5:0])
                                              : base_luma(pos[5:0])}
                               * {8'd0, scale_r};
                    if (pos == 7'd127)
                        issuing <= 1'b0;
                    else
                        pos <= pos + 7'd1;
                end
            end

            r2_v   <= r1_v;
            r2_pos <= r1_pos;
            r2_q   <= r2_clamped;

            r3_v    <= r2_v;
            r3_pos  <= r2_pos;
            r3_q    <= r2_q;
            r3_fold <= recip_lut[r2_q] * kf_of(r2_pos[5:0]);

            if (r3_v) begin
                qstep_tbl[{~active_r, r3_pos}] <= r3_q;
                recip_tbl[{~active_r, r3_pos}] <= r3_rounded;
                if (r3_pos == 7'd127) begin
                    active_r   <= ~active_r;
                    rebuilding <= 1'b0;
                end
            end
        end
    end

    assign bank_active = active_r;

    // Both banks start at step 1, reciprocals folded; the first quality
    // write after reset triggers a rebuild.
    /* verilator coverage_off */
    // Elaboration-only integer; the folded value is at most 107470 (17b).
    /* verilator lint_off UNUSEDSIGNAL */
    integer k, rf;
    /* verilator lint_on UNUSEDSIGNAL */
    initial begin
        for (k = 0; k < 256; k = k + 1) begin
            qstep_tbl[k] = 8'd1;
            rf = (65535 * kf_of(k[5:0]) + 8192) >> 14;
            recip_tbl[k] = rf[16:0];
        end
    end
    /* verilator coverage_on */

end else begin : g_lite_tables

    // Tables fixed at elaboration. The scale factor and the /100 use floor
    // division here (elaboration-time integer arithmetic).
    /* verilator coverage_off */
    integer i, scale, step, rf;
    initial begin
        scale = (LITE_QUALITY >= 50) ? 200 - 2 * LITE_QUALITY :
                (LITE_QUALITY >= 1)  ? 5000 / LITE_QUALITY    : 5000;
        for (i = 0; i < 64; i = i + 1) begin
            step = (base_luma(i[5:0]) * scale + 50) / 100;
            if (step < 1)   step = 1;
            if (step > 255) step = 255;
            qstep_tbl[i]     = step[7:0];
            rf = (recip_of(step) * kf_of(i[5:0]) + 8192) >> 14;
            recip_tbl[i]     = rf[16:0];

            step = (base_chroma(i[5:0]) * scale + 50) / 100;
            if (step < 1)   step = 1;
            if (step > 255) step = 255;
            qstep_tbl[64 + i] = step[7:0];
            rf = (recip_of(step) * kf_of(i[5:0]) + 8192) >> 14;
            recip_tbl[64 + i] = rf[16:0];
        end
    end
    /* verilator coverage_on */

    assign bank_active = 1'b0;

end
endgenerate

    // ========================================================================
    // Step-table read port (JFIF writer), one-cycle registered read of the
    // active bank.
    // ========================================================================
    always @(posedge clk)
        qt_rd_data <= qstep_tbl[{bank_active, qt_rd_is_chroma, qt_rd_addr}];

    // ========================================================================
    // Coefficient position within the block: in_sob restarts the count, so
    // the first coefficient reads position 0 combinationally while the
    // counter is still being reset.
    // ========================================================================
    reg [5:0] coeff_idx;

    always @(posedge clk) begin
        if (!rst_n)
            coeff_idx <= 6'd0;
        else if (in_valid)
            coeff_idx <= in_sob ? 6'd1 : coeff_idx + 6'd1;
    end

    wire [5:0] lookup_idx = in_sob ? 6'd0 : coeff_idx;

    // Table selection is sampled at the first coefficient of each block and
    // held: comp_id and the active bank may change mid-block without
    // affecting the block in flight.
    reg  latched_is_chroma;
    reg  latched_bank;
    wire is_chroma_now = (comp_id >= 2'd2);
    wire use_chroma = (in_valid && in_sob) ? is_chroma_now : latched_is_chroma;
    wire use_bank   = (in_valid && in_sob) ? bank_active   : latched_bank;

    always @(posedge clk) begin
        if (!rst_n) begin
            latched_is_chroma <= 1'b0;
            latched_bank      <= 1'b0;
        end else if (in_valid && in_sob) begin
            latched_is_chroma <= is_chroma_now;
            latched_bank      <= bank_active;
        end
    end

    // ========================================================================
    // Datapath: 4 pipeline stages, one coefficient per clock.
    //   P1: register inputs, read reciprocal
    //   P2: split into sign and magnitude
    //   P3: magnitude x reciprocal (one DSP multiply)
    //   P4: round, restore sign
    //
    // Output bound: the scaled input satisfies |in| ~= |X_orth| * g_u*g_v
    // and recip_f ~= 2^16 / (step * g_u*g_v), so the product is
    // ~= |X_orth| * 2^16 / step <= 2^14 * 2^16 for the encoder's input
    // domain (|X_orth| <= 2^14 at 8-bit pixels) — bits [32:16] of the
    // rounded product stay under 2^15 with margin for the fixed-point
    // epsilon, and the 16-bit output cannot overflow in-domain.
    // ========================================================================
    reg               p1_valid, p1_sof, p1_sob;
    reg signed [15:0] p1_data;
    reg        [16:0] p1_recip;

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
            p1_recip <= recip_tbl[{use_bank, use_chroma, lookup_idx}];
        end
    end

    reg        p2_valid, p2_sof, p2_sob, p2_sign;
    reg [15:0] p2_mag;
    reg [16:0] p2_recip;

    always @(posedge clk) begin
        if (!rst_n) begin
            p2_valid <= 1'b0;
            p2_sof   <= 1'b0;
            p2_sob   <= 1'b0;
        end else begin
            p2_valid <= p1_valid;
            p2_sof   <= p1_sof;
            p2_sob   <= p1_sob;
            p2_sign  <= p1_data[15];
            p2_mag   <= p1_data[15] ? (-p1_data) : p1_data;
            p2_recip <= p1_recip;
        end
    end

    reg        p3_valid, p3_sof, p3_sob, p3_sign;
    reg [32:0] p3_product;

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
            p3_product <= {17'd0, p2_mag} * {16'd0, p2_recip};
        end
    end

    // Bits [15:0] of the sum are the discarded fraction of the >> 16;
    // bits above the in-domain bound duplicate the sign (see the bound
    // note above).
    /* verilator lint_off UNUSEDSIGNAL */
    wire [32:0] p4_sum = p3_product + 33'd32768;
    wire [16:0] p4_rounded = p4_sum[32:16];
    wire signed [17:0] p4_signed = p3_sign ? -$signed({1'b0, p4_rounded})
                                           :  $signed({1'b0, p4_rounded});
    /* verilator lint_on UNUSEDSIGNAL */

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
            if (p3_valid)
                out_data <= p4_signed[15:0];
        end
    end

endmodule
