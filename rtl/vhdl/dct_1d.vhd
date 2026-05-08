-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dct_1d is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        in_valid  : in  std_logic;
        in_data   : in  std_logic_vector(11 downto 0);
        in_last   : in  std_logic;

        out_valid : out std_logic;
        out_data  : out std_logic_vector(15 downto 0);
        out_last  : out std_logic
    );
end entity dct_1d;

architecture rtl of dct_1d is

    type sample_array_t is array (0 to 7) of signed(11 downto 0);
    type coeff_array_t is array (0 to 63) of signed(12 downto 0);
    type prod_array_t is array (0 to 7) of signed(24 downto 0);

    constant COS_ROM : coeff_array_t := (
         0 => to_signed(1448, 13),  1 => to_signed(1448, 13),  2 => to_signed(1448, 13),  3 => to_signed(1448, 13),
         4 => to_signed(1448, 13),  5 => to_signed(1448, 13),  6 => to_signed(1448, 13),  7 => to_signed(1448, 13),
         8 => to_signed(2009, 13),  9 => to_signed(1703, 13), 10 => to_signed(1138, 13), 11 => to_signed(400, 13),
        12 => to_signed(-400, 13), 13 => to_signed(-1138, 13),14 => to_signed(-1703, 13),15 => to_signed(-2009, 13),
        16 => to_signed(1892, 13), 17 => to_signed(784, 13),  18 => to_signed(-784, 13), 19 => to_signed(-1892, 13),
        20 => to_signed(-1892, 13),21 => to_signed(-784, 13), 22 => to_signed(784, 13),  23 => to_signed(1892, 13),
        24 => to_signed(1703, 13), 25 => to_signed(-400, 13), 26 => to_signed(-2009, 13),27 => to_signed(-1138, 13),
        28 => to_signed(1138, 13), 29 => to_signed(2009, 13), 30 => to_signed(400, 13),  31 => to_signed(-1703, 13),
        32 => to_signed(1448, 13), 33 => to_signed(-1448, 13),34 => to_signed(-1448, 13),35 => to_signed(1448, 13),
        36 => to_signed(1448, 13), 37 => to_signed(-1448, 13),38 => to_signed(-1448, 13),39 => to_signed(1448, 13),
        40 => to_signed(1138, 13), 41 => to_signed(-2009, 13),42 => to_signed(400, 13),  43 => to_signed(1703, 13),
        44 => to_signed(-1703, 13),45 => to_signed(-400, 13), 46 => to_signed(2009, 13), 47 => to_signed(-1138, 13),
        48 => to_signed(784, 13),  49 => to_signed(-1892, 13),50 => to_signed(1892, 13), 51 => to_signed(-784, 13),
        52 => to_signed(-784, 13), 53 => to_signed(1892, 13), 54 => to_signed(-1892, 13),55 => to_signed(784, 13),
        56 => to_signed(400, 13),  57 => to_signed(-1138, 13),58 => to_signed(1703, 13), 59 => to_signed(-2009, 13),
        60 => to_signed(2009, 13), 61 => to_signed(-1703, 13),62 => to_signed(1138, 13), 63 => to_signed(-400, 13)
    );

    signal x  : sample_array_t := (others => (others => '0'));
    signal xc : sample_array_t := (others => (others => '0'));

    signal in_cnt       : unsigned(2 downto 0) := (others => '0');
    signal in_row_ready : std_logic := '0';

    signal calc_k      : unsigned(2 downto 0) := (others => '0');
    signal calc_active : std_logic := '0';

    signal prod : prod_array_t := (others => (others => '0'));
    signal sum_01 : signed(25 downto 0) := (others => '0');
    signal sum_23 : signed(25 downto 0) := (others => '0');
    signal sum_45 : signed(25 downto 0) := (others => '0');
    signal sum_67 : signed(25 downto 0) := (others => '0');
    signal sum_0123 : signed(26 downto 0) := (others => '0');
    signal sum_4567 : signed(26 downto 0) := (others => '0');

    signal pipe_s1_valid : std_logic := '0';
    signal pipe_s2_valid : std_logic := '0';
    signal pipe_s3_valid : std_logic := '0';
    signal pipe_s1_last  : std_logic := '0';
    signal pipe_s2_last  : std_logic := '0';
    signal pipe_s3_last  : std_logic := '0';

    signal out_valid_r : std_logic := '0';
    signal out_data_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal out_last_r  : std_logic := '0';

begin

    out_valid <= out_valid_r;
    out_data <= out_data_r;
    out_last <= out_last_r;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                in_cnt <= (others => '0');
                in_row_ready <= '0';
            else
                in_row_ready <= '0';
                if in_valid = '1' then
                    x(to_integer(in_cnt)) <= signed(in_data);
                    if in_cnt = 7 then
                        in_cnt <= (others => '0');
                        in_row_ready <= '1';
                    else
                        in_cnt <= in_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if in_row_ready = '1' then
                xc <= x;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                calc_k <= (others => '0');
                calc_active <= '0';
            else
                if in_row_ready = '1' then
                    calc_k <= (others => '0');
                    calc_active <= '1';
                elsif calc_active = '1' then
                    if calc_k = 7 then
                        calc_active <= '0';
                    else
                        calc_k <= calc_k + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable idx : natural;
        variable p   : signed(24 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                pipe_s1_valid <= '0';
                pipe_s1_last <= '0';
            else
                pipe_s1_valid <= calc_active;
                if calc_active = '1' and calc_k = 7 then
                    pipe_s1_last <= '1';
                else
                    pipe_s1_last <= '0';
                end if;

                if calc_active = '1' then
                    for n in 0 to 7 loop
                        idx := to_integer(calc_k) * 8 + n;
                        p := xc(n) * COS_ROM(idx);
                        prod(n) <= p;
                    end loop;
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                pipe_s2_valid <= '0';
                pipe_s2_last <= '0';
            else
                pipe_s2_valid <= pipe_s1_valid;
                pipe_s2_last <= pipe_s1_last;
                if pipe_s1_valid = '1' then
                    sum_01 <= resize(prod(0), 26) + resize(prod(1), 26);
                    sum_23 <= resize(prod(2), 26) + resize(prod(3), 26);
                    sum_45 <= resize(prod(4), 26) + resize(prod(5), 26);
                    sum_67 <= resize(prod(6), 26) + resize(prod(7), 26);
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                pipe_s3_valid <= '0';
                pipe_s3_last <= '0';
            else
                pipe_s3_valid <= pipe_s2_valid;
                pipe_s3_last <= pipe_s2_last;
                if pipe_s2_valid = '1' then
                    sum_0123 <= resize(sum_01, 27) + resize(sum_23, 27);
                    sum_4567 <= resize(sum_45, 27) + resize(sum_67, 27);
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable final_sum : signed(27 downto 0);
        variable shifted   : signed(27 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                out_valid_r <= '0';
                out_last_r <= '0';
                out_data_r <= (others => '0');
            else
                out_valid_r <= pipe_s3_valid;
                out_last_r <= pipe_s3_last;
                if pipe_s3_valid = '1' then
                    final_sum := resize(sum_0123, 28) + resize(sum_4567, 28) + to_signed(2048, 28);
                    shifted := shift_right(final_sum, 12);
                    out_data_r <= std_logic_vector(resize(shifted, 16));
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
