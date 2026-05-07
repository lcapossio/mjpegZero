-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.mjpegzero_pkg.all;

entity bram_sdp is
    generic (
        DEPTH : natural := 8192;
        WIDTH : natural := 8
    );
    port (
        clk   : in  std_logic;
        we    : in  std_logic;
        waddr : in  std_logic_vector(clog2(DEPTH)-1 downto 0);
        wdata : in  std_logic_vector(WIDTH-1 downto 0);
        raddr : in  std_logic_vector(clog2(DEPTH)-1 downto 0);
        rdata : out std_logic_vector(WIDTH-1 downto 0)
    );
end entity bram_sdp;

architecture rtl of bram_sdp is
    function sel_bits_for(tile_count : natural) return natural is
    begin
        if tile_count <= 1 then
            return 1;
        else
            return clog2(tile_count);
        end if;
    end function;

    function inner_width_for(addr_width : natural; tile_count : natural; sel_width : natural) return natural is
    begin
        if tile_count <= 1 then
            return addr_width;
        else
            return addr_width - sel_width;
        end if;
    end function;

    constant TILE_DEPTH : natural := 4096;
    constant N_TILES    : natural := (DEPTH + TILE_DEPTH - 1) / TILE_DEPTH;
    constant ADDR_W     : natural := clog2(DEPTH);
    constant SEL_BITS   : natural := sel_bits_for(N_TILES);
    constant INNER_W    : natural := inner_width_for(ADDR_W, N_TILES, SEL_BITS);

    subtype data_t is std_logic_vector(WIDTH-1 downto 0);
    type data_array_t is array (natural range <>) of data_t;

    signal rsel_now : std_logic_vector(SEL_BITS-1 downto 0);
    signal rsel_d1  : std_logic_vector(SEL_BITS-1 downto 0) := (others => '0');
    signal rsel_d2  : std_logic_vector(SEL_BITS-1 downto 0) := (others => '0');
    signal tile_dout : data_array_t(0 to N_TILES-1);
begin

    assert DEPTH > 0 report "DEPTH must be positive" severity failure;
    assert WIDTH = 8 report "AMD 7-series bram_sdp supports WIDTH=8" severity failure;

    g_sel_one : if N_TILES <= 1 generate
    begin
        rsel_now <= (others => '0');
    end generate;

    g_sel_multi : if N_TILES > 1 generate
    begin
        rsel_now <= raddr(ADDR_W-1 downto ADDR_W-SEL_BITS);
    end generate;

    process(clk)
    begin
        if rising_edge(clk) then
            rsel_d1 <= rsel_now;
            rsel_d2 <= rsel_d1;
        end if;
    end process;

    g_tile : for gi in 0 to N_TILES-1 generate
        signal tile_we : std_logic;
        signal inner_wa : std_logic_vector(11 downto 0);
        signal inner_ra : std_logic_vector(11 downto 0);
        signal addr_a : std_logic_vector(15 downto 0);
        signal addr_b : std_logic_vector(15 downto 0);
        signal dob_out : std_logic_vector(31 downto 0);
    begin
        g_we_one : if N_TILES = 1 generate
        begin
            tile_we <= we;
        end generate;

        g_we_multi : if N_TILES > 1 generate
        begin
            tile_we <= we when waddr(ADDR_W-1 downto ADDR_W-SEL_BITS) =
                    std_logic_vector(to_unsigned(gi, SEL_BITS)) else '0';
        end generate;

        inner_wa <= std_logic_vector(resize(unsigned(waddr(INNER_W-1 downto 0)), 12));
        inner_ra <= std_logic_vector(resize(unsigned(raddr(INNER_W-1 downto 0)), 12));
        addr_a <= '1' & inner_wa & "000";
        addr_b <= '1' & inner_ra & "000";

        u_bram : RAMB36E1
            generic map (
                RAM_MODE => "TDP",
                READ_WIDTH_A => 9,
                READ_WIDTH_B => 9,
                WRITE_WIDTH_A => 9,
                WRITE_WIDTH_B => 9,
                DOA_REG => 0,
                DOB_REG => 1,
                WRITE_MODE_A => "NO_CHANGE",
                WRITE_MODE_B => "WRITE_FIRST",
                RDADDR_COLLISION_HWCONFIG => "DELAYED_WRITE",
                RSTREG_PRIORITY_A => "REGCE",
                RSTREG_PRIORITY_B => "REGCE",
                SIM_COLLISION_CHECK => "NONE",
                SIM_DEVICE => "7SERIES",
                INIT_A => X"000000000",
                INIT_B => X"000000000",
                SRVAL_A => X"000000000",
                SRVAL_B => X"000000000",
                EN_ECC_READ => false,
                EN_ECC_WRITE => false,
                IS_CLKARDCLK_INVERTED => '0',
                IS_CLKBWRCLK_INVERTED => '0',
                IS_ENARDEN_INVERTED => '0',
                IS_ENBWREN_INVERTED => '0',
                IS_RSTRAMARSTRAM_INVERTED => '0',
                IS_RSTRAMB_INVERTED => '0',
                IS_RSTREGARSTREG_INVERTED => '0',
                IS_RSTREGB_INVERTED => '0'
            )
            port map (
                CLKARDCLK => clk,
                ENARDEN => tile_we,
                WEA => "0001",
                ADDRARDADDR => addr_a,
                DIADI => X"000000" & wdata,
                DIPADIP => "0000",
                DOADO => open,
                DOPADOP => open,
                REGCEAREGCE => '0',

                CLKBWRCLK => clk,
                ENBWREN => '1',
                WEBWE => X"00",
                ADDRBWRADDR => addr_b,
                DIBDI => (others => '0'),
                DIPBDIP => "0000",
                DOBDO => dob_out,
                DOPBDOP => open,
                REGCEB => '1',

                RSTRAMARSTRAM => '0',
                RSTRAMB => '0',
                RSTREGARSTREG => '0',
                RSTREGB => '0',

                CASCADEINA => '0',
                CASCADEINB => '0',
                CASCADEOUTA => open,
                CASCADEOUTB => open,

                DBITERR => open,
                SBITERR => open,
                ECCPARITY => open,
                RDADDRECC => open,
                INJECTDBITERR => '0',
                INJECTSBITERR => '0'
            );

        tile_dout(gi) <= dob_out(WIDTH-1 downto 0);
    end generate;

    g_out_one : if N_TILES = 1 generate
    begin
        rdata <= tile_dout(0);
    end generate;

    g_out_mux : if N_TILES > 1 generate
        process(all)
            variable selected : data_t;
        begin
            selected := tile_dout(0);
            for mi in 1 to N_TILES-1 loop
                if rsel_d2 = std_logic_vector(to_unsigned(mi, SEL_BITS)) then
                    selected := tile_dout(mi);
                end if;
            end loop;
            rdata <= selected;
        end process;
    end generate;

end architecture rtl;
