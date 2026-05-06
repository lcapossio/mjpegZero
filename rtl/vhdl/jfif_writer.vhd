-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jfif_writer is
    generic (
        IMG_WIDTH     : natural := 1280;
        IMG_HEIGHT    : natural := 720;
        LITE_MODE     : natural := 0;
        LITE_QUALITY  : natural := 95;
        EXIF_ENABLE   : natural := 0;
        EXIF_X_RES    : natural := 72;
        EXIF_Y_RES    : natural := 72;
        EXIF_RES_UNIT : natural := 2
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;
        frame_start      : in  std_logic;
        frame_done       : in  std_logic;
        restart_interval : in  std_logic_vector(15 downto 0);
        qt_rd_addr       : out std_logic_vector(5 downto 0);
        qt_rd_is_chroma  : out std_logic;
        qt_rd_data       : in  std_logic_vector(7 downto 0);
        scan_valid       : in  std_logic;
        scan_data        : in  std_logic_vector(7 downto 0);
        scan_last        : in  std_logic;
        scan_ready       : out std_logic;
        m_axis_tvalid    : out std_logic;
        m_axis_tdata     : out std_logic_vector(7 downto 0);
        m_axis_tlast     : out std_logic;
        headers_done     : out std_logic
    );
end entity;

architecture rtl of jfif_writer is
    type byte_array_t is array (natural range <>) of natural range 0 to 255;
    type nat_array64_t is array (0 to 63) of natural;

    constant ZIGZAG_ORDER : nat_array64_t := (
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    );

    constant BASE_LUMA : nat_array64_t := (
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    );

    constant BASE_CHROMA : nat_array64_t := (
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99
    );

    constant SOI_APP0_ROM : byte_array_t(0 to 19) := (
        16#FF#, 16#D8#, 16#FF#, 16#E0#, 16#00#, 16#10#, 16#4A#, 16#46#,
        16#49#, 16#46#, 16#00#, 16#01#, 16#01#, 16#00#, 16#00#, 16#01#,
        16#00#, 16#01#, 16#00#, 16#00#
    );

    constant DHT_ROM : byte_array_t(0 to 431) := (
        16#FF#, 16#C4#, 16#00#, 16#1F#, 16#00#, 16#00#, 16#01#, 16#05#, 16#01#, 16#01#, 16#01#, 16#01#,
        16#01#, 16#01#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#01#, 16#02#,
        16#03#, 16#04#, 16#05#, 16#06#, 16#07#, 16#08#, 16#09#, 16#0A#, 16#0B#, 16#FF#, 16#C4#, 16#00#,
        16#B5#, 16#10#, 16#00#, 16#02#, 16#01#, 16#03#, 16#03#, 16#02#, 16#04#, 16#03#, 16#05#, 16#05#,
        16#04#, 16#04#, 16#00#, 16#00#, 16#01#, 16#7D#, 16#01#, 16#02#, 16#03#, 16#00#, 16#04#, 16#11#,
        16#05#, 16#12#, 16#21#, 16#31#, 16#41#, 16#06#, 16#13#, 16#51#, 16#61#, 16#07#, 16#22#, 16#71#,
        16#14#, 16#32#, 16#81#, 16#91#, 16#A1#, 16#08#, 16#23#, 16#42#, 16#B1#, 16#C1#, 16#15#, 16#52#,
        16#D1#, 16#F0#, 16#24#, 16#33#, 16#62#, 16#72#, 16#82#, 16#09#, 16#0A#, 16#16#, 16#17#, 16#18#,
        16#19#, 16#1A#, 16#25#, 16#26#, 16#27#, 16#28#, 16#29#, 16#2A#, 16#34#, 16#35#, 16#36#, 16#37#,
        16#38#, 16#39#, 16#3A#, 16#43#, 16#44#, 16#45#, 16#46#, 16#47#, 16#48#, 16#49#, 16#4A#, 16#53#,
        16#54#, 16#55#, 16#56#, 16#57#, 16#58#, 16#59#, 16#5A#, 16#63#, 16#64#, 16#65#, 16#66#, 16#67#,
        16#68#, 16#69#, 16#6A#, 16#73#, 16#74#, 16#75#, 16#76#, 16#77#, 16#78#, 16#79#, 16#7A#, 16#83#,
        16#84#, 16#85#, 16#86#, 16#87#, 16#88#, 16#89#, 16#8A#, 16#92#, 16#93#, 16#94#, 16#95#, 16#96#,
        16#97#, 16#98#, 16#99#, 16#9A#, 16#A2#, 16#A3#, 16#A4#, 16#A5#, 16#A6#, 16#A7#, 16#A8#, 16#A9#,
        16#AA#, 16#B2#, 16#B3#, 16#B4#, 16#B5#, 16#B6#, 16#B7#, 16#B8#, 16#B9#, 16#BA#, 16#C2#, 16#C3#,
        16#C4#, 16#C5#, 16#C6#, 16#C7#, 16#C8#, 16#C9#, 16#CA#, 16#D2#, 16#D3#, 16#D4#, 16#D5#, 16#D6#,
        16#D7#, 16#D8#, 16#D9#, 16#DA#, 16#E1#, 16#E2#, 16#E3#, 16#E4#, 16#E5#, 16#E6#, 16#E7#, 16#E8#,
        16#E9#, 16#EA#, 16#F1#, 16#F2#, 16#F3#, 16#F4#, 16#F5#, 16#F6#, 16#F7#, 16#F8#, 16#F9#, 16#FA#,
        16#FF#, 16#C4#, 16#00#, 16#1F#, 16#01#, 16#00#, 16#03#, 16#01#, 16#01#, 16#01#, 16#01#, 16#01#,
        16#01#, 16#01#, 16#01#, 16#01#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#01#, 16#02#,
        16#03#, 16#04#, 16#05#, 16#06#, 16#07#, 16#08#, 16#09#, 16#0A#, 16#0B#, 16#FF#, 16#C4#, 16#00#,
        16#B5#, 16#11#, 16#00#, 16#02#, 16#01#, 16#02#, 16#04#, 16#04#, 16#03#, 16#04#, 16#07#, 16#05#,
        16#04#, 16#04#, 16#00#, 16#01#, 16#02#, 16#77#, 16#00#, 16#01#, 16#02#, 16#03#, 16#11#, 16#04#,
        16#05#, 16#21#, 16#31#, 16#06#, 16#12#, 16#41#, 16#51#, 16#07#, 16#61#, 16#71#, 16#13#, 16#22#,
        16#32#, 16#81#, 16#08#, 16#14#, 16#42#, 16#91#, 16#A1#, 16#B1#, 16#C1#, 16#09#, 16#23#, 16#33#,
        16#52#, 16#F0#, 16#15#, 16#62#, 16#72#, 16#D1#, 16#0A#, 16#16#, 16#24#, 16#34#, 16#E1#, 16#25#,
        16#F1#, 16#17#, 16#18#, 16#19#, 16#1A#, 16#26#, 16#27#, 16#28#, 16#29#, 16#2A#, 16#35#, 16#36#,
        16#37#, 16#38#, 16#39#, 16#3A#, 16#43#, 16#44#, 16#45#, 16#46#, 16#47#, 16#48#, 16#49#, 16#4A#,
        16#53#, 16#54#, 16#55#, 16#56#, 16#57#, 16#58#, 16#59#, 16#5A#, 16#63#, 16#64#, 16#65#, 16#66#,
        16#67#, 16#68#, 16#69#, 16#6A#, 16#73#, 16#74#, 16#75#, 16#76#, 16#77#, 16#78#, 16#79#, 16#7A#,
        16#82#, 16#83#, 16#84#, 16#85#, 16#86#, 16#87#, 16#88#, 16#89#, 16#8A#, 16#92#, 16#93#, 16#94#,
        16#95#, 16#96#, 16#97#, 16#98#, 16#99#, 16#9A#, 16#A2#, 16#A3#, 16#A4#, 16#A5#, 16#A6#, 16#A7#,
        16#A8#, 16#A9#, 16#AA#, 16#B2#, 16#B3#, 16#B4#, 16#B5#, 16#B6#, 16#B7#, 16#B8#, 16#B9#, 16#BA#,
        16#C2#, 16#C3#, 16#C4#, 16#C5#, 16#C6#, 16#C7#, 16#C8#, 16#C9#, 16#CA#, 16#D2#, 16#D3#, 16#D4#,
        16#D5#, 16#D6#, 16#D7#, 16#D8#, 16#D9#, 16#DA#, 16#E2#, 16#E3#, 16#E4#, 16#E5#, 16#E6#, 16#E7#,
        16#E8#, 16#E9#, 16#EA#, 16#F2#, 16#F3#, 16#F4#, 16#F5#, 16#F6#, 16#F7#, 16#F8#, 16#F9#, 16#FA#
    );

    constant SOS_ROM : byte_array_t(0 to 13) := (
        16#FF#, 16#DA#, 16#00#, 16#0C#, 16#03#, 16#01#, 16#00#,
        16#02#, 16#11#, 16#03#, 16#11#, 16#00#, 16#3F#, 16#00#
    );

    type state_t is (S_IDLE, S_SOI_APP0, S_APP1, S_DQT_L_HDR, S_DQT_L_DATA,
                     S_DQT_C_HDR, S_DQT_C_DATA, S_SOF0, S_DRI, S_DHT, S_SOS,
                     S_SCAN_DATA, S_EOI_0, S_EOI_1, S_DONE);
    signal state : state_t := S_IDLE;
    signal seg_idx : unsigned(9 downto 0) := (others => '0');
    signal qt_data_valid : std_logic := '0';

    function b(v : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(v mod 256, 8));
    end function;

    function hi16(v : natural) return std_logic_vector is
    begin
        return b((v / 256) mod 256);
    end function;

    function lo16(v : natural) return std_logic_vector is
    begin
        return b(v mod 256);
    end function;

    function le_byte(v : natural; idx : natural) return std_logic_vector is
    begin
        case idx is
            when 0 => return b(v mod 256);
            when 1 => return b((v / 256) mod 256);
            when 2 => return b((v / 65536) mod 256);
            when others => return b((v / 16777216) mod 256);
        end case;
    end function;

    function scale_lite(q : natural) return natural is
    begin
        if q >= 50 then
            return 200 - 2 * q;
        elsif q >= 1 then
            return 5000 / q;
        else
            return 5000;
        end if;
    end function;

    function scaled_q(base : natural) return std_logic_vector is
        variable q : natural;
    begin
        q := (base * scale_lite(LITE_QUALITY) + 50) / 100;
        if q < 1 then q := 1; end if;
        if q > 255 then q := 255; end if;
        return b(q);
    end function;

    function lite_q(is_chroma : std_logic; idx : natural) return std_logic_vector is
    begin
        if is_chroma = '1' then
            return scaled_q(BASE_CHROMA(ZIGZAG_ORDER(idx)));
        end if;
        return scaled_q(BASE_LUMA(ZIGZAG_ORDER(idx)));
    end function;

    function app1_byte(idx : natural) return std_logic_vector is
    begin
        case idx is
            when 0 => return x"FF"; when 1 => return x"E1";
            when 2 => return x"00"; when 3 => return x"4A";
            when 4 => return x"45"; when 5 => return x"78"; when 6 => return x"69";
            when 7 => return x"66"; when 8 => return x"00"; when 9 => return x"00";
            when 10 => return x"49"; when 11 => return x"49";
            when 12 => return x"2A"; when 13 => return x"00";
            when 14 => return x"08"; when 15 => return x"00"; when 16 => return x"00"; when 17 => return x"00";
            when 18 => return x"03"; when 19 => return x"00";
            when 20 => return x"1A"; when 21 => return x"01"; when 22 => return x"05"; when 23 => return x"00";
            when 24 => return x"01"; when 25 => return x"00"; when 26 => return x"00"; when 27 => return x"00";
            when 28 => return x"32"; when 29 => return x"00"; when 30 => return x"00"; when 31 => return x"00";
            when 32 => return x"1B"; when 33 => return x"01"; when 34 => return x"05"; when 35 => return x"00";
            when 36 => return x"01"; when 37 => return x"00"; when 38 => return x"00"; when 39 => return x"00";
            when 40 => return x"3A"; when 41 => return x"00"; when 42 => return x"00"; when 43 => return x"00";
            when 44 => return x"28"; when 45 => return x"01"; when 46 => return x"03"; when 47 => return x"00";
            when 48 => return x"01"; when 49 => return x"00"; when 50 => return x"00"; when 51 => return x"00";
            when 52 => return le_byte(EXIF_RES_UNIT, 0); when 53 => return le_byte(EXIF_RES_UNIT, 1);
            when 54 => return x"00"; when 55 => return x"00";
            when 56 => return x"00"; when 57 => return x"00"; when 58 => return x"00"; when 59 => return x"00";
            when 60 => return le_byte(EXIF_X_RES, 0); when 61 => return le_byte(EXIF_X_RES, 1);
            when 62 => return le_byte(EXIF_X_RES, 2); when 63 => return le_byte(EXIF_X_RES, 3);
            when 64 => return x"01"; when 65 => return x"00"; when 66 => return x"00"; when 67 => return x"00";
            when 68 => return le_byte(EXIF_Y_RES, 0); when 69 => return le_byte(EXIF_Y_RES, 1);
            when 70 => return le_byte(EXIF_Y_RES, 2); when 71 => return le_byte(EXIF_Y_RES, 3);
            when 72 => return x"01"; when 73 => return x"00"; when 74 => return x"00"; when others => return x"00";
        end case;
    end function;

begin
    scan_ready <= '1' when state = S_SCAN_DATA else '0';
    headers_done <= '1' when state = S_SCAN_DATA or state = S_EOI_0 or state = S_EOI_1 or state = S_DONE else '0';

    process (clk)
        variable idx : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state <= S_IDLE;
                seg_idx <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tdata <= (others => '0');
                m_axis_tlast <= '0';
                qt_rd_addr <= (others => '0');
                qt_rd_is_chroma <= '0';
                qt_data_valid <= '0';
            else
                idx := to_integer(seg_idx);
                case state is
                    when S_IDLE =>
                        m_axis_tvalid <= '0';
                        m_axis_tlast <= '0';
                        qt_data_valid <= '0';
                        if frame_start = '1' then
                            state <= S_SOI_APP0;
                            seg_idx <= (others => '0');
                        end if;

                    when S_SOI_APP0 =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= b(SOI_APP0_ROM(idx));
                        if seg_idx = 19 then
                            seg_idx <= (others => '0');
                            if EXIF_ENABLE /= 0 then state <= S_APP1; else state <= S_DQT_L_HDR; end if;
                        else
                            seg_idx <= seg_idx + 1;
                        end if;

                    when S_APP1 =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= app1_byte(idx);
                        if seg_idx = 75 then
                            state <= S_DQT_L_HDR;
                            seg_idx <= (others => '0');
                        else
                            seg_idx <= seg_idx + 1;
                        end if;

                    when S_DQT_L_HDR =>
                        m_axis_tvalid <= '1';
                        case idx is
                            when 0 => m_axis_tdata <= x"FF";
                            when 1 => m_axis_tdata <= x"DB";
                            when 2 => m_axis_tdata <= x"00";
                            when 3 => m_axis_tdata <= x"43";
                            when 4 => m_axis_tdata <= x"00";
                            when others => m_axis_tdata <= x"00";
                        end case;
                        if seg_idx = 4 then
                            state <= S_DQT_L_DATA;
                            seg_idx <= (others => '0');
                            qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(0), 6));
                            qt_rd_is_chroma <= '0';
                            qt_data_valid <= '0';
                        else
                            seg_idx <= seg_idx + 1;
                        end if;

                    when S_DQT_L_DATA =>
                        if LITE_MODE /= 0 then
                            m_axis_tvalid <= '1';
                            m_axis_tdata <= lite_q('0', idx);
                            if seg_idx = 63 then state <= S_DQT_C_HDR; seg_idx <= (others => '0'); else seg_idx <= seg_idx + 1; end if;
                        elsif qt_data_valid = '0' then
                            m_axis_tvalid <= '0';
                            qt_data_valid <= '1';
                            if seg_idx < 63 then qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(idx + 1), 6)); end if;
                        else
                            m_axis_tvalid <= '1';
                            m_axis_tdata <= qt_rd_data;
                            if seg_idx = 63 then
                                state <= S_DQT_C_HDR; seg_idx <= (others => '0'); qt_data_valid <= '0';
                            else
                                seg_idx <= seg_idx + 1;
                                if seg_idx + 1 < 63 then qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(idx + 2), 6)); else qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(63), 6)); end if;
                            end if;
                        end if;

                    when S_DQT_C_HDR =>
                        m_axis_tvalid <= '1';
                        case idx is
                            when 0 => m_axis_tdata <= x"FF";
                            when 1 => m_axis_tdata <= x"DB";
                            when 2 => m_axis_tdata <= x"00";
                            when 3 => m_axis_tdata <= x"43";
                            when 4 => m_axis_tdata <= x"01";
                            when others => m_axis_tdata <= x"00";
                        end case;
                        if seg_idx = 4 then
                            state <= S_DQT_C_DATA;
                            seg_idx <= (others => '0');
                            qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(0), 6));
                            qt_rd_is_chroma <= '1';
                            qt_data_valid <= '0';
                        else
                            seg_idx <= seg_idx + 1;
                        end if;

                    when S_DQT_C_DATA =>
                        if LITE_MODE /= 0 then
                            m_axis_tvalid <= '1';
                            m_axis_tdata <= lite_q('1', idx);
                            if seg_idx = 63 then state <= S_SOF0; seg_idx <= (others => '0'); else seg_idx <= seg_idx + 1; end if;
                        elsif qt_data_valid = '0' then
                            m_axis_tvalid <= '0';
                            qt_data_valid <= '1';
                            if seg_idx < 63 then qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(idx + 1), 6)); end if;
                        else
                            m_axis_tvalid <= '1';
                            m_axis_tdata <= qt_rd_data;
                            if seg_idx = 63 then
                                state <= S_SOF0; seg_idx <= (others => '0'); qt_data_valid <= '0';
                            else
                                seg_idx <= seg_idx + 1;
                                if seg_idx + 1 < 63 then qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(idx + 2), 6)); else qt_rd_addr <= std_logic_vector(to_unsigned(ZIGZAG_ORDER(63), 6)); end if;
                            end if;
                        end if;

                    when S_SOF0 =>
                        m_axis_tvalid <= '1';
                        case idx is
                            when 0 => m_axis_tdata <= x"FF";
                            when 1 => m_axis_tdata <= x"C0";
                            when 2 => m_axis_tdata <= x"00";
                            when 3 => m_axis_tdata <= x"11";
                            when 4 => m_axis_tdata <= x"08";
                            when 5 => m_axis_tdata <= hi16(IMG_HEIGHT);
                            when 6 => m_axis_tdata <= lo16(IMG_HEIGHT);
                            when 7 => m_axis_tdata <= hi16(IMG_WIDTH);
                            when 8 => m_axis_tdata <= lo16(IMG_WIDTH);
                            when 9 => m_axis_tdata <= x"03";
                            when 10 => m_axis_tdata <= x"01";
                            when 11 => m_axis_tdata <= x"21";
                            when 12 => m_axis_tdata <= x"00";
                            when 13 => m_axis_tdata <= x"02";
                            when 14 => m_axis_tdata <= x"11";
                            when 15 => m_axis_tdata <= x"01";
                            when 16 => m_axis_tdata <= x"03";
                            when 17 => m_axis_tdata <= x"11";
                            when others => m_axis_tdata <= x"01";
                        end case;
                        if seg_idx = 18 then
                            seg_idx <= (others => '0');
                            if unsigned(restart_interval) /= 0 then state <= S_DRI; else state <= S_DHT; end if;
                        else
                            seg_idx <= seg_idx + 1;
                        end if;

                    when S_DRI =>
                        m_axis_tvalid <= '1';
                        case idx is
                            when 0 => m_axis_tdata <= x"FF";
                            when 1 => m_axis_tdata <= x"DD";
                            when 2 => m_axis_tdata <= x"00";
                            when 3 => m_axis_tdata <= x"04";
                            when 4 => m_axis_tdata <= restart_interval(15 downto 8);
                            when 5 => m_axis_tdata <= restart_interval(7 downto 0);
                            when others => m_axis_tdata <= x"00";
                        end case;
                        if seg_idx = 5 then state <= S_DHT; seg_idx <= (others => '0'); else seg_idx <= seg_idx + 1; end if;

                    when S_DHT =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= b(DHT_ROM(idx));
                        if seg_idx = 431 then state <= S_SOS; seg_idx <= (others => '0'); else seg_idx <= seg_idx + 1; end if;

                    when S_SOS =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= b(SOS_ROM(idx));
                        if seg_idx = 13 then state <= S_SCAN_DATA; seg_idx <= (others => '0'); else seg_idx <= seg_idx + 1; end if;

                    when S_SCAN_DATA =>
                        if scan_valid = '1' and scan_last = '1' then
                            m_axis_tvalid <= '0';
                            state <= S_EOI_0;
                        else
                            m_axis_tvalid <= scan_valid;
                            m_axis_tdata <= scan_data;
                            m_axis_tlast <= '0';
                        end if;

                    when S_EOI_0 =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= x"FF";
                        m_axis_tlast <= '0';
                        state <= S_EOI_1;

                    when S_EOI_1 =>
                        m_axis_tvalid <= '1';
                        m_axis_tdata <= x"D9";
                        m_axis_tlast <= '1';
                        state <= S_DONE;

                    when S_DONE =>
                        m_axis_tvalid <= '0';
                        m_axis_tlast <= '0';
                        state <= S_IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
