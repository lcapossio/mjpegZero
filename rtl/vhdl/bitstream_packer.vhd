-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bitstream_packer is
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        in_valid   : in  std_logic;
        in_bits    : in  std_logic_vector(31 downto 0);
        in_len     : in  std_logic_vector(5 downto 0);
        in_flush   : in  std_logic;
        in_restart : in  std_logic;
        bp_ready   : out std_logic;
        out_valid  : out std_logic;
        out_data   : out std_logic_vector(7 downto 0);
        out_last   : out std_logic;
        out_ready  : in  std_logic;
        byte_count : out std_logic_vector(31 downto 0)
    );
end entity bitstream_packer;

architecture rtl of bitstream_packer is

    type state_t is (
        S_NORMAL,
        S_RST_PAD,
        S_RST_DRAIN,
        S_RST_FF,
        S_RST_MARKER,
        S_FLUSH_PAD,
        S_FLUSH_LAST
    );

    signal bit_buf_r     : std_logic_vector(63 downto 0) := (others => '0');
    signal bit_cnt_r     : unsigned(6 downto 0) := (others => '0');
    signal need_stuff_r  : std_logic := '0';
    signal state_r       : state_t := S_NORMAL;
    signal rst_counter_r : unsigned(2 downto 0) := (others => '0');

    signal out_valid_r  : std_logic := '0';
    signal out_data_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal out_last_r   : std_logic := '0';
    signal byte_count_r : unsigned(31 downto 0) := (others => '0');

    function pad_mask(bit_cnt : unsigned(6 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(shift_right(to_unsigned(16#FF#, 8),
                                            to_integer(bit_cnt(2 downto 0))));
    end function;

begin

    bp_ready <= '1' when state_r = S_NORMAL and bit_cnt_r < to_unsigned(8, 7) and need_stuff_r = '0' else '0';
    out_valid <= out_valid_r;
    out_data <= out_data_r;
    out_last <= out_last_r;
    byte_count <= std_logic_vector(byte_count_r);

    process (clk)
        variable incoming_bits : std_logic_vector(63 downto 0);
        variable padded_byte   : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                bit_buf_r     <= (others => '0');
                bit_cnt_r     <= (others => '0');
                out_valid_r   <= '0';
                out_data_r    <= (others => '0');
                out_last_r    <= '0';
                need_stuff_r  <= '0';
                state_r       <= S_NORMAL;
                rst_counter_r <= (others => '0');
                byte_count_r  <= (others => '0');
            else
                if out_valid_r = '1' and out_ready = '1' then
                    out_valid_r <= '0';
                    out_last_r <= '0';
                end if;

                case state_r is
                    when S_NORMAL =>
                        if need_stuff_r = '1' and (out_valid_r = '0' or out_ready = '1') then
                            out_valid_r <= '1';
                            out_data_r <= x"00";
                            need_stuff_r <= '0';
                            byte_count_r <= byte_count_r + 1;
                        elsif bit_cnt_r >= to_unsigned(8, 7) and need_stuff_r = '0' and
                              (out_valid_r = '0' or out_ready = '1') then
                            out_valid_r <= '1';
                            out_data_r <= bit_buf_r(63 downto 56);
                            bit_buf_r <= bit_buf_r(55 downto 0) & x"00";
                            bit_cnt_r <= bit_cnt_r - 8;
                            byte_count_r <= byte_count_r + 1;
                            if bit_buf_r(63 downto 56) = x"FF" then
                                need_stuff_r <= '1';
                            end if;
                        elsif in_valid = '1' and
                              state_r = S_NORMAL and bit_cnt_r < to_unsigned(8, 7) and need_stuff_r = '0' and
                              (out_valid_r = '0' or out_ready = '1') then
                            incoming_bits := std_logic_vector(shift_right(unsigned(in_bits & x"00000000"),
                                                                           to_integer(bit_cnt_r)));
                            bit_buf_r <= bit_buf_r or incoming_bits;
                            bit_cnt_r <= bit_cnt_r + resize(unsigned(in_len), bit_cnt_r'length);
                        end if;

                        if in_restart = '1' then
                            state_r <= S_RST_PAD;
                        elsif in_flush = '1' then
                            state_r <= S_FLUSH_PAD;
                        end if;

                    when S_RST_PAD =>
                        if out_valid_r = '0' or out_ready = '1' then
                            if need_stuff_r = '1' then
                                out_valid_r <= '1';
                                out_data_r <= x"00";
                                need_stuff_r <= '0';
                                byte_count_r <= byte_count_r + 1;
                            elsif bit_cnt_r > 0 then
                                if bit_cnt_r < to_unsigned(8, 7) then
                                    bit_buf_r(63 downto 56) <= bit_buf_r(63 downto 56) or pad_mask(bit_cnt_r);
                                    bit_cnt_r <= to_unsigned(8, 7);
                                end if;
                                state_r <= S_RST_DRAIN;
                            else
                                state_r <= S_RST_FF;
                            end if;
                        end if;

                    when S_RST_DRAIN =>
                        if out_valid_r = '0' or out_ready = '1' then
                            if need_stuff_r = '1' then
                                out_valid_r <= '1';
                                out_data_r <= x"00";
                                need_stuff_r <= '0';
                                byte_count_r <= byte_count_r + 1;
                            elsif bit_cnt_r >= to_unsigned(8, 7) then
                                out_valid_r <= '1';
                                out_data_r <= bit_buf_r(63 downto 56);
                                bit_buf_r <= bit_buf_r(55 downto 0) & x"00";
                                bit_cnt_r <= bit_cnt_r - 8;
                                byte_count_r <= byte_count_r + 1;
                                if bit_buf_r(63 downto 56) = x"FF" then
                                    need_stuff_r <= '1';
                                end if;
                            else
                                state_r <= S_RST_FF;
                            end if;
                        end if;

                    when S_RST_FF =>
                        if out_valid_r = '0' or out_ready = '1' then
                            out_valid_r <= '1';
                            out_data_r <= x"FF";
                            need_stuff_r <= '0';
                            byte_count_r <= byte_count_r + 1;
                            state_r <= S_RST_MARKER;
                        end if;

                    when S_RST_MARKER =>
                        if out_valid_r = '0' or out_ready = '1' then
                            out_valid_r <= '1';
                            out_data_r <= "11010" & std_logic_vector(rst_counter_r);
                            byte_count_r <= byte_count_r + 1;
                            rst_counter_r <= rst_counter_r + 1;
                            state_r <= S_NORMAL;
                            bit_buf_r <= (others => '0');
                            bit_cnt_r <= (others => '0');
                        end if;

                    when S_FLUSH_PAD =>
                        if out_valid_r = '0' or out_ready = '1' then
                            if need_stuff_r = '1' then
                                out_valid_r <= '1';
                                out_data_r <= x"00";
                                need_stuff_r <= '0';
                                byte_count_r <= byte_count_r + 1;
                            elsif bit_cnt_r >= to_unsigned(8, 7) then
                                out_valid_r <= '1';
                                out_data_r <= bit_buf_r(63 downto 56);
                                bit_buf_r <= bit_buf_r(55 downto 0) & x"00";
                                bit_cnt_r <= bit_cnt_r - 8;
                                byte_count_r <= byte_count_r + 1;
                                if bit_buf_r(63 downto 56) = x"FF" then
                                    need_stuff_r <= '1';
                                end if;
                            elsif bit_cnt_r > 0 then
                                padded_byte := bit_buf_r(63 downto 56) or pad_mask(bit_cnt_r);
                                out_valid_r <= '1';
                                out_data_r <= padded_byte;
                                byte_count_r <= byte_count_r + 1;
                                bit_buf_r <= (others => '0');
                                bit_cnt_r <= (others => '0');
                                if padded_byte = x"FF" then
                                    need_stuff_r <= '1';
                                else
                                    state_r <= S_FLUSH_LAST;
                                end if;
                            else
                                state_r <= S_FLUSH_LAST;
                            end if;
                        end if;

                    when S_FLUSH_LAST =>
                        if out_valid_r = '0' or out_ready = '1' then
                            if need_stuff_r = '1' then
                                out_valid_r <= '1';
                                out_data_r <= x"00";
                                need_stuff_r <= '0';
                                byte_count_r <= byte_count_r + 1;
                            else
                                out_last_r <= '1';
                                out_valid_r <= '1';
                                out_data_r <= x"00";
                                state_r <= S_NORMAL;
                                bit_buf_r <= (others => '0');
                                bit_cnt_r <= (others => '0');
                                rst_counter_r <= (others => '0');
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
