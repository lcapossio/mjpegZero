-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

-- Vendor-neutral tiled behavioral simple dual-port RAM.
-- Read latency is two clocks. The 4096-deep behavioral tiling makes the
-- desired memory banking visible without instantiating vendor primitives.
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
    type ram_t is array (0 to TILE_DEPTH-1) of data_t;
    type data_array_t is array (natural range <>) of data_t;

    signal rsel_now : std_logic_vector(SEL_BITS-1 downto 0);
    signal rsel_d1  : std_logic_vector(SEL_BITS-1 downto 0) := (others => '0');
    signal rsel_d2  : std_logic_vector(SEL_BITS-1 downto 0) := (others => '0');
    signal tile_dout : data_array_t(0 to N_TILES-1);
begin

    assert DEPTH > 0 report "DEPTH must be positive" severity failure;
    assert WIDTH > 0 report "WIDTH must be positive" severity failure;

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
        signal mem : ram_t;
        signal tile_we : std_logic;
        signal rdata_r : data_t := (others => '0');
        signal rdata_q : data_t := (others => '0');
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

        process(clk)
        begin
            if rising_edge(clk) then
                if tile_we = '1' then
                    mem(to_integer(unsigned(waddr(INNER_W-1 downto 0)))) <= wdata;
                end if;
                rdata_r <= mem(to_integer(unsigned(raddr(INNER_W-1 downto 0))));
                rdata_q <= rdata_r;
            end if;
        end process;

        tile_dout(gi) <= rdata_q;
    end generate;

    g_out_one : if N_TILES = 1 generate
    begin
        rdata <= tile_dout(0);
    end generate;

    g_out_mux : if N_TILES > 1 generate
        process(tile_dout, rsel_d2)
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
