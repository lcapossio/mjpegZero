-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity huffman_encoder is
    generic (
        HUFF_BANKS : natural := 4
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
    function bank_width(n : natural) return natural is
    begin
        if n <= 2 then
            return 1;
        elsif n <= 4 then
            return 2;
        else
            return 3;
        end if;
    end function;

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

    -- Binary index of a one-hot vector (an OR tree, no priority chain).
    function onehot_idx(oh : std_logic_vector(63 downto 0)) return unsigned is
        variable idx : unsigned(5 downto 0);
    begin
        idx := (others => '0');
        for i in 0 to 63 loop
            if oh(i) = '1' then
                idx := idx or to_unsigned(i, 6);
            end if;
        end loop;
        return idx;
    end function;

    -- Inclusive prefix OR (bit i = or of x(i downto 0)) as a log-depth
    -- shift-OR network, so the lowest-set-bit logic stays off the carry chain.
    function prefix_or(x : std_logic_vector(63 downto 0)) return std_logic_vector is
        variable p : unsigned(63 downto 0);
    begin
        p := unsigned(x);
        p := p or shift_left(p, 1);
        p := p or shift_left(p, 2);
        p := p or shift_left(p, 4);
        p := p or shift_left(p, 8);
        p := p or shift_left(p, 16);
        p := p or shift_left(p, 32);
        return std_logic_vector(p);
    end function;

    constant NB : natural := HUFF_BANKS;
    constant BW : natural := bank_width(NB);

    type coeff_array_t is array (0 to NB * 64 - 1) of signed(15 downto 0);
    signal coeff_buf : coeff_array_t := (others => (others => '0'));

    signal coeff_wr_idx : unsigned(5 downto 0) := (others => '0');
    signal coeff_comp_id : std_logic_vector(1 downto 0) := (others => '0');
    -- Nonzero map of the block being written (bit i = coeff i /= 0; bit 0 unused).
    signal nz_acc : std_logic_vector(63 downto 0) := (others => '0');
    -- Any nonzero AC so far in that block.
    signal nz_any : std_logic := '0';
    signal wr_count : unsigned(BW downto 0) := (others => '0');
    signal rd_count : unsigned(BW downto 0) := (others => '0');
    signal occ : unsigned(BW downto 0);

    type bank_comp_t is array (0 to NB - 1) of std_logic_vector(1 downto 0);
    type bank_nz_t is array (0 to NB - 1) of std_logic_vector(63 downto 0);
    signal bank_comp : bank_comp_t := (others => (others => '0'));
    signal bank_nz : bank_nz_t := (others => (others => '0'));
    -- Per-bank or-reduce of bank_nz, kept off the read-side path.
    signal bank_any : std_logic_vector(NB - 1 downto 0) := (others => '0');

    -- Code pipeline: one Huffman code per cycle. A controller walks the block's
    -- nonzero map and issues one token per cycle (DC, each nonzero AC, EOB) into
    -- a 5-stage pipeline; zero coefficients cost nothing. Stage 2 splits runs of
    -- >15 zeros into ZRL codes, stalling the controller one cycle per ZRL. The
    -- whole pipeline advances together whenever the output register is free.
    --
    --   issue -> S2 fetch/DC diff/run -> S3 abs+category -> S4 table lookup
    --         -> out register (code+value bits combined)
    --
    -- Blocks never overlap: the next block is issued only from C_IDLE, entered
    -- the cycle after the block's EOB-flagged code is accepted. That keeps the
    -- top's restart/frame_done (registered off that handshake) in step: the DC
    -- predictors reset in C_IDLE before the next DC reaches S2, and the next
    -- code reaches the packer >= 2 cycles after the EOB, after it saw in_restart.
    type ctl_t is (C_IDLE, C_AC, C_EOB, C_WAIT);
    signal ctl : ctl_t := C_IDLE;

    constant K_DC  : unsigned(1 downto 0) := "00";
    constant K_AC  : unsigned(1 downto 0) := "01";
    constant K_ZRL : unsigned(1 downto 0) := "10";
    constant K_EOB : unsigned(1 downto 0) := "11";

    signal rem_nz : std_logic_vector(63 downto 0) := (others => '0');  -- nonzero ACs not yet issued
    signal blk_comp_id : std_logic_vector(1 downto 0) := (others => '0');
    signal coeff_rd_bank : unsigned(BW - 1 downto 0) := (others => '0');
    signal restart_pending : std_logic := '0';
    signal prev_dc_y : signed(15 downto 0) := (others => '0');
    signal prev_dc_cb : signed(15 downto 0) := (others => '0');
    signal prev_dc_cr : signed(15 downto 0) := (others => '0');

    -- S2: token as issued
    signal s2_valid : std_logic := '0';
    signal s2_kind : unsigned(1 downto 0) := K_DC;
    signal s2_pos : unsigned(5 downto 0) := (others => '0');  -- coefficient index (0 for DC)
    signal s2_eob : std_logic := '0';
    signal last_pos : unsigned(5 downto 0) := (others => '0');  -- previous coded coefficient
    -- S3: value + run
    signal s3_valid : std_logic := '0';
    signal s3_kind : unsigned(1 downto 0) := K_DC;
    signal s3_eob : std_logic := '0';
    signal s3_val : signed(15 downto 0) := (others => '0');
    signal s3_run : unsigned(3 downto 0) := (others => '0');
    -- S4: sign/abs/category
    signal s4_valid : std_logic := '0';
    signal s4_kind : unsigned(1 downto 0) := K_DC;
    signal s4_eob : std_logic := '0';
    signal s4_raw : unsigned(10 downto 0) := (others => '0');
    signal s4_sign : std_logic := '0';
    signal s4_cat : unsigned(3 downto 0) := (others => '0');
    signal s4_run : unsigned(3 downto 0) := (others => '0');
    -- S5: code + value bits, ready to combine
    signal s5_valid : std_logic := '0';
    signal s5_dc : std_logic := '0';
    signal s5_eob : std_logic := '0';
    signal s5_code : std_logic_vector(15 downto 0) := (others => '0');
    signal s5_len : unsigned(4 downto 0) := (others => '0');
    signal s5_cat : unsigned(3 downto 0) := (others => '0');
    signal s5_vbits : unsigned(10 downto 0) := (others => '0');

    signal out_valid_i : std_logic := '0';
    signal out_eob_i : std_logic := '0';
    signal adv : std_logic;
    signal s2_run : unsigned(5 downto 0);
    signal zrl_emit : std_logic;
    signal issue_en : std_logic;
    signal rem_pos : unsigned(5 downto 0);
    signal rem_clr : std_logic_vector(63 downto 0);
    signal rem_below : std_logic_vector(63 downto 0);
    signal s2_coeff : signed(15 downto 0);
begin
    out_valid <= out_valid_i;
    out_eob <= out_eob_i;
    occ <= wr_count - rd_count;

    assert NB = 2 or NB = 4 or NB = 8
        report "HUFF_BANKS must be 2, 4, or 8" severity failure;

    adv <= (not out_valid_i) or out_ready;
    -- S2 run of zeros before this AC; > 15 needs a ZRL first.
    s2_run <= s2_pos - last_pos - 1;
    zrl_emit <= '1' when s2_valid = '1' and s2_kind = K_AC and s2_run(5 downto 4) /= "00" else '0';
    issue_en <= adv and not zrl_emit;
    -- rem_below(i) = any set bit below i. The lowest set bit is the one with
    -- none below it; clearing it keeps the rest (== x and (x-1), no carry chain).
    rem_below <= std_logic_vector(shift_left(unsigned(prefix_or(rem_nz)), 1));
    rem_pos <= onehot_idx(rem_nz and not rem_below);
    rem_clr <= rem_nz and rem_below;
    s2_coeff <= coeff_buf(to_integer(coeff_rd_bank) * 64 + to_integer(s2_pos));

    process (clk)
        variable wr_addr : natural;
        variable wr_bank : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                coeff_wr_idx <= (others => '0');
                nz_acc <= (others => '0');
                nz_any <= '0';
                wr_count <= (others => '0');
            else
                if in_valid = '1' then
                    wr_bank := to_integer(wr_count(BW - 1 downto 0));
                    if in_sob = '1' then
                        wr_addr := wr_bank * 64;
                        coeff_buf(wr_addr) <= signed(in_data);
                        coeff_wr_idx <= to_unsigned(1, 6);
                        coeff_comp_id <= comp_id;
                        nz_acc <= (others => '0');
                        nz_any <= '0';
                    else
                        wr_addr := wr_bank * 64 + to_integer(coeff_wr_idx);
                        coeff_buf(wr_addr) <= signed(in_data);
                        if signed(in_data) /= 0 then
                            nz_acc(to_integer(coeff_wr_idx)) <= '1';
                            nz_any <= '1';
                        else
                            nz_acc(to_integer(coeff_wr_idx)) <= '0';
                        end if;
                        if coeff_wr_idx = 63 then
                            bank_comp(wr_bank) <= coeff_comp_id;
                            if signed(in_data) /= 0 then
                                bank_nz(wr_bank) <= '1' & nz_acc(62 downto 1) & '0';
                                bank_any(wr_bank) <= '1';
                            else
                                bank_nz(wr_bank) <= '0' & nz_acc(62 downto 1) & '0';
                                bank_any(wr_bank) <= nz_any;
                            end if;
                            coeff_wr_idx <= (others => '0');
                            wr_count <= wr_count + 1;
                        else
                            coeff_wr_idx <= coeff_wr_idx + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable rd_bank : natural;
        variable blk_is_luma : boolean;
        variable dc_lookup : std_logic_vector(19 downto 0);
        variable ac_lookup : std_logic_vector(20 downto 0);
        variable ac_sym : natural;
        variable prev_dc : signed(15 downto 0);
        variable abs_v : unsigned(10 downto 0);
        variable cat : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ctl <= C_IDLE;
                rem_nz <= (others => '0');
                restart_pending <= '0';
                coeff_rd_bank <= (others => '0');
                rd_count <= (others => '0');
                prev_dc_y <= (others => '0');
                prev_dc_cb <= (others => '0');
                prev_dc_cr <= (others => '0');
                last_pos <= (others => '0');
                s2_valid <= '0';
                s3_valid <= '0';
                s4_valid <= '0';
                s5_valid <= '0';
                out_valid_i <= '0';
                out_sob <= '0';
                out_eob_i <= '0';
                out_bits <= (others => '0');
                out_len <= (others => '0');
            else
                if restart = '1' then
                    restart_pending <= '1';
                end if;

                blk_is_luma := unsigned(blk_comp_id) <= 1;

                -- ---------------- Controller / issue ----------------
                case ctl is
                    when C_IDLE =>
                        -- Apply pending restart. Also honor a LIVE restart this
                        -- cycle: a mid-frame restart_trigger lands exactly as the
                        -- controller enters C_IDLE (both registered off the same
                        -- EOB handshake), so waiting for the latched
                        -- restart_pending (set next cycle) would miss it and code
                        -- the next MCU's DC against the stale predictor - a desync
                        -- vs the decoder, which resets DC at the RSTn marker.
                        if restart_pending = '1' or restart = '1' then
                            prev_dc_y <= (others => '0');
                            prev_dc_cb <= (others => '0');
                            prev_dc_cr <= (others => '0');
                            restart_pending <= '0';
                        end if;
                        if issue_en = '1' then
                            s2_valid <= '0';
                            if occ /= 0 then
                                rd_bank := to_integer(rd_count(BW - 1 downto 0));
                                blk_comp_id <= bank_comp(rd_bank);
                                coeff_rd_bank <= rd_count(BW - 1 downto 0);
                                rem_nz <= bank_nz(rd_bank);
                                s2_valid <= '1';
                                s2_kind <= K_DC;
                                s2_pos <= (others => '0');
                                s2_eob <= '0';
                                if bank_any(rd_bank) = '1' then
                                    ctl <= C_AC;
                                else
                                    ctl <= C_EOB;
                                end if;
                            end if;
                        end if;

                    when C_AC =>
                        if issue_en = '1' then
                            s2_valid <= '1';
                            s2_kind <= K_AC;
                            s2_pos <= rem_pos;
                            if unsigned(rem_clr) = 0 and rem_pos = 63 then
                                s2_eob <= '1';
                            else
                                s2_eob <= '0';
                            end if;
                            rem_nz <= rem_clr;
                            if unsigned(rem_clr) = 0 then
                                if rem_pos = 63 then
                                    ctl <= C_WAIT;
                                else
                                    ctl <= C_EOB;
                                end if;
                            end if;
                        end if;

                    when C_EOB =>
                        if issue_en = '1' then
                            s2_valid <= '1';
                            s2_kind <= K_EOB;
                            s2_eob <= '1';
                            ctl <= C_WAIT;
                        end if;

                    when C_WAIT =>
                        if issue_en = '1' then
                            s2_valid <= '0';
                        end if;
                        if out_valid_i = '1' and out_ready = '1' and out_eob_i = '1' then
                            rd_count <= rd_count + 1;  -- pop completed block
                            ctl <= C_IDLE;
                        end if;
                end case;

                if adv = '1' then
                    -- ---------------- S2: fetch / DC diff / zero run ----------------
                    s3_valid <= s2_valid;
                    s3_eob <= s2_eob and not zrl_emit;
                    if zrl_emit = '1' then
                        s3_kind <= K_ZRL;
                        s3_run <= to_unsigned(15, 4);
                        s3_val <= (others => '0');
                        last_pos <= last_pos + 16;
                    else
                        s3_kind <= s2_kind;
                        s3_run <= s2_run(3 downto 0);
                        if s2_kind = K_DC then
                            if unsigned(blk_comp_id) <= 1 then
                                prev_dc := prev_dc_y;
                            elsif unsigned(blk_comp_id) = 2 then
                                prev_dc := prev_dc_cb;
                            else
                                prev_dc := prev_dc_cr;
                            end if;
                            s3_val <= s2_coeff - prev_dc;
                            last_pos <= (others => '0');
                            if s2_valid = '1' then
                                if unsigned(blk_comp_id) <= 1 then
                                    prev_dc_y <= s2_coeff;
                                elsif unsigned(blk_comp_id) = 2 then
                                    prev_dc_cb <= s2_coeff;
                                else
                                    prev_dc_cr <= s2_coeff;
                                end if;
                            end if;
                        else
                            s3_val <= s2_coeff;
                            if s2_valid = '1' then
                                last_pos <= s2_pos;
                            end if;
                        end if;
                    end if;

                    -- ---------------- S3: sign / abs / category ----------------
                    s4_valid <= s3_valid;
                    s4_kind <= s3_kind;
                    s4_eob <= s3_eob;
                    s4_run <= s3_run;
                    -- ZRL/EOB carry no value bits: zero them so none leak into the code.
                    if s3_kind = K_DC or s3_kind = K_AC then
                        abs_v := abs11(s3_val);
                        s4_raw <= unsigned(s3_val(10 downto 0));
                        s4_sign <= s3_val(15);
                        s4_cat <= to_unsigned(compute_category(abs_v), 4);
                    else
                        s4_raw <= (others => '0');
                        s4_sign <= '0';
                        s4_cat <= (others => '0');
                    end if;

                    -- ---------------- S4: value bits + table lookup ----------------
                    s5_valid <= s4_valid;
                    if s4_kind = K_DC then s5_dc <= '1'; else s5_dc <= '0'; end if;
                    s5_eob <= s4_eob;
                    s5_cat <= s4_cat;
                    cat := to_integer(s4_cat);
                    if s4_sign = '1' then
                        s5_vbits <= s4_raw + (shift_left(to_unsigned(1, 11), cat) - 1);
                    else
                        s5_vbits <= s4_raw;
                    end if;
                    if s4_kind = K_DC then
                        if blk_is_luma then dc_lookup := dc_luma_lookup(cat); else dc_lookup := dc_chroma_lookup(cat); end if;
                        s5_code <= dc_lookup(15 downto 0);
                        s5_len <= resize(unsigned(dc_lookup(19 downto 16)), 5);
                    else
                        if s4_kind = K_AC then
                            ac_sym := to_integer(s4_run) * 16 + cat;
                        elsif s4_kind = K_ZRL then
                            ac_sym := 16#F0#;
                        else
                            ac_sym := 16#00#;
                        end if;
                        if blk_is_luma then ac_lookup := ac_luma_lookup(ac_sym); else ac_lookup := ac_chroma_lookup(ac_sym); end if;
                        s5_code <= ac_lookup(15 downto 0);
                        s5_len <= unsigned(ac_lookup(20 downto 16));
                    end if;

                    -- ---------------- S5: combine into the output register ----------------
                    -- Huffman code MSB-aligned, value bits immediately after it.
                    out_valid_i <= s5_valid;
                    out_sob <= s5_valid and s5_dc;
                    out_eob_i <= s5_valid and s5_eob;
                    out_bits <= pack_bits(s5_code, s5_len, s5_vbits, s5_cat);
                    out_len <= std_logic_vector(resize(s5_len, 6) + resize(s5_cat, 6));
                end if;
            end if;
        end if;
    end process;
end architecture;
