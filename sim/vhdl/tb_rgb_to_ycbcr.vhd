-- ============================================================================
-- Testbench: rgb_to_ycbcr (VHDL)
-- ============================================================================
-- Mirror of sim/tb_rgb_to_ycbcr.sv: feeds known RGB colors and reports the
-- YUYV output words. Expected BT.601 full-range sequence (C, Y):
--   (128,0) (128,255) (85,76) (255,76) (44,150) (21,150) (255,29) (128,128)
--
-- Run:
--   ghdl -a --std=08 rtl/vhdl/rgb_to_ycbcr.vhd sim/vhdl/tb_rgb_to_ycbcr.vhd
--   ghdl -e --std=08 tb_rgb_to_ycbcr
--   ghdl -r --std=08 tb_rgb_to_ycbcr --vcd=sim/tb_rgb_to_ycbcr_vhdl.vcd
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rgb_to_ycbcr is
end entity;

architecture sim of tb_rgb_to_ycbcr is
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';

    signal s_tdata  : std_logic_vector(23 downto 0) := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tlast  : std_logic := '0';
    signal s_tuser  : std_logic := '0';

    signal m_tdata  : std_logic_vector(15 downto 0);
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';
    signal m_tlast  : std_logic;
    signal m_tuser  : std_logic;

    signal done     : boolean := false;

    type pix_array is array (0 to 7) of std_logic_vector(23 downto 0);
    constant PIXELS : pix_array := (
        x"000000",  -- black
        x"FFFFFF",  -- white
        x"FF0000",  -- red
        x"FF0000",  -- red
        x"00FF00",  -- green
        x"00FF00",  -- green
        x"0000FF",  -- blue
        x"808080"   -- gray
    );
begin

    dut : entity work.rgb_to_ycbcr
        port map (
            clk           => clk,
            rst_n         => rst_n,
            s_axis_tdata  => s_tdata,
            s_axis_tvalid => s_tvalid,
            s_axis_tready => s_tready,
            s_axis_tlast  => s_tlast,
            s_axis_tuser  => s_tuser,
            m_axis_tdata  => m_tdata,
            m_axis_tvalid => m_tvalid,
            m_axis_tready => m_tready,
            m_axis_tlast  => m_tlast,
            m_axis_tuser  => m_tuser
        );

    clk <= not clk after 5 ns when not done else '0';

    stim : process
    begin
        wait for 40 ns;
        rst_n <= '1';
        wait until rising_edge(clk);

        for i in PIXELS'range loop
            s_tdata  <= PIXELS(i);
            s_tvalid <= '1';
            if i = 0 then s_tuser <= '1'; else s_tuser <= '0'; end if;
            if i = PIXELS'high then s_tlast <= '1'; else s_tlast <= '0'; end if;
            wait until rising_edge(clk);
            while s_tready /= '1' loop
                wait until rising_edge(clk);
            end loop;
        end loop;
        s_tvalid <= '0';
        s_tlast  <= '0';
        s_tuser  <= '0';

        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        done <= true;
        wait;
    end process;

    mon : process(clk)
        variable count : integer := 0;
    begin
        if rising_edge(clk) then
            if m_tvalid = '1' and m_tready = '1' then
                report "out[" & integer'image(count) & "] C=" &
                       integer'image(to_integer(unsigned(m_tdata(15 downto 8)))) &
                       " Y=" &
                       integer'image(to_integer(unsigned(m_tdata(7 downto 0))));
                count := count + 1;
            end if;
        end if;
    end process;

end architecture;
