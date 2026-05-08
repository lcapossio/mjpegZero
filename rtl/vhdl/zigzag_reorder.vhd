-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity zigzag_reorder is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        in_valid  : in  std_logic;
        in_data   : in  std_logic_vector(15 downto 0);
        in_sob    : in  std_logic;

        out_valid : out std_logic;
        out_data  : out std_logic_vector(15 downto 0);
        out_sob   : out std_logic
    );
end entity zigzag_reorder;

architecture rtl of zigzag_reorder is

    type zigzag_lut_t is array (0 to 63) of natural range 0 to 63;
    constant ZIGZAG_POS : zigzag_lut_t := (
         0 =>  0,  1 =>  1,  2 =>  5,  3 =>  6,
         4 => 14,  5 => 15,  6 => 27,  7 => 28,
         8 =>  2,  9 =>  4, 10 =>  7, 11 => 13,
        12 => 16, 13 => 26, 14 => 29, 15 => 42,
        16 =>  3, 17 =>  8, 18 => 12, 19 => 17,
        20 => 25, 21 => 30, 22 => 41, 23 => 43,
        24 =>  9, 25 => 11, 26 => 18, 27 => 24,
        28 => 31, 29 => 40, 30 => 44, 31 => 53,
        32 => 10, 33 => 19, 34 => 23, 35 => 32,
        36 => 39, 37 => 45, 38 => 52, 39 => 54,
        40 => 20, 41 => 22, 42 => 33, 43 => 38,
        44 => 46, 45 => 51, 46 => 55, 47 => 60,
        48 => 21, 49 => 34, 50 => 37, 51 => 47,
        52 => 50, 53 => 56, 54 => 59, 55 => 61,
        56 => 35, 57 => 36, 58 => 48, 59 => 49,
        60 => 57, 61 => 58, 62 => 62, 63 => 63
    );

    type coeff_buf_t is array (0 to 63) of std_logic_vector(15 downto 0);
    signal buf0 : coeff_buf_t := (others => (others => '0'));
    signal buf1 : coeff_buf_t := (others => (others => '0'));

    signal buf_sel       : std_logic := '0';
    signal wr_cnt        : unsigned(5 downto 0) := (others => '0');
    signal wr_block_done : std_logic := '0';

    signal rd_cnt    : unsigned(5 downto 0) := (others => '0');
    signal rd_active : std_logic := '0';

    signal out_valid_r : std_logic := '0';
    signal out_data_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal out_sob_r   : std_logic := '0';

begin

    out_valid <= out_valid_r;
    out_data <= out_data_r;
    out_sob <= out_sob_r;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                wr_cnt <= (others => '0');
                wr_block_done <= '0';
                buf_sel <= '0';
            else
                wr_block_done <= '0';

                if in_valid = '1' then
                    if buf_sel = '0' then
                        buf0(ZIGZAG_POS(to_integer(wr_cnt))) <= in_data;
                    else
                        buf1(ZIGZAG_POS(to_integer(wr_cnt))) <= in_data;
                    end if;

                    if wr_cnt = to_unsigned(63, 6) then
                        wr_cnt <= (others => '0');
                        wr_block_done <= '1';
                        buf_sel <= not buf_sel;
                    else
                        wr_cnt <= wr_cnt + 1;
                    end if;

                    if in_sob = '1' then
                        wr_cnt <= to_unsigned(1, 6);
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_cnt <= (others => '0');
                rd_active <= '0';
                out_valid_r <= '0';
                out_sob_r <= '0';
            else
                out_valid_r <= '0';
                out_sob_r <= '0';

                if rd_active = '1' then
                    out_valid_r <= '1';
                    if rd_cnt = to_unsigned(0, 6) then
                        out_sob_r <= '1';
                    else
                        out_sob_r <= '0';
                    end if;

                    if buf_sel = '1' then
                        out_data_r <= buf0(to_integer(rd_cnt));
                    else
                        out_data_r <= buf1(to_integer(rd_cnt));
                    end if;

                    if rd_cnt = to_unsigned(63, 6) then
                        rd_active <= '0';
                    end if;
                    rd_cnt <= rd_cnt + 1;
                end if;

                if wr_block_done = '1' then
                    rd_active <= '1';
                    rd_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
