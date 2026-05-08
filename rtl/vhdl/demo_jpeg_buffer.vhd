-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

-- Behavioral tiled JPEG output buffer for the board demo shell.
--
-- The tile depth keeps large JPEG buffers from becoming cascaded BRAMs in
-- Vivado, while preserving the one-cycle read timing expected by demo_top.
entity demo_jpeg_buffer is
    generic (
        JPEG_WORDS      : natural := 65536;
        JPEG_TILE_DEPTH : natural := 4096
    );
    port (
        clk   : in  std_logic;
        we    : in  std_logic;
        waddr : in  std_logic_vector(16 downto 0);
        wdata : in  std_logic_vector(31 downto 0);
        raddr : in  std_logic_vector(16 downto 0);
        rdata : out std_logic_vector(31 downto 0)
    );
end entity demo_jpeg_buffer;

architecture rtl of demo_jpeg_buffer is
    function sel_bits_for(tile_count : natural) return natural is
    begin
        if tile_count <= 1 then
            return 1;
        else
            return clog2(tile_count);
        end if;
    end function;

    constant ADDR_W   : natural := clog2(JPEG_WORDS);
    constant N_TILES  : natural := (JPEG_WORDS + JPEG_TILE_DEPTH - 1) / JPEG_TILE_DEPTH;
    constant SEL_BITS : natural := sel_bits_for(N_TILES);
    constant INNER_W  : natural := clog2(JPEG_TILE_DEPTH);

    subtype data_t is std_logic_vector(31 downto 0);
    type ram_t is array (0 to JPEG_TILE_DEPTH-1) of data_t;
    type data_array_t is array (natural range <>) of data_t;

    signal tile_dout : data_array_t(0 to N_TILES-1);
begin

    assert JPEG_WORDS > 0 report "JPEG_WORDS must be positive" severity failure;
    assert JPEG_WORDS <= 65536 report "JPEG_WORDS must be <= 65536" severity failure;
    assert JPEG_TILE_DEPTH > 0 report "JPEG_TILE_DEPTH must be positive" severity failure;

    g_tile : for gi in 0 to N_TILES-1 generate
        signal mem : ram_t;
        attribute ram_style : string;
        attribute ram_style of mem : signal is "block";
        signal tile_we : std_logic;
        signal tile_rdata : data_t := (others => '0');
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
                tile_rdata <= mem(to_integer(unsigned(raddr(INNER_W-1 downto 0))));
            end if;
        end process;

        tile_dout(gi) <= tile_rdata;
    end generate;

    g_out_one : if N_TILES = 1 generate
    begin
        rdata <= tile_dout(0);
    end generate;

    g_out_mux : if N_TILES > 1 generate
        process(tile_dout, raddr)
            variable selected : data_t;
        begin
            selected := tile_dout(0);
            for mi in 1 to N_TILES-1 loop
                if raddr(ADDR_W-1 downto ADDR_W-SEL_BITS) =
                        std_logic_vector(to_unsigned(mi, SEL_BITS)) then
                    selected := tile_dout(mi);
                end if;
            end loop;
            rdata <= selected;
        end process;
    end generate;

end architecture rtl;
