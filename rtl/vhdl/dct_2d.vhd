-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dct_2d is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        in_valid  : in  std_logic;
        in_data   : in  std_logic_vector(11 downto 0);
        in_sof    : in  std_logic;

        out_valid : out std_logic;
        out_data  : out std_logic_vector(15 downto 0);
        out_sof   : out std_logic
    );
end entity dct_2d;

architecture rtl of dct_2d is

    component dct_1d is
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
    end component;

    type dct_buf_t is array (0 to 63) of std_logic_vector(15 downto 0);

    signal in_sample_cnt : unsigned(5 downto 0) := (others => '0');
    signal in_last_of_row : std_logic;

    signal row_dct_out_valid : std_logic;
    signal row_dct_out_data  : std_logic_vector(15 downto 0);
    signal row_dct_out_last  : std_logic;

    signal tbuf0 : dct_buf_t := (others => (others => '0'));
    signal tbuf1 : dct_buf_t := (others => (others => '0'));
    signal tbuf_sel        : std_logic := '0';
    signal tbuf_wr_cnt     : unsigned(5 downto 0) := (others => '0');
    signal tbuf_wr_row     : unsigned(2 downto 0) := (others => '0');
    signal tbuf_wr_col     : unsigned(2 downto 0) := (others => '0');
    signal tbuf_block_done : std_logic := '0';

    signal tbuf_rd_row    : unsigned(2 downto 0) := (others => '0');
    signal tbuf_rd_col    : unsigned(2 downto 0) := (others => '0');
    signal tbuf_rd_active : std_logic := '0';
    signal tbuf_rd_valid  : std_logic := '0';
    signal tbuf_rd_data   : std_logic_vector(15 downto 0) := (others => '0');
    signal tbuf_rd_sel    : std_logic := '0';
    signal tbuf_rd_col_d  : unsigned(2 downto 0) := (others => '0');
    signal tbuf_rd_row_last : std_logic;

    signal col_dct_in : std_logic_vector(11 downto 0);
    signal col_dct_out_valid : std_logic;
    signal col_dct_out_data  : std_logic_vector(15 downto 0);
    signal col_dct_out_last_unused : std_logic;

    signal obuf0 : dct_buf_t := (others => (others => '0'));
    signal obuf1 : dct_buf_t := (others => (others => '0'));
    signal obuf_wr_sel     : std_logic := '0';
    signal obuf_wr_cnt     : unsigned(5 downto 0) := (others => '0');
    signal obuf_block_done : std_logic := '0';

    signal obuf_rd_active : std_logic := '0';
    signal obuf_rd_cnt    : unsigned(5 downto 0) := (others => '0');
    signal obuf_rd_sel    : std_logic := '0';

    signal out_valid_r : std_logic := '0';
    signal out_data_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal out_cnt     : unsigned(5 downto 0) := (others => '0');

begin

    out_valid <= out_valid_r;
    out_data <= out_data_r;
    out_sof <= '1' when out_valid_r = '1' and out_cnt = 0 else '0';

    in_last_of_row <= '1' when in_sample_cnt(2 downto 0) = 7 and in_valid = '1' else '0';

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                in_sample_cnt <= (others => '0');
            elsif in_valid = '1' then
                if in_sof = '1' then
                    in_sample_cnt <= to_unsigned(1, in_sample_cnt'length);
                else
                    in_sample_cnt <= in_sample_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    u_row_dct : dct_1d
        port map (
            clk => clk, rst_n => rst_n, in_valid => in_valid, in_data => in_data,
            in_last => in_last_of_row, out_valid => row_dct_out_valid,
            out_data => row_dct_out_data, out_last => row_dct_out_last
        );

    process (clk)
        variable addr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                tbuf_wr_cnt <= (others => '0');
                tbuf_wr_row <= (others => '0');
                tbuf_wr_col <= (others => '0');
                tbuf_block_done <= '0';
                tbuf_sel <= '0';
            else
                tbuf_block_done <= '0';
                if row_dct_out_valid = '1' then
                    addr := to_integer(tbuf_wr_row & tbuf_wr_col);
                    if tbuf_sel = '0' then
                        tbuf0(addr) <= row_dct_out_data;
                    else
                        tbuf1(addr) <= row_dct_out_data;
                    end if;

                    tbuf_wr_col <= tbuf_wr_col + 1;
                    tbuf_wr_cnt <= tbuf_wr_cnt + 1;

                    if row_dct_out_last = '1' then
                        tbuf_wr_row <= tbuf_wr_row + 1;
                        tbuf_wr_col <= (others => '0');
                    end if;

                    if tbuf_wr_cnt = 63 then
                        tbuf_block_done <= '1';
                        tbuf_wr_cnt <= (others => '0');
                        tbuf_wr_row <= (others => '0');
                        tbuf_wr_col <= (others => '0');
                        tbuf_sel <= not tbuf_sel;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable addr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                tbuf_rd_row <= (others => '0');
                tbuf_rd_col <= (others => '0');
                tbuf_rd_active <= '0';
                tbuf_rd_valid <= '0';
                tbuf_rd_sel <= '0';
            else
                tbuf_rd_valid <= '0';

                if tbuf_rd_active = '1' then
                    tbuf_rd_valid <= '1';
                    addr := to_integer(tbuf_rd_col & tbuf_rd_row);
                    if tbuf_rd_sel = '0' then
                        tbuf_rd_data <= tbuf0(addr);
                    else
                        tbuf_rd_data <= tbuf1(addr);
                    end if;

                    tbuf_rd_col <= tbuf_rd_col + 1;
                    if tbuf_rd_col = 7 then
                        tbuf_rd_col <= (others => '0');
                        tbuf_rd_row <= tbuf_rd_row + 1;
                        if tbuf_rd_row = 7 then
                            tbuf_rd_active <= '0';
                        end if;
                    end if;
                end if;

                if tbuf_block_done = '1' then
                    tbuf_rd_sel <= not tbuf_sel;
                    tbuf_rd_active <= '1';
                    tbuf_rd_row <= (others => '0');
                    tbuf_rd_col <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            tbuf_rd_col_d <= tbuf_rd_col;
        end if;
    end process;

    tbuf_rd_row_last <= '1' when tbuf_rd_valid = '1' and tbuf_rd_col_d = 7 else '0';

    process (tbuf_rd_data)
        variable v : signed(15 downto 0);
    begin
        v := signed(tbuf_rd_data);
        if v > to_signed(2047, 16) then
            col_dct_in <= std_logic_vector(to_signed(2047, 12));
        elsif v < to_signed(-2048, 16) then
            col_dct_in <= std_logic_vector(to_signed(-2048, 12));
        else
            col_dct_in <= tbuf_rd_data(11 downto 0);
        end if;
    end process;

    u_col_dct : dct_1d
        port map (
            clk => clk, rst_n => rst_n, in_valid => tbuf_rd_valid,
            in_data => col_dct_in, in_last => tbuf_rd_row_last,
            out_valid => col_dct_out_valid, out_data => col_dct_out_data,
            out_last => col_dct_out_last_unused
        );

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                obuf_wr_sel <= '0';
                obuf_wr_cnt <= (others => '0');
                obuf_block_done <= '0';
            else
                obuf_block_done <= '0';
                if col_dct_out_valid = '1' then
                    if obuf_wr_sel = '0' then
                        obuf0(to_integer(obuf_wr_cnt)) <= col_dct_out_data;
                    else
                        obuf1(to_integer(obuf_wr_cnt)) <= col_dct_out_data;
                    end if;

                    if obuf_wr_cnt = 63 then
                        obuf_wr_cnt <= (others => '0');
                        obuf_wr_sel <= not obuf_wr_sel;
                        obuf_block_done <= '1';
                    else
                        obuf_wr_cnt <= obuf_wr_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable addr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                obuf_rd_active <= '0';
                obuf_rd_cnt <= (others => '0');
                obuf_rd_sel <= '0';
                out_valid_r <= '0';
                out_data_r <= (others => '0');
            else
                out_valid_r <= '0';

                if obuf_rd_active = '1' then
                    out_valid_r <= '1';
                    addr := to_integer(obuf_rd_cnt(2 downto 0) & obuf_rd_cnt(5 downto 3));
                    if obuf_rd_sel = '0' then
                        out_data_r <= obuf0(addr);
                    else
                        out_data_r <= obuf1(addr);
                    end if;

                    if obuf_rd_cnt = 63 then
                        obuf_rd_active <= '0';
                    end if;
                    obuf_rd_cnt <= obuf_rd_cnt + 1;
                end if;

                if obuf_block_done = '1' then
                    obuf_rd_sel <= not obuf_wr_sel;
                    obuf_rd_active <= '1';
                    obuf_rd_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                out_cnt <= (others => '0');
            elsif out_valid_r = '1' then
                if out_cnt = 63 then
                    out_cnt <= (others => '0');
                else
                    out_cnt <= out_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
