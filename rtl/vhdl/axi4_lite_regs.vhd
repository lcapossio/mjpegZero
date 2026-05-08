-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi4_lite_regs is
    generic (
        LITE_MODE : natural := 0
    );
    port (
        clk   : in  std_logic;
        rst_n : in  std_logic;

        s_axi_awaddr  : in  std_logic_vector(4 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(4 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        ctrl_enable           : out std_logic;
        ctrl_soft_reset       : out std_logic;
        ctrl_quality          : out std_logic_vector(6 downto 0);
        ctrl_restart_interval : out std_logic_vector(15 downto 0);

        sts_busy             : in std_logic;
        sts_frame_done_pulse : in std_logic;
        sts_frame_cnt        : in std_logic_vector(31 downto 0);
        sts_frame_size       : in std_logic_vector(31 downto 0)
    );
end entity axi4_lite_regs;

architecture rtl of axi4_lite_regs is

    signal awready_r : std_logic := '0';
    signal wready_r  : std_logic := '0';
    signal bresp_r   : std_logic_vector(1 downto 0) := (others => '0');
    signal bvalid_r  : std_logic := '0';
    signal arready_r : std_logic := '0';
    signal rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
    signal rresp_r   : std_logic_vector(1 downto 0) := (others => '0');
    signal rvalid_r  : std_logic := '0';

    signal reg_ctrl    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_status  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_quality : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(95, 32));
    signal reg_restart : std_logic_vector(31 downto 0) := (others => '0');

    signal wr_addr    : std_logic_vector(4 downto 0) := (others => '0');
    signal aw_received : std_logic := '0';
    signal w_received  : std_logic := '0';

begin

    s_axi_awready <= awready_r;
    s_axi_wready  <= wready_r;
    s_axi_bresp   <= bresp_r;
    s_axi_bvalid  <= bvalid_r;
    s_axi_arready <= arready_r;
    s_axi_rdata   <= rdata_r;
    s_axi_rresp   <= rresp_r;
    s_axi_rvalid  <= rvalid_r;

    ctrl_enable <= reg_ctrl(0);
    ctrl_soft_reset <= reg_ctrl(1);
    ctrl_quality <= reg_quality(6 downto 0);
    ctrl_restart_interval <= reg_restart(15 downto 0);

    p_write : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                awready_r <= '0';
                wready_r <= '0';
                bvalid_r <= '0';
                bresp_r <= (others => '0');
                aw_received <= '0';
                w_received <= '0';
                wr_addr <= (others => '0');
                reg_ctrl <= (others => '0');
                reg_status <= (others => '0');
                reg_quality <= std_logic_vector(to_unsigned(95, 32));
                reg_restart <= (others => '0');
            else
                if s_axi_awvalid = '1' and aw_received = '0' and bvalid_r = '0' then
                    awready_r <= '1';
                    wr_addr <= s_axi_awaddr;
                    aw_received <= '1';
                else
                    awready_r <= '0';
                end if;

                if s_axi_wvalid = '1' and w_received = '0' and bvalid_r = '0' then
                    wready_r <= '1';
                    w_received <= '1';
                else
                    wready_r <= '0';
                end if;

                if aw_received = '1' and w_received = '1' then
                    case wr_addr(4 downto 2) is
                        when "000" =>
                            reg_ctrl <= s_axi_wdata;
                        when "001" =>
                            reg_status <= reg_status and not s_axi_wdata;
                        when "011" =>
                            if LITE_MODE = 0 then
                                reg_quality <= s_axi_wdata;
                            end if;
                        when "100" =>
                            reg_restart <= s_axi_wdata;
                        when others =>
                            null;
                    end case;
                    bvalid_r <= '1';
                    bresp_r <= "00";
                    aw_received <= '0';
                    w_received <= '0';
                end if;

                if bvalid_r = '1' and s_axi_bready = '1' then
                    bvalid_r <= '0';
                end if;

                reg_status(0) <= sts_busy;
                if sts_frame_done_pulse = '1' then
                    reg_status(1) <= '1';
                end if;
            end if;
        end if;
    end process;

    p_read : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                arready_r <= '0';
                rvalid_r <= '0';
                rdata_r <= (others => '0');
                rresp_r <= (others => '0');
            else
                if s_axi_arvalid = '1' and rvalid_r = '0' then
                    arready_r <= '1';
                    rvalid_r <= '1';
                    rresp_r <= "00";
                    case s_axi_araddr(4 downto 2) is
                        when "000" =>
                            rdata_r <= reg_ctrl;
                        when "001" =>
                            rdata_r <= reg_status;
                        when "010" =>
                            rdata_r <= sts_frame_cnt;
                        when "011" =>
                            rdata_r <= reg_quality;
                        when "100" =>
                            rdata_r <= reg_restart;
                        when "101" =>
                            rdata_r <= sts_frame_size;
                        when others =>
                            rdata_r <= (others => '0');
                    end case;
                else
                    arready_r <= '0';
                end if;

                if rvalid_r = '1' and s_axi_rready = '1' then
                    rvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
