-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity huffman_encoder is
    generic (
        LITE_MODE : natural := 0
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        comp_id   : in  std_logic_vector(1 downto 0);
        restart   : in  std_logic;
        in_valid  : in  std_logic;
        in_data   : in  std_logic_vector(15 downto 0);
        in_sob    : in  std_logic;
        out_valid : out std_logic;
        out_bits  : out std_logic_vector(31 downto 0);
        out_len   : out std_logic_vector(5 downto 0);
        out_sob   : out std_logic;
        out_eob   : out std_logic;
        out_ready : in  std_logic
    );
end entity;

architecture rtl of huffman_encoder is
    function dc_luma_lookup(sym : natural) return std_logic_vector is
    begin
        case sym is
            when 0 => return "00100000000000000000";
            when 1 => return "00110100000000000000";
            when 2 => return "00110110000000000000";
            when 3 => return "00111000000000000000";
            when 4 => return "00111010000000000000";
            when 5 => return "00111100000000000000";
            when 6 => return "01001110000000000000";
            when 7 => return "01011111000000000000";
            when 8 => return "01101111100000000000";
            when 9 => return "01111111110000000000";
            when 10 => return "10001111111000000000";
            when 11 => return "10011111111100000000";
            when others => return x"00000";
        end case;
    end function;

    function dc_chroma_lookup(sym : natural) return std_logic_vector is
    begin
        case sym is
            when 0 => return "00100000000000000000";
            when 1 => return "00100100000000000000";
            when 2 => return "00101000000000000000";
            when 3 => return "00111100000000000000";
            when 4 => return "01001110000000000000";
            when 5 => return "01011111000000000000";
            when 6 => return "01101111100000000000";
            when 7 => return "01111111110000000000";
            when 8 => return "10001111111000000000";
            when 9 => return "10011111111100000000";
            when 10 => return "10101111111110000000";
            when 11 => return "10111111111111000000";
            when others => return x"00000";
        end case;
    end function;

    function ac_luma_lookup(sym : natural) return std_logic_vector is
    begin
        case sym is
            when 16#00# => return "001001010000000000000";
            when 16#01# => return "000100000000000000000";
            when 16#02# => return "000100100000000000000";
            when 16#03# => return "000111000000000000000";
            when 16#04# => return "001001011000000000000";
            when 16#05# => return "001011101000000000000";
            when 16#06# => return "001111111000000000000";
            when 16#07# => return "010001111100000000000";
            when 16#08# => return "010101111110110000000";
            when 16#09# => return "100001111111110000010";
            when 16#0A# => return "100001111111110000011";
            when 16#11# => return "001001100000000000000";
            when 16#12# => return "001011101100000000000";
            when 16#13# => return "001111111001000000000";
            when 16#14# => return "010011111101100000000";
            when 16#15# => return "010111111111011000000";
            when 16#16# => return "100001111111110000100";
            when 16#17# => return "100001111111110000101";
            when 16#18# => return "100001111111110000110";
            when 16#19# => return "100001111111110000111";
            when 16#1A# => return "100001111111110001000";
            when 16#21# => return "001011110000000000000";
            when 16#22# => return "010001111100100000000";
            when 16#23# => return "010101111110111000000";
            when 16#24# => return "011001111111101000000";
            when 16#25# => return "100001111111110001001";
            when 16#26# => return "100001111111110001010";
            when 16#27# => return "100001111111110001011";
            when 16#28# => return "100001111111110001100";
            when 16#29# => return "100001111111110001101";
            when 16#2A# => return "100001111111110001110";
            when 16#31# => return "001101110100000000000";
            when 16#32# => return "010011111101110000000";
            when 16#33# => return "011001111111101010000";
            when 16#34# => return "100001111111110001111";
            when 16#35# => return "100001111111110010000";
            when 16#36# => return "100001111111110010001";
            when 16#37# => return "100001111111110010010";
            when 16#38# => return "100001111111110010011";
            when 16#39# => return "100001111111110010100";
            when 16#3A# => return "100001111111110010101";
            when 16#41# => return "001101110110000000000";
            when 16#42# => return "010101111111000000000";
            when 16#43# => return "100001111111110010110";
            when 16#44# => return "100001111111110010111";
            when 16#45# => return "100001111111110011000";
            when 16#46# => return "100001111111110011001";
            when 16#47# => return "100001111111110011010";
            when 16#48# => return "100001111111110011011";
            when 16#49# => return "100001111111110011100";
            when 16#4A# => return "100001111111110011101";
            when 16#51# => return "001111111010000000000";
            when 16#52# => return "010111111111011100000";
            when 16#53# => return "100001111111110011110";
            when 16#54# => return "100001111111110011111";
            when 16#55# => return "100001111111110100000";
            when 16#56# => return "100001111111110100001";
            when 16#57# => return "100001111111110100010";
            when 16#58# => return "100001111111110100011";
            when 16#59# => return "100001111111110100100";
            when 16#5A# => return "100001111111110100101";
            when 16#61# => return "001111111011000000000";
            when 16#62# => return "011001111111101100000";
            when 16#63# => return "100001111111110100110";
            when 16#64# => return "100001111111110100111";
            when 16#65# => return "100001111111110101000";
            when 16#66# => return "100001111111110101001";
            when 16#67# => return "100001111111110101010";
            when 16#68# => return "100001111111110101011";
            when 16#69# => return "100001111111110101100";
            when 16#6A# => return "100001111111110101101";
            when 16#71# => return "010001111101000000000";
            when 16#72# => return "011001111111101110000";
            when 16#73# => return "100001111111110101110";
            when 16#74# => return "100001111111110101111";
            when 16#75# => return "100001111111110110000";
            when 16#76# => return "100001111111110110001";
            when 16#77# => return "100001111111110110010";
            when 16#78# => return "100001111111110110011";
            when 16#79# => return "100001111111110110100";
            when 16#7A# => return "100001111111110110101";
            when 16#81# => return "010011111110000000000";
            when 16#82# => return "011111111111110000000";
            when 16#83# => return "100001111111110110110";
            when 16#84# => return "100001111111110110111";
            when 16#85# => return "100001111111110111000";
            when 16#86# => return "100001111111110111001";
            when 16#87# => return "100001111111110111010";
            when 16#88# => return "100001111111110111011";
            when 16#89# => return "100001111111110111100";
            when 16#8A# => return "100001111111110111101";
            when 16#91# => return "010011111110010000000";
            when 16#92# => return "100001111111110111110";
            when 16#93# => return "100001111111110111111";
            when 16#94# => return "100001111111111000000";
            when 16#95# => return "100001111111111000001";
            when 16#96# => return "100001111111111000010";
            when 16#97# => return "100001111111111000011";
            when 16#98# => return "100001111111111000100";
            when 16#99# => return "100001111111111000101";
            when 16#9A# => return "100001111111111000110";
            when 16#A1# => return "010011111110100000000";
            when 16#A2# => return "100001111111111000111";
            when 16#A3# => return "100001111111111001000";
            when 16#A4# => return "100001111111111001001";
            when 16#A5# => return "100001111111111001010";
            when 16#A6# => return "100001111111111001011";
            when 16#A7# => return "100001111111111001100";
            when 16#A8# => return "100001111111111001101";
            when 16#A9# => return "100001111111111001110";
            when 16#AA# => return "100001111111111001111";
            when 16#B1# => return "010101111111001000000";
            when 16#B2# => return "100001111111111010000";
            when 16#B3# => return "100001111111111010001";
            when 16#B4# => return "100001111111111010010";
            when 16#B5# => return "100001111111111010011";
            when 16#B6# => return "100001111111111010100";
            when 16#B7# => return "100001111111111010101";
            when 16#B8# => return "100001111111111010110";
            when 16#B9# => return "100001111111111010111";
            when 16#BA# => return "100001111111111011000";
            when 16#C1# => return "010101111111010000000";
            when 16#C2# => return "100001111111111011001";
            when 16#C3# => return "100001111111111011010";
            when 16#C4# => return "100001111111111011011";
            when 16#C5# => return "100001111111111011100";
            when 16#C6# => return "100001111111111011101";
            when 16#C7# => return "100001111111111011110";
            when 16#C8# => return "100001111111111011111";
            when 16#C9# => return "100001111111111100000";
            when 16#CA# => return "100001111111111100001";
            when 16#D1# => return "010111111111100000000";
            when 16#D2# => return "100001111111111100010";
            when 16#D3# => return "100001111111111100011";
            when 16#D4# => return "100001111111111100100";
            when 16#D5# => return "100001111111111100101";
            when 16#D6# => return "100001111111111100110";
            when 16#D7# => return "100001111111111100111";
            when 16#D8# => return "100001111111111101000";
            when 16#D9# => return "100001111111111101001";
            when 16#DA# => return "100001111111111101010";
            when 16#E1# => return "100001111111111101011";
            when 16#E2# => return "100001111111111101100";
            when 16#E3# => return "100001111111111101101";
            when 16#E4# => return "100001111111111101110";
            when 16#E5# => return "100001111111111101111";
            when 16#E6# => return "100001111111111110000";
            when 16#E7# => return "100001111111111110001";
            when 16#E8# => return "100001111111111110010";
            when 16#E9# => return "100001111111111110011";
            when 16#EA# => return "100001111111111110100";
            when 16#F0# => return "010111111111100100000";
            when 16#F1# => return "100001111111111110101";
            when 16#F2# => return "100001111111111110110";
            when 16#F3# => return "100001111111111110111";
            when 16#F4# => return "100001111111111111000";
            when 16#F5# => return "100001111111111111001";
            when 16#F6# => return "100001111111111111010";
            when 16#F7# => return "100001111111111111011";
            when 16#F8# => return "100001111111111111100";
            when 16#F9# => return "100001111111111111101";
            when 16#FA# => return "100001111111111111110";
            when others => return "00000" & x"0000";
        end case;
    end function;

    function ac_chroma_lookup(sym : natural) return std_logic_vector is
    begin
        case sym is
            when 16#00# => return "000100000000000000000";
            when 16#01# => return "000100100000000000000";
            when 16#02# => return "000111000000000000000";
            when 16#03# => return "001001010000000000000";
            when 16#04# => return "001011100000000000000";
            when 16#05# => return "001011100100000000000";
            when 16#06# => return "001101110000000000000";
            when 16#07# => return "001111111000000000000";
            when 16#08# => return "010011111101000000000";
            when 16#09# => return "010101111110110000000";
            when 16#0A# => return "011001111111101000000";
            when 16#11# => return "001001011000000000000";
            when 16#12# => return "001101110010000000000";
            when 16#13# => return "010001111011000000000";
            when 16#14# => return "010011111101010000000";
            when 16#15# => return "010111111111011000000";
            when 16#16# => return "011001111111101010000";
            when 16#17# => return "100001111111110001000";
            when 16#18# => return "100001111111110001001";
            when 16#19# => return "100001111111110001010";
            when 16#1A# => return "100001111111110001011";
            when 16#21# => return "001011101000000000000";
            when 16#22# => return "010001111011100000000";
            when 16#23# => return "010101111110111000000";
            when 16#24# => return "011001111111101100000";
            when 16#25# => return "011111111111110000100";
            when 16#26# => return "100001111111110001100";
            when 16#27# => return "100001111111110001101";
            when 16#28# => return "100001111111110001110";
            when 16#29# => return "100001111111110001111";
            when 16#2A# => return "100001111111110010000";
            when 16#31# => return "001011101100000000000";
            when 16#32# => return "010001111100000000000";
            when 16#33# => return "010101111111000000000";
            when 16#34# => return "011001111111101110000";
            when 16#35# => return "100001111111110010001";
            when 16#36# => return "100001111111110010010";
            when 16#37# => return "100001111111110010011";
            when 16#38# => return "100001111111110010100";
            when 16#39# => return "100001111111110010101";
            when 16#3A# => return "100001111111110010110";
            when 16#41# => return "001101110100000000000";
            when 16#42# => return "010011111101100000000";
            when 16#43# => return "100001111111110010111";
            when 16#44# => return "100001111111110011000";
            when 16#45# => return "100001111111110011001";
            when 16#46# => return "100001111111110011010";
            when 16#47# => return "100001111111110011011";
            when 16#48# => return "100001111111110011100";
            when 16#49# => return "100001111111110011101";
            when 16#4A# => return "100001111111110011110";
            when 16#51# => return "001101110110000000000";
            when 16#52# => return "010101111111001000000";
            when 16#53# => return "100001111111110011111";
            when 16#54# => return "100001111111110100000";
            when 16#55# => return "100001111111110100001";
            when 16#56# => return "100001111111110100010";
            when 16#57# => return "100001111111110100011";
            when 16#58# => return "100001111111110100100";
            when 16#59# => return "100001111111110100101";
            when 16#5A# => return "100001111111110100110";
            when 16#61# => return "001111111001000000000";
            when 16#62# => return "010111111111011100000";
            when 16#63# => return "100001111111110100111";
            when 16#64# => return "100001111111110101000";
            when 16#65# => return "100001111111110101001";
            when 16#66# => return "100001111111110101010";
            when 16#67# => return "100001111111110101011";
            when 16#68# => return "100001111111110101100";
            when 16#69# => return "100001111111110101101";
            when 16#6A# => return "100001111111110101110";
            when 16#71# => return "001111111010000000000";
            when 16#72# => return "010111111111100000000";
            when 16#73# => return "100001111111110101111";
            when 16#74# => return "100001111111110110000";
            when 16#75# => return "100001111111110110001";
            when 16#76# => return "100001111111110110010";
            when 16#77# => return "100001111111110110011";
            when 16#78# => return "100001111111110110100";
            when 16#79# => return "100001111111110110101";
            when 16#7A# => return "100001111111110110110";
            when 16#81# => return "010001111100100000000";
            when 16#82# => return "100001111111110110111";
            when 16#83# => return "100001111111110111000";
            when 16#84# => return "100001111111110111001";
            when 16#85# => return "100001111111110111010";
            when 16#86# => return "100001111111110111011";
            when 16#87# => return "100001111111110111100";
            when 16#88# => return "100001111111110111101";
            when 16#89# => return "100001111111110111110";
            when 16#8A# => return "100001111111110111111";
            when 16#91# => return "010011111101110000000";
            when 16#92# => return "100001111111111000000";
            when 16#93# => return "100001111111111000001";
            when 16#94# => return "100001111111111000010";
            when 16#95# => return "100001111111111000011";
            when 16#96# => return "100001111111111000100";
            when 16#97# => return "100001111111111000101";
            when 16#98# => return "100001111111111000110";
            when 16#99# => return "100001111111111000111";
            when 16#9A# => return "100001111111111001000";
            when 16#A1# => return "010011111110000000000";
            when 16#A2# => return "100001111111111001001";
            when 16#A3# => return "100001111111111001010";
            when 16#A4# => return "100001111111111001011";
            when 16#A5# => return "100001111111111001100";
            when 16#A6# => return "100001111111111001101";
            when 16#A7# => return "100001111111111001110";
            when 16#A8# => return "100001111111111001111";
            when 16#A9# => return "100001111111111010000";
            when 16#AA# => return "100001111111111010001";
            when 16#B1# => return "010011111110010000000";
            when 16#B2# => return "100001111111111010010";
            when 16#B3# => return "100001111111111010011";
            when 16#B4# => return "100001111111111010100";
            when 16#B5# => return "100001111111111010101";
            when 16#B6# => return "100001111111111010110";
            when 16#B7# => return "100001111111111010111";
            when 16#B8# => return "100001111111111011000";
            when 16#B9# => return "100001111111111011001";
            when 16#BA# => return "100001111111111011010";
            when 16#C1# => return "010011111110100000000";
            when 16#C2# => return "100001111111111011011";
            when 16#C3# => return "100001111111111011100";
            when 16#C4# => return "100001111111111011101";
            when 16#C5# => return "100001111111111011110";
            when 16#C6# => return "100001111111111011111";
            when 16#C7# => return "100001111111111100000";
            when 16#C8# => return "100001111111111100001";
            when 16#C9# => return "100001111111111100010";
            when 16#CA# => return "100001111111111100011";
            when 16#D1# => return "010111111111100100000";
            when 16#D2# => return "100001111111111100100";
            when 16#D3# => return "100001111111111100101";
            when 16#D4# => return "100001111111111100110";
            when 16#D5# => return "100001111111111100111";
            when 16#D6# => return "100001111111111101000";
            when 16#D7# => return "100001111111111101001";
            when 16#D8# => return "100001111111111101010";
            when 16#D9# => return "100001111111111101011";
            when 16#DA# => return "100001111111111101100";
            when 16#E1# => return "011101111111110000000";
            when 16#E2# => return "100001111111111101101";
            when 16#E3# => return "100001111111111101110";
            when 16#E4# => return "100001111111111101111";
            when 16#E5# => return "100001111111111110000";
            when 16#E6# => return "100001111111111110001";
            when 16#E7# => return "100001111111111110010";
            when 16#E8# => return "100001111111111110011";
            when 16#E9# => return "100001111111111110100";
            when 16#EA# => return "100001111111111110101";
            when 16#F0# => return "010101111111010000000";
            when 16#F1# => return "011111111111110000110";
            when 16#F2# => return "100001111111111110110";
            when 16#F3# => return "100001111111111110111";
            when 16#F4# => return "100001111111111111000";
            when 16#F5# => return "100001111111111111001";
            when 16#F6# => return "100001111111111111010";
            when 16#F7# => return "100001111111111111011";
            when 16#F8# => return "100001111111111111100";
            when 16#F9# => return "100001111111111111101";
            when 16#FA# => return "100001111111111111110";
            when others => return "00000" & x"0000";
        end case;
    end function;

    function compute_category(abs_val : unsigned(10 downto 0)) return natural is
    begin
        for i in 10 downto 0 loop
            if abs_val(i) = '1' then
                return i + 1;
            end if;
        end loop;
        return 0;
    end function;

    function abs11(v : signed(15 downto 0)) return unsigned is
        variable lo : unsigned(10 downto 0);
    begin
        lo := unsigned(v(10 downto 0));
        if v(15) = '1' then
            return (to_unsigned(0, 11) - lo);
        end if;
        return lo;
    end function;

    function vbits_for(v : signed(15 downto 0); cat : natural) return unsigned is
        variable lo : unsigned(10 downto 0);
        variable addend : unsigned(10 downto 0);
    begin
        lo := unsigned(v(10 downto 0));
        if v(15) = '1' then
            addend := shift_left(to_unsigned(1, 11), cat) - 1;
            return lo + addend;
        end if;
        return lo;
    end function;

    function pack_bits(code : std_logic_vector(15 downto 0); len : unsigned(4 downto 0);
                       vbits : unsigned(10 downto 0); cat : unsigned(3 downto 0)) return std_logic_vector is
        variable base : unsigned(31 downto 0);
        variable val  : unsigned(31 downto 0);
        variable sh   : integer;
    begin
        base := unsigned(code & x"0000");
        sh := 32 - to_integer(len) - to_integer(cat);
        val := resize(vbits, 32) sll sh;
        return std_logic_vector(base or val);
    end function;

    type coeff_array_t is array (0 to 127) of signed(15 downto 0);
    signal coeff_buf : coeff_array_t := (others => (others => '0'));

    signal coeff_wr_idx : unsigned(5 downto 0) := (others => '0');
    signal coeff_block_ready : std_logic := '0';
    signal coeff_comp_id : std_logic_vector(1 downto 0) := (others => '0');
    signal last_nonzero_idx : unsigned(5 downto 0) := (others => '0');
    signal ready_comp_id : std_logic_vector(1 downto 0) := (others => '0');
    signal ready_last_nonzero : unsigned(5 downto 0) := (others => '0');
    signal coeff_wr_bank : std_logic := '0';
    signal ready_rd_bank : std_logic := '0';
    signal fsm_ack : std_logic := '0';

    type state_t is (S_IDLE, S_DC_FETCH, S_DC_ENCODE, S_DC_CALC, S_DC_EMIT,
                     S_AC_FETCH, S_AC_SCAN, S_AC_ENCODE, S_AC_EMIT,
                     S_ZRL_EMIT, S_EOB_EMIT);
    signal state : state_t := S_IDLE;
    signal ac_idx : unsigned(5 downto 0) := to_unsigned(1, 6);
    signal zero_run : unsigned(3 downto 0) := (others => '0');
    signal blk_comp_id : std_logic_vector(1 downto 0) := (others => '0');
    signal coeff_rd_bank : std_logic := '0';
    signal blk_last_nonzero : unsigned(5 downto 0) := (others => '0');
    signal prev_dc_y : signed(15 downto 0) := (others => '0');
    signal prev_dc_cb : signed(15 downto 0) := (others => '0');
    signal prev_dc_cr : signed(15 downto 0) := (others => '0');
    signal cur_coeff : signed(15 downto 0) := (others => '0');
    signal cur_abs : unsigned(10 downto 0) := (others => '0');
    signal cur_sign : std_logic := '0';
    signal cur_cat : unsigned(3 downto 0) := (others => '0');
    signal cur_vbits : unsigned(10 downto 0) := (others => '0');
    signal huff_code : std_logic_vector(15 downto 0) := (others => '0');
    signal huff_len : unsigned(4 downto 0) := (others => '0');
    signal restart_pending : std_logic := '0';
begin
    process (clk)
        variable wr_addr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                coeff_wr_idx <= (others => '0');
                coeff_wr_bank <= '0';
                coeff_block_ready <= '0';
                last_nonzero_idx <= (others => '0');
            else
                if fsm_ack = '1' then
                    coeff_block_ready <= '0';
                end if;

                if in_valid = '1' then
                    if in_sob = '1' then
                        if LITE_MODE /= 0 then
                            wr_addr := 0;
                        elsif coeff_wr_bank = '1' then
                            wr_addr := 64;
                        else
                            wr_addr := 0;
                        end if;
                        coeff_buf(wr_addr) <= signed(in_data);
                        coeff_wr_idx <= to_unsigned(1, 6);
                        coeff_comp_id <= comp_id;
                        last_nonzero_idx <= (others => '0');
                    else
                        if LITE_MODE /= 0 then
                            wr_addr := to_integer(coeff_wr_idx);
                        elsif coeff_wr_bank = '1' then
                            wr_addr := 64 + to_integer(coeff_wr_idx);
                        else
                            wr_addr := to_integer(coeff_wr_idx);
                        end if;
                        coeff_buf(wr_addr) <= signed(in_data);
                        if signed(in_data) /= 0 then
                            last_nonzero_idx <= coeff_wr_idx;
                        end if;
                        if coeff_wr_idx = 63 then
                            coeff_block_ready <= '1';
                            ready_comp_id <= coeff_comp_id;
                            if signed(in_data) /= 0 then
                                ready_last_nonzero <= to_unsigned(63, 6);
                            else
                                ready_last_nonzero <= last_nonzero_idx;
                            end if;
                            coeff_wr_idx <= (others => '0');
                            if LITE_MODE = 0 then
                                ready_rd_bank <= coeff_wr_bank;
                                coeff_wr_bank <= not coeff_wr_bank;
                            end if;
                        else
                            coeff_wr_idx <= coeff_wr_idx + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable rd_addr : natural;
        variable blk_is_luma : boolean;
        variable temp_cat : natural;
        variable dc_lookup : std_logic_vector(19 downto 0);
        variable ac_lookup : std_logic_vector(20 downto 0);
        variable ac_sym : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state <= S_IDLE;
                out_valid <= '0';
                out_sob <= '0';
                out_eob <= '0';
                out_bits <= (others => '0');
                out_len <= (others => '0');
                prev_dc_y <= (others => '0');
                prev_dc_cb <= (others => '0');
                prev_dc_cr <= (others => '0');
                ac_idx <= to_unsigned(1, 6);
                zero_run <= (others => '0');
                restart_pending <= '0';
                coeff_rd_bank <= '0';
                fsm_ack <= '0';
            else
                fsm_ack <= '0';
                if restart = '1' then
                    restart_pending <= '1';
                end if;

                blk_is_luma := unsigned(blk_comp_id) <= 1;

                case state is
                    when S_IDLE =>
                        out_valid <= '0';
                        out_sob <= '0';
                        out_eob <= '0';
                        if restart_pending = '1' then
                            prev_dc_y <= (others => '0');
                            prev_dc_cb <= (others => '0');
                            prev_dc_cr <= (others => '0');
                            restart_pending <= '0';
                        end if;
                        if coeff_block_ready = '1' then
                            fsm_ack <= '1';
                            blk_comp_id <= ready_comp_id;
                            blk_last_nonzero <= ready_last_nonzero;
                            if LITE_MODE = 0 then
                                coeff_rd_bank <= ready_rd_bank;
                            end if;
                            state <= S_DC_FETCH;
                        end if;

                    when S_DC_FETCH =>
                        out_valid <= '0';
                        if LITE_MODE /= 0 then rd_addr := 0; elsif coeff_rd_bank = '1' then rd_addr := 64; else rd_addr := 0; end if;
                        if unsigned(blk_comp_id) <= 1 then
                            cur_coeff <= coeff_buf(rd_addr) - prev_dc_y;
                            prev_dc_y <= coeff_buf(rd_addr);
                        elsif unsigned(blk_comp_id) = 2 then
                            cur_coeff <= coeff_buf(rd_addr) - prev_dc_cb;
                            prev_dc_cb <= coeff_buf(rd_addr);
                        else
                            cur_coeff <= coeff_buf(rd_addr) - prev_dc_cr;
                            prev_dc_cr <= coeff_buf(rd_addr);
                        end if;
                        state <= S_DC_ENCODE;

                    when S_DC_ENCODE =>
                        out_valid <= '0';
                        cur_sign <= cur_coeff(15);
                        cur_abs <= abs11(cur_coeff);
                        cur_cat <= to_unsigned(compute_category(abs11(cur_coeff)), 4);
                        state <= S_DC_CALC;

                    when S_DC_CALC =>
                        out_valid <= '0';
                        temp_cat := to_integer(cur_cat);
                        cur_vbits <= vbits_for(cur_coeff, temp_cat);
                        if blk_is_luma then dc_lookup := dc_luma_lookup(temp_cat); else dc_lookup := dc_chroma_lookup(temp_cat); end if;
                        huff_code <= dc_lookup(15 downto 0);
                        huff_len <= resize(unsigned(dc_lookup(19 downto 16)), 5);
                        state <= S_DC_EMIT;

                    when S_DC_EMIT =>
                        out_valid <= '1';
                        out_sob <= '1';
                        out_eob <= '0';
                        out_bits <= pack_bits(huff_code, huff_len, cur_vbits, cur_cat);
                        out_len <= std_logic_vector(resize(huff_len, 6) + resize(cur_cat, 6));
                        if out_ready = '1' and out_valid = '1' then
                            out_valid <= '0';
                            out_sob <= '0';
                            if blk_last_nonzero = 0 then
                                state <= S_EOB_EMIT;
                            else
                                ac_idx <= to_unsigned(1, 6);
                                zero_run <= (others => '0');
                                state <= S_AC_FETCH;
                            end if;
                        end if;

                    when S_AC_FETCH =>
                        out_valid <= '0';
                        out_sob <= '0';
                        out_eob <= '0';
                        if LITE_MODE /= 0 then rd_addr := to_integer(ac_idx); elsif coeff_rd_bank = '1' then rd_addr := 64 + to_integer(ac_idx); else rd_addr := to_integer(ac_idx); end if;
                        cur_coeff <= coeff_buf(rd_addr);
                        state <= S_AC_SCAN;

                    when S_AC_SCAN =>
                        out_valid <= '0';
                        if cur_coeff = 0 then
                            if ac_idx > blk_last_nonzero then
                                state <= S_EOB_EMIT;
                            elsif zero_run = 15 then
                                state <= S_ZRL_EMIT;
                            else
                                zero_run <= zero_run + 1;
                                ac_idx <= ac_idx + 1;
                                state <= S_AC_FETCH;
                            end if;
                        else
                            cur_sign <= cur_coeff(15);
                            cur_abs <= abs11(cur_coeff);
                            state <= S_AC_ENCODE;
                        end if;

                    when S_AC_ENCODE =>
                        out_valid <= '0';
                        temp_cat := compute_category(cur_abs);
                        cur_cat <= to_unsigned(temp_cat, 4);
                        cur_vbits <= vbits_for(cur_coeff, temp_cat);
                        ac_sym := to_integer(zero_run) * 16 + temp_cat;
                        if blk_is_luma then ac_lookup := ac_luma_lookup(ac_sym); else ac_lookup := ac_chroma_lookup(ac_sym); end if;
                        huff_code <= ac_lookup(15 downto 0);
                        huff_len <= unsigned(ac_lookup(20 downto 16));
                        state <= S_AC_EMIT;

                    when S_AC_EMIT =>
                        out_valid <= '1';
                        out_sob <= '0';
                        if ac_idx = 63 then out_eob <= '1'; else out_eob <= '0'; end if;
                        out_bits <= pack_bits(huff_code, huff_len, cur_vbits, cur_cat);
                        out_len <= std_logic_vector(resize(huff_len, 6) + resize(cur_cat, 6));
                        if out_ready = '1' and out_valid = '1' then
                            out_valid <= '0';
                            zero_run <= (others => '0');
                            if ac_idx = 63 then
                                state <= S_IDLE;
                            else
                                ac_idx <= ac_idx + 1;
                                state <= S_AC_FETCH;
                            end if;
                        end if;

                    when S_ZRL_EMIT =>
                        out_valid <= '1';
                        out_sob <= '0';
                        out_eob <= '0';
                        if blk_is_luma then ac_lookup := ac_luma_lookup(16#F0#); else ac_lookup := ac_chroma_lookup(16#F0#); end if;
                        out_bits <= ac_lookup(15 downto 0) & x"0000";
                        out_len <= std_logic_vector(resize(unsigned(ac_lookup(20 downto 16)), 6));
                        if out_ready = '1' and out_valid = '1' then
                            out_valid <= '0';
                            zero_run <= (others => '0');
                            ac_idx <= ac_idx + 1;
                            state <= S_AC_FETCH;
                        end if;

                    when S_EOB_EMIT =>
                        out_valid <= '1';
                        out_sob <= '0';
                        out_eob <= '1';
                        if blk_is_luma then ac_lookup := ac_luma_lookup(16#00#); else ac_lookup := ac_chroma_lookup(16#00#); end if;
                        out_bits <= ac_lookup(15 downto 0) & x"0000";
                        out_len <= std_logic_vector(resize(unsigned(ac_lookup(20 downto 16)), 6));
                        if out_ready = '1' and out_valid = '1' then
                            out_valid <= '0';
                            out_eob <= '0';
                            state <= S_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
