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

    signal awready_i : std_logic;
    signal wready_i  : std_logic;
    signal arready_i : std_logic;
    signal bresp_r   : std_logic_vector(1 downto 0) := (others => '0');
    signal bvalid_r  : std_logic := '0';
    signal rdata_r   : std_logic_vector(31 downto 0) := (others => '0');
    signal rresp_r   : std_logic_vector(1 downto 0) := (others => '0');
    signal rvalid_r  : std_logic := '0';

    signal reg_ctrl    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_status  : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_quality : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(95, 32));
    signal reg_restart : std_logic_vector(31 downto 0) := (others => '0');

    signal wr_addr     : std_logic_vector(4 downto 0) := (others => '0');
    signal wr_data     : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_strb     : std_logic_vector(3 downto 0) := (others => '0');
    signal aw_received : std_logic := '0';
    signal w_received  : std_logic := '0';
    signal strb_mask   : std_logic_vector(31 downto 0);

    -- Byte-lane merge honoring WSTRB
    function merge(old_val, new_val, mask : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return (old_val and not mask) or (new_val and mask);
    end function merge;

begin

    -- AW and W are accepted independently (each captured at its own
    -- handshake), the register is written once both are held, then B is
    -- returned. A new AW/W is not accepted until B completes.
    awready_i <= '1' when aw_received = '0' and bvalid_r = '0' else '0';
    wready_i  <= '1' when w_received = '0' and bvalid_r = '0' else '0';
    -- ARREADY is high while no response is outstanding; RVALID follows the
    -- AR handshake by one cycle and is held until RREADY.
    arready_i <= not rvalid_r;

    s_axi_awready <= awready_i;
    s_axi_wready  <= wready_i;
    s_axi_bresp   <= bresp_r;
    s_axi_bvalid  <= bvalid_r;
    s_axi_arready <= arready_i;
    s_axi_rdata   <= rdata_r;
    s_axi_rresp   <= rresp_r;
    s_axi_rvalid  <= rvalid_r;

    ctrl_enable <= reg_ctrl(0);
    ctrl_soft_reset <= reg_ctrl(1);
    ctrl_quality <= reg_quality(6 downto 0);
    ctrl_restart_interval <= reg_restart(15 downto 0);

    g_mask : for b in 0 to 3 generate
        strb_mask(8*b+7 downto 8*b) <= (others => wr_strb(b));
    end generate;

    p_write : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                bvalid_r <= '0';
                bresp_r <= (others => '0');
                aw_received <= '0';
                w_received <= '0';
                wr_addr <= (others => '0');
                wr_data <= (others => '0');
                wr_strb <= (others => '0');
                reg_ctrl <= (others => '0');
                reg_status <= (others => '0');
                reg_quality <= std_logic_vector(to_unsigned(95, 32));
                reg_restart <= (others => '0');
            else
                if s_axi_awvalid = '1' and awready_i = '1' then
                    wr_addr <= s_axi_awaddr;
                    aw_received <= '1';
                end if;
                if s_axi_wvalid = '1' and wready_i = '1' then
                    wr_data <= s_axi_wdata;
                    wr_strb <= s_axi_wstrb;
                    w_received <= '1';
                end if;

                -- Update status from hardware
                reg_status(0) <= sts_busy;
                if sts_frame_done_pulse = '1' then
                    reg_status(1) <= '1';
                end if;

                -- Perform the write once both address and data are held
                if aw_received = '1' and w_received = '1' then
                    case wr_addr(4 downto 2) is
                        when "000" =>
                            reg_ctrl <= merge(reg_ctrl, wr_data, strb_mask);
                        when "001" =>
                            -- W1C on frame_done; a same-cycle new frame_done wins
                            if wr_data(1) = '1' and wr_strb(0) = '1' and
                                    sts_frame_done_pulse = '0' then
                                reg_status(1) <= '0';
                            end if;
                        when "011" =>
                            if LITE_MODE = 0 then
                                reg_quality <= merge(reg_quality, wr_data, strb_mask);
                            end if;
                        when "100" =>
                            reg_restart <= merge(reg_restart, wr_data, strb_mask);
                        when others =>
                            null;
                    end case;
                    bvalid_r <= '1';
                    bresp_r <= "00";
                    aw_received <= '0';
                    w_received <= '0';
                end if;

                -- Write response handshake
                if bvalid_r = '1' and s_axi_bready = '1' then
                    bvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    p_read : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rvalid_r <= '0';
                rdata_r <= (others => '0');
                rresp_r <= (others => '0');
            else
                if s_axi_arvalid = '1' and arready_i = '1' then
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
                elsif rvalid_r = '1' and s_axi_rready = '1' then
                    rvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
