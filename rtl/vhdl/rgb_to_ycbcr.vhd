-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rgb_to_ycbcr is
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;

        s_axis_tdata  : in  std_logic_vector(23 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tuser  : in  std_logic;

        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic;
        m_axis_tuser  : out std_logic
    );
end entity rgb_to_ycbcr;

architecture rtl of rgb_to_ycbcr is

    signal p1_r     : unsigned(7 downto 0) := (others => '0');
    signal p1_g     : unsigned(7 downto 0) := (others => '0');
    signal p1_b     : unsigned(7 downto 0) := (others => '0');
    signal p1_valid : std_logic := '0';
    signal p1_last  : std_logic := '0';
    signal p1_user  : std_logic := '0';

    signal p2_y_raw  : signed(25 downto 0) := (others => '0');
    signal p2_cb_raw : signed(25 downto 0) := (others => '0');
    signal p2_cr_raw : signed(25 downto 0) := (others => '0');
    signal p2_valid  : std_logic := '0';
    signal p2_last   : std_logic := '0';
    signal p2_user   : std_logic := '0';

    signal pixel_odd : std_logic := '0';

    signal m_axis_tdata_r  : std_logic_vector(15 downto 0) := (others => '0');
    signal m_axis_tvalid_r : std_logic := '0';
    signal m_axis_tlast_r  : std_logic := '0';
    signal m_axis_tuser_r  : std_logic := '0';

    signal y_shifted  : signed(9 downto 0);
    signal cb_shifted : signed(9 downto 0);
    signal cr_shifted : signed(9 downto 0);
    signal y_clamped  : std_logic_vector(7 downto 0);
    signal cb_clamped : std_logic_vector(7 downto 0);
    signal cr_clamped : std_logic_vector(7 downto 0);

    signal ready_i : std_logic;

    function clamp8(value : signed(9 downto 0)) return std_logic_vector is
    begin
        if value < to_signed(0, value'length) then
            return x"00";
        elsif value > to_signed(255, value'length) then
            return x"FF";
        else
            return std_logic_vector(value(7 downto 0));
        end if;
    end function;

begin

    ready_i <= m_axis_tready or not m_axis_tvalid_r;
    s_axis_tready <= ready_i;

    m_axis_tdata <= m_axis_tdata_r;
    m_axis_tvalid <= m_axis_tvalid_r;
    m_axis_tlast <= m_axis_tlast_r;
    m_axis_tuser <= m_axis_tuser_r;

    y_shifted <= p2_y_raw(25 downto 16);
    cb_shifted <= p2_cb_raw(25 downto 16) + to_signed(128, 10);
    cr_shifted <= p2_cr_raw(25 downto 16) + to_signed(128, 10);

    y_clamped <= clamp8(y_shifted);
    cb_clamped <= clamp8(cb_shifted);
    cr_clamped <= clamp8(cr_shifted);

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                p1_valid <= '0';
                p1_last <= '0';
                p1_user <= '0';
            elsif ready_i = '1' then
                p1_valid <= s_axis_tvalid;
                p1_r <= unsigned(s_axis_tdata(23 downto 16));
                p1_g <= unsigned(s_axis_tdata(15 downto 8));
                p1_b <= unsigned(s_axis_tdata(7 downto 0));
                p1_last <= s_axis_tlast;
                p1_user <= s_axis_tuser;
            end if;
        end if;
    end process;

    process (clk)
        variable r_i : integer;
        variable g_i : integer;
        variable b_i : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                p2_valid <= '0';
                p2_last <= '0';
                p2_user <= '0';
            elsif ready_i = '1' then
                r_i := to_integer(p1_r);
                g_i := to_integer(p1_g);
                b_i := to_integer(p1_b);

                p2_valid <= p1_valid;
                p2_last <= p1_last;
                p2_user <= p1_user;
                p2_y_raw <= to_signed((19595 * r_i) + (38470 * g_i) + (7471 * b_i) + 32768, 26);
                p2_cb_raw <= to_signed((-11056 * r_i) + (-21712 * g_i) + (32768 * b_i) + 32768, 26);
                p2_cr_raw <= to_signed((32768 * r_i) + (-27440 * g_i) + (-5328 * b_i) + 32768, 26);
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                m_axis_tvalid_r <= '0';
                m_axis_tlast_r <= '0';
                m_axis_tuser_r <= '0';
                pixel_odd <= '0';
            elsif ready_i = '1' then
                m_axis_tvalid_r <= p2_valid;
                m_axis_tlast_r <= p2_last;
                m_axis_tuser_r <= p2_user;

                if p2_valid = '1' then
                    if pixel_odd = '0' then
                        m_axis_tdata_r <= cb_clamped & y_clamped;
                        pixel_odd <= '1';
                    else
                        m_axis_tdata_r <= cr_clamped & y_clamped;
                        pixel_odd <= '0';
                    end if;

                    if p2_user = '1' then
                        pixel_odd <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
