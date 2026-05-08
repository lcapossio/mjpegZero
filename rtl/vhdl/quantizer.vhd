-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity quantizer is
    generic (
        LITE_MODE    : natural := 0;
        LITE_QUALITY : natural := 95
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;

        comp_id  : in  std_logic_vector(1 downto 0);
        quality  : in  std_logic_vector(6 downto 0);

        in_valid : in  std_logic;
        in_data  : in  std_logic_vector(15 downto 0);
        in_sof   : in  std_logic;
        in_sob   : in  std_logic;

        out_valid : out std_logic;
        out_data  : out std_logic_vector(15 downto 0);
        out_sof   : out std_logic;
        out_sob   : out std_logic;

        qt_rd_addr      : in  std_logic_vector(5 downto 0);
        qt_rd_is_chroma : in  std_logic;
        qt_rd_data      : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of quantizer is
    type nat_array64 is array (0 to 63) of natural;
    type u8_array64 is array (0 to 63) of unsigned(7 downto 0);
    type u16_array64 is array (0 to 63) of unsigned(15 downto 0);
    type u16_array256 is array (0 to 255) of unsigned(15 downto 0);

    constant BASE_LUMA : nat_array64 := (
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    );

    constant BASE_CHROMA : nat_array64 := (
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99
    );

    function recip_for(q : natural) return unsigned is
        variable recip : natural;
    begin
        if q <= 1 then
            recip := 65535;
        else
            recip := (65536 + (q / 2)) / q;
            if recip > 65535 then
                recip := 65535;
            end if;
        end if;
        return to_unsigned(recip, 16);
    end function;

    function recip_lut_init return u16_array256 is
        variable r : u16_array256 := (others => to_unsigned(65535, 16));
    begin
        for i in 1 to 255 loop
            r(i) := recip_for(i);
        end loop;
        return r;
    end function;

    function scale_full(q : natural) return natural is
    begin
        if q >= 50 then
            return 200 - 2 * q;
        elsif q >= 1 then
            case q is
                when 1 => return 5000; when 2 => return 2500; when 3 => return 1667;
                when 4 => return 1250; when 5 => return 1000; when 6 => return 833;
                when 7 => return 714;  when 8 => return 625;  when 9 => return 556;
                when 10 => return 500; when 11 => return 455; when 12 => return 417;
                when 13 => return 385; when 14 => return 357; when 15 => return 333;
                when 16 => return 313; when 17 => return 294; when 18 => return 278;
                when 19 => return 263; when 20 => return 250; when 21 => return 238;
                when 22 => return 227; when 23 => return 217; when 24 => return 208;
                when 25 => return 200; when 26 => return 192; when 27 => return 185;
                when 28 => return 179; when 29 => return 172; when 30 => return 167;
                when 31 => return 161; when 32 => return 156; when 33 => return 152;
                when 34 => return 147; when 35 => return 143; when 36 => return 139;
                when 37 => return 135; when 38 => return 132; when 39 => return 128;
                when 40 => return 125; when 41 => return 122; when 42 => return 119;
                when 43 => return 116; when 44 => return 114; when 45 => return 111;
                when 46 => return 109; when 47 => return 106; when 48 => return 104;
                when 49 => return 102; when others => return 100;
            end case;
        else
            return 5000;
        end if;
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

    function clamp_q(v : natural) return natural is
    begin
        if v < 1 then
            return 1;
        elsif v > 255 then
            return 255;
        else
            return v;
        end if;
    end function;

    function qtable_init(base : nat_array64; lite_mode_g : natural; quality_g : natural) return u8_array64 is
        variable r : u8_array64 := (others => to_unsigned(1, 8));
        variable scale : natural;
        variable q : natural;
    begin
        if lite_mode_g /= 0 then
            scale := scale_lite(quality_g);
            for i in 0 to 63 loop
                q := clamp_q((base(i) * scale + 50) / 100);
                r(i) := to_unsigned(q, 8);
            end loop;
        end if;
        return r;
    end function;

    function recip_init(base : nat_array64; lite_mode_g : natural; quality_g : natural) return u16_array64 is
        variable r : u16_array64 := (others => to_unsigned(65535, 16));
        variable scale : natural;
        variable q : natural;
    begin
        if lite_mode_g /= 0 then
            scale := scale_lite(quality_g);
            for i in 0 to 63 loop
                q := clamp_q((base(i) * scale + 50) / 100);
                r(i) := recip_for(q);
            end loop;
        end if;
        return r;
    end function;

    type upd_state_t is (UPD_IDLE, UPD_SCALE, UPD_ADD, UPD_DIV, UPD_RECIP);

    signal recip_luma    : u16_array64 := recip_init(BASE_LUMA, LITE_MODE, LITE_QUALITY);
    signal recip_chroma  : u16_array64 := recip_init(BASE_CHROMA, LITE_MODE, LITE_QUALITY);
    signal qtable_luma   : u8_array64 := qtable_init(BASE_LUMA, LITE_MODE, LITE_QUALITY);
    signal qtable_chroma : u8_array64 := qtable_init(BASE_CHROMA, LITE_MODE, LITE_QUALITY);
    constant RECIP_LUT   : u16_array256 := recip_lut_init;

    attribute ram_style : string;
    attribute ram_style of recip_luma : signal is "distributed";
    attribute ram_style of recip_chroma : signal is "distributed";
    attribute ram_style of qtable_luma : signal is "distributed";
    attribute ram_style of qtable_chroma : signal is "distributed";

    signal upd_state     : upd_state_t := UPD_IDLE;
    signal upd_is_chroma : std_logic := '0';
    signal upd_pos       : unsigned(5 downto 0) := (others => '0');
    signal last_quality  : unsigned(6 downto 0) := (others => '0');
    signal scale_factor  : unsigned(12 downto 0) := (others => '0');
    signal scaled_raw    : unsigned(20 downto 0) := (others => '0');
    signal scaled_plus50 : unsigned(20 downto 0) := (others => '0');
    signal div100_product : unsigned(31 downto 0) := (others => '0');

    signal coeff_idx : unsigned(5 downto 0) := (others => '0');
    signal latched_is_chroma : std_logic := '0';

    signal p1_valid : std_logic := '0';
    signal p1_data  : signed(15 downto 0) := (others => '0');
    signal p1_recip : unsigned(15 downto 0) := (others => '0');
    signal p1_sof   : std_logic := '0';
    signal p1_sob   : std_logic := '0';

    signal p2_valid    : std_logic := '0';
    signal p2_abs_data : unsigned(15 downto 0) := (others => '0');
    signal p2_sign     : std_logic := '0';
    signal p2_recip    : unsigned(15 downto 0) := (others => '0');
    signal p2_sof      : std_logic := '0';
    signal p2_sob      : std_logic := '0';

    signal p3_valid   : std_logic := '0';
    signal p3_product : unsigned(31 downto 0) := (others => '0');
    signal p3_sof     : std_logic := '0';
    signal p3_sob     : std_logic := '0';
    signal p3_sign    : std_logic := '0';
begin
    process (clk)
        variable div_result : natural;
        variable pos : natural;
        variable base_q : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if LITE_MODE = 0 then
                if rst_n = '0' then
                    upd_state <= UPD_IDLE;
                    last_quality <= (others => '0');
                    upd_is_chroma <= '0';
                    upd_pos <= (others => '0');
                else
                    pos := to_integer(upd_pos);
                    if div100_product(31 downto 17) > to_unsigned(255, 15) then
                        div_result := 255;
                    elsif div100_product(31 downto 17) < to_unsigned(1, 15) then
                        div_result := 1;
                    else
                        div_result := to_integer(div100_product(24 downto 17));
                    end if;

                    case upd_state is
                        when UPD_IDLE =>
                            if unsigned(quality) /= last_quality then
                                last_quality <= unsigned(quality);
                                scale_factor <= to_unsigned(scale_full(to_integer(unsigned(quality))), 13);
                                upd_is_chroma <= '0';
                                upd_pos <= (others => '0');
                                upd_state <= UPD_SCALE;
                            end if;

                        when UPD_SCALE =>
                            if upd_is_chroma = '1' then
                                base_q := to_unsigned(BASE_CHROMA(pos), 8);
                            else
                                base_q := to_unsigned(BASE_LUMA(pos), 8);
                            end if;
                            scaled_raw <= resize(base_q * scale_factor, scaled_raw'length);
                            upd_state <= UPD_ADD;

                        when UPD_ADD =>
                            scaled_plus50 <= scaled_raw + to_unsigned(50, scaled_plus50'length);
                            upd_state <= UPD_DIV;

                        when UPD_DIV =>
                            div100_product <= resize(scaled_plus50 * to_unsigned(1311, 11), div100_product'length);
                            upd_state <= UPD_RECIP;

                        when UPD_RECIP =>
                            if upd_is_chroma = '1' then
                                qtable_chroma(pos) <= to_unsigned(div_result, 8);
                                recip_chroma(pos) <= RECIP_LUT(div_result);
                            else
                                qtable_luma(pos) <= to_unsigned(div_result, 8);
                                recip_luma(pos) <= RECIP_LUT(div_result);
                            end if;

                            if upd_pos = 63 then
                                upd_pos <= (others => '0');
                                if upd_is_chroma = '1' then
                                    upd_state <= UPD_IDLE;
                                else
                                    upd_is_chroma <= '1';
                                    upd_state <= UPD_SCALE;
                                end if;
                            else
                                upd_pos <= upd_pos + 1;
                                upd_state <= UPD_SCALE;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if qt_rd_is_chroma = '1' then
                qt_rd_data <= std_logic_vector(qtable_chroma(to_integer(unsigned(qt_rd_addr))));
            else
                qt_rd_data <= std_logic_vector(qtable_luma(to_integer(unsigned(qt_rd_addr))));
            end if;
        end if;
    end process;

    process (clk)
        variable lookup_idx : natural;
        variable use_chroma : std_logic;
        variable abs_data : signed(15 downto 0);
        variable rounded_product : unsigned(31 downto 0);
        variable rounded_result : unsigned(15 downto 0);
        variable signed_result : signed(16 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                coeff_idx <= (others => '0');
                latched_is_chroma <= '0';
                p1_valid <= '0';
                p1_sof <= '0';
                p1_sob <= '0';
                p2_valid <= '0';
                p2_sof <= '0';
                p2_sob <= '0';
                p3_valid <= '0';
                p3_sof <= '0';
                p3_sob <= '0';
                out_valid <= '0';
                out_sof <= '0';
                out_sob <= '0';
                out_data <= (others => '0');
            else
                if in_valid = '1' then
                    if in_sob = '1' then
                        coeff_idx <= to_unsigned(1, 6);
                    else
                        coeff_idx <= coeff_idx + 1;
                    end if;
                end if;

                if in_valid = '1' and in_sob = '1' then
                    if unsigned(comp_id) >= 2 then
                        latched_is_chroma <= '1';
                    else
                        latched_is_chroma <= '0';
                    end if;
                end if;

                if in_sob = '1' then
                    lookup_idx := 0;
                else
                    lookup_idx := to_integer(coeff_idx);
                end if;

                if in_valid = '1' and in_sob = '1' then
                    if unsigned(comp_id) >= 2 then
                        use_chroma := '1';
                    else
                        use_chroma := '0';
                    end if;
                else
                    use_chroma := latched_is_chroma;
                end if;

                p1_valid <= in_valid;
                p1_data <= signed(in_data);
                p1_sof <= in_sof;
                p1_sob <= in_sob;
                if use_chroma = '1' then
                    p1_recip <= recip_chroma(lookup_idx);
                else
                    p1_recip <= recip_luma(lookup_idx);
                end if;

                p2_valid <= p1_valid;
                p2_sof <= p1_sof;
                p2_sob <= p1_sob;
                p2_sign <= p1_data(15);
                if p1_data(15) = '1' then
                    abs_data := -p1_data;
                else
                    abs_data := p1_data;
                end if;
                p2_abs_data <= unsigned(abs_data);
                p2_recip <= p1_recip;

                p3_valid <= p2_valid;
                p3_sof <= p2_sof;
                p3_sob <= p2_sob;
                p3_sign <= p2_sign;
                p3_product <= p2_abs_data * p2_recip;

                out_valid <= p3_valid;
                out_sof <= p3_sof;
                out_sob <= p3_sob;
                if p3_valid = '1' then
                    rounded_product := p3_product + 32768;
                    rounded_result := rounded_product(31 downto 16);
                    signed_result := signed('0' & rounded_result);
                    if p3_sign = '1' then
                        signed_result := -signed_result;
                    end if;
                    out_data <= std_logic_vector(signed_result(15 downto 0));
                end if;
            end if;
        end if;
    end process;
end architecture;
