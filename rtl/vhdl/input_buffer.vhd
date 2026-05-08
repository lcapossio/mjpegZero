-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mjpegzero_pkg.all;

entity input_buffer is
    generic (
        IMG_WIDTH : natural := 1280
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;

        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tuser  : in  std_logic;

        blk_valid     : out std_logic;
        blk_data      : out std_logic_vector(7 downto 0);
        blk_sof       : out std_logic;
        blk_sob       : out std_logic;
        blk_comp      : out std_logic_vector(1 downto 0);
        blk_ready     : in  std_logic;

        lines_done    : out std_logic
    );
end entity input_buffer;

architecture rtl of input_buffer is

    constant MCU_COLS     : natural := IMG_WIDTH / 16;
    constant Y_BANK_SIZE  : natural := 8 * IMG_WIDTH;
    constant CB_BANK_SIZE : natural := 8 * (IMG_WIDTH / 2);
    constant CR_BANK_SIZE : natural := 8 * (IMG_WIDTH / 2);
    constant CHROMA_WIDTH : natural := IMG_WIDTH / 2;

    constant Y_ADDR_W  : natural := clog2(2 * Y_BANK_SIZE);
    constant CB_ADDR_W : natural := clog2(2 * CB_BANK_SIZE);
    constant CR_ADDR_W : natural := clog2(2 * CR_BANK_SIZE);

    component bram_sdp is
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
    end component;

    signal y_buf_we    : std_logic := '0';
    signal y_buf_waddr : std_logic_vector(Y_ADDR_W-1 downto 0) := (others => '0');
    signal y_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal y_buf_raddr : std_logic_vector(Y_ADDR_W-1 downto 0) := (others => '0');
    signal y_buf_rdata : std_logic_vector(7 downto 0);

    signal cb_buf_we    : std_logic := '0';
    signal cb_buf_waddr : std_logic_vector(CB_ADDR_W-1 downto 0) := (others => '0');
    signal cb_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal cb_buf_raddr : std_logic_vector(CB_ADDR_W-1 downto 0) := (others => '0');
    signal cb_buf_rdata : std_logic_vector(7 downto 0);

    signal cr_buf_we    : std_logic := '0';
    signal cr_buf_waddr : std_logic_vector(CR_ADDR_W-1 downto 0) := (others => '0');
    signal cr_buf_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal cr_buf_raddr : std_logic_vector(CR_ADDR_W-1 downto 0) := (others => '0');
    signal cr_buf_rdata : std_logic_vector(7 downto 0);

    signal rd_bank            : std_logic := '0';
    signal rd_active          : std_logic := '0';
    signal lines_done_pending : std_logic := '0';
    signal rd_bank_pending    : std_logic := '0';

    signal wr_bank         : std_logic := '0';
    signal wr_x            : unsigned(10 downto 0) := (others => '0');
    signal wr_line         : unsigned(2 downto 0) := (others => '0');
    signal wr_mcu_row      : unsigned(6 downto 0) := (others => '0');
    signal wr_phase        : std_logic := '0';
    signal wr_frame_active : std_logic := '0';
    signal wr_8lines_done  : std_logic := '0';

    signal s_axis_tready_i : std_logic;
    signal wr_accept : std_logic;

    type rd_state_t is (RD_IDLE, RD_READ);
    signal rd_state       : rd_state_t := RD_IDLE;
    signal rd_mcu_col     : unsigned(6 downto 0) := (others => '0');
    signal rd_comp        : unsigned(1 downto 0) := (others => '0');
    signal rd_row         : unsigned(2 downto 0) := (others => '0');
    signal rd_col         : unsigned(2 downto 0) := (others => '0');
    signal rd_started     : std_logic := '0';
    signal rd_sof_pending : std_logic := '0';

    signal rd_valid_pipe : std_logic := '0';
    signal rd_sob_pipe   : std_logic := '0';
    signal rd_comp_pipe  : unsigned(1 downto 0) := (others => '0');
    signal rd_sof_pipe   : std_logic := '0';

    signal blk_valid_r : std_logic := '0';
    signal blk_data_r  : std_logic_vector(7 downto 0) := (others => '0');
    signal blk_sof_r   : std_logic := '0';
    signal blk_sob_r   : std_logic := '0';
    signal blk_comp_r  : unsigned(1 downto 0) := (others => '0');

    signal out_valid_d1 : std_logic := '0';
    signal out_valid_d2 : std_logic := '0';
    signal out_sob_d1   : std_logic := '0';
    signal out_sob_d2   : std_logic := '0';
    signal out_sof_d1   : std_logic := '0';
    signal out_sof_d2   : std_logic := '0';
    signal out_comp_d1  : unsigned(1 downto 0) := (others => '0');
    signal out_comp_d2  : unsigned(1 downto 0) := (others => '0');

begin

    assert IMG_WIDTH > 0 report "IMG_WIDTH must be positive" severity failure;
    assert (IMG_WIDTH mod 16) = 0 report "IMG_WIDTH must be a multiple of 16" severity failure;

    u_y_mem : bram_sdp
        generic map (DEPTH => 2 * Y_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => y_buf_we, waddr => y_buf_waddr,
            wdata => y_buf_wdata, raddr => y_buf_raddr, rdata => y_buf_rdata
        );

    u_cb_mem : bram_sdp
        generic map (DEPTH => 2 * CB_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => cb_buf_we, waddr => cb_buf_waddr,
            wdata => cb_buf_wdata, raddr => cb_buf_raddr, rdata => cb_buf_rdata
        );

    u_cr_mem : bram_sdp
        generic map (DEPTH => 2 * CR_BANK_SIZE, WIDTH => 8)
        port map (
            clk => clk, we => cr_buf_we, waddr => cr_buf_waddr,
            wdata => cr_buf_wdata, raddr => cr_buf_raddr, rdata => cr_buf_rdata
        );

    s_axis_tready_i <= '1' when wr_frame_active = '1' and (wr_bank /= rd_bank or rd_active = '0') else '0';
    s_axis_tready <= s_axis_tready_i;
    wr_accept <= s_axis_tvalid and s_axis_tready_i;
    lines_done <= wr_8lines_done;

    blk_valid <= blk_valid_r;
    blk_data <= blk_data_r;
    blk_sof <= blk_sof_r;
    blk_sob <= blk_sob_r;
    blk_comp <= std_logic_vector(blk_comp_r);

    process (clk)
        variable y_addr  : natural;
        variable cb_addr : natural;
        variable cr_addr : natural;
        variable bank_base_y  : natural;
        variable bank_base_cb : natural;
        variable bank_base_cr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                wr_bank <= '0';
                wr_x <= (others => '0');
                wr_line <= (others => '0');
                wr_mcu_row <= (others => '0');
                wr_phase <= '0';
                wr_frame_active <= '0';
                wr_8lines_done <= '0';
                y_buf_we <= '0';
                cb_buf_we <= '0';
                cr_buf_we <= '0';
            else
                y_buf_we <= '0';
                cb_buf_we <= '0';
                cr_buf_we <= '0';
                wr_8lines_done <= '0';

                if s_axis_tvalid = '1' and s_axis_tuser = '1' then
                    wr_frame_active <= '1';
                    wr_x <= (others => '0');
                    wr_line <= (others => '0');
                    wr_mcu_row <= (others => '0');
                    wr_phase <= '0';
                    wr_bank <= '0';
                end if;

                if wr_accept = '1' and wr_frame_active = '1' then
                    if wr_bank = '1' then
                        bank_base_y := Y_BANK_SIZE;
                        bank_base_cb := CB_BANK_SIZE;
                        bank_base_cr := CR_BANK_SIZE;
                    else
                        bank_base_y := 0;
                        bank_base_cb := 0;
                        bank_base_cr := 0;
                    end if;

                    y_addr := bank_base_y + to_integer(wr_line) * IMG_WIDTH + to_integer(wr_x);
                    y_buf_we <= '1';
                    y_buf_waddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                    y_buf_wdata <= s_axis_tdata(7 downto 0);

                    if wr_phase = '0' then
                        cb_addr := bank_base_cb + to_integer(wr_line) * CHROMA_WIDTH + to_integer(wr_x(10 downto 1));
                        cb_buf_we <= '1';
                        cb_buf_waddr <= std_logic_vector(to_unsigned(cb_addr, CB_ADDR_W));
                        cb_buf_wdata <= s_axis_tdata(15 downto 8);
                    else
                        cr_addr := bank_base_cr + to_integer(wr_line) * CHROMA_WIDTH + to_integer(wr_x(10 downto 1));
                        cr_buf_we <= '1';
                        cr_buf_waddr <= std_logic_vector(to_unsigned(cr_addr, CR_ADDR_W));
                        cr_buf_wdata <= s_axis_tdata(15 downto 8);
                    end if;

                    wr_phase <= not wr_phase;
                    wr_x <= wr_x + 1;

                    if wr_x = to_unsigned(IMG_WIDTH - 1, wr_x'length) or s_axis_tlast = '1' then
                        wr_x <= (others => '0');
                        wr_phase <= '0';
                        if wr_line = to_unsigned(7, wr_line'length) then
                            wr_line <= (others => '0');
                            wr_8lines_done <= '1';
                            wr_bank <= not wr_bank;
                            wr_mcu_row <= wr_mcu_row + 1;
                        else
                            wr_line <= wr_line + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable y_addr  : natural;
        variable cb_addr : natural;
        variable cr_addr : natural;
        variable bank_base_y  : natural;
        variable bank_base_cb : natural;
        variable bank_base_cr : natural;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rd_bank <= '0';
                rd_mcu_col <= (others => '0');
                rd_comp <= (others => '0');
                rd_row <= (others => '0');
                rd_col <= (others => '0');
                rd_active <= '0';
                rd_started <= '0';
                rd_sof_pending <= '0';
                rd_state <= RD_IDLE;
                rd_valid_pipe <= '0';
                rd_sob_pipe <= '0';
                rd_sof_pipe <= '0';
                rd_comp_pipe <= (others => '0');
                lines_done_pending <= '0';
                rd_bank_pending <= '0';
            else
                rd_valid_pipe <= '0';
                rd_sob_pipe <= '0';
                rd_sof_pipe <= '0';

                if wr_8lines_done = '1' and rd_state = RD_READ then
                    lines_done_pending <= '1';
                    rd_bank_pending <= not wr_bank;
                end if;

                case rd_state is
                    when RD_IDLE =>
                        if wr_8lines_done = '1' or lines_done_pending = '1' then
                            rd_active <= '1';
                            if wr_8lines_done = '1' then
                                rd_bank <= not wr_bank;
                            else
                                rd_bank <= rd_bank_pending;
                            end if;
                            rd_mcu_col <= (others => '0');
                            rd_comp <= (others => '0');
                            rd_row <= (others => '0');
                            rd_col <= (others => '0');
                            rd_state <= RD_READ;
                            lines_done_pending <= '0';
                            if rd_started = '0' then
                                rd_sof_pending <= '1';
                                rd_started <= '1';
                            end if;
                        end if;

                    when RD_READ =>
                        if blk_ready = '1' then
                            rd_valid_pipe <= '1';
                            rd_comp_pipe <= rd_comp;

                            if rd_sof_pending = '1' and rd_row = 0 and rd_col = 0 then
                                rd_sof_pipe <= '1';
                                rd_sof_pending <= '0';
                            end if;

                            if rd_row = 0 and rd_col = 0 then
                                rd_sob_pipe <= '1';
                            end if;

                            if rd_bank = '1' then
                                bank_base_y := Y_BANK_SIZE;
                                bank_base_cb := CB_BANK_SIZE;
                                bank_base_cr := CR_BANK_SIZE;
                            else
                                bank_base_y := 0;
                                bank_base_cb := 0;
                                bank_base_cr := 0;
                            end if;

                            case to_integer(rd_comp) is
                                when 0 =>
                                    y_addr := bank_base_y + to_integer(rd_row) * IMG_WIDTH +
                                              to_integer(rd_mcu_col) * 16 + to_integer(rd_col);
                                    y_buf_raddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                                when 1 =>
                                    y_addr := bank_base_y + to_integer(rd_row) * IMG_WIDTH +
                                              to_integer(rd_mcu_col) * 16 + 8 + to_integer(rd_col);
                                    y_buf_raddr <= std_logic_vector(to_unsigned(y_addr, Y_ADDR_W));
                                when 2 =>
                                    cb_addr := bank_base_cb + to_integer(rd_row) * CHROMA_WIDTH +
                                               to_integer(rd_mcu_col) * 8 + to_integer(rd_col);
                                    cb_buf_raddr <= std_logic_vector(to_unsigned(cb_addr, CB_ADDR_W));
                                when others =>
                                    cr_addr := bank_base_cr + to_integer(rd_row) * CHROMA_WIDTH +
                                               to_integer(rd_mcu_col) * 8 + to_integer(rd_col);
                                    cr_buf_raddr <= std_logic_vector(to_unsigned(cr_addr, CR_ADDR_W));
                            end case;

                            rd_col <= rd_col + 1;
                            if rd_col = 7 then
                                rd_col <= (others => '0');
                                rd_row <= rd_row + 1;
                                if rd_row = 7 then
                                    rd_row <= (others => '0');
                                    rd_comp <= rd_comp + 1;
                                    if rd_comp = 3 then
                                        rd_comp <= (others => '0');
                                        rd_mcu_col <= rd_mcu_col + 1;
                                        if rd_mcu_col = to_unsigned(MCU_COLS - 1, rd_mcu_col'length) then
                                            rd_state <= RD_IDLE;
                                            rd_active <= '0';
                                        end if;
                                    end if;
                                end if;
                            end if;
                        end if;
                end case;

                if s_axis_tvalid = '1' and s_axis_tuser = '1' then
                    rd_started <= '0';
                    rd_state <= RD_IDLE;
                    lines_done_pending <= '0';
                    rd_active <= '0';
                end if;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                blk_valid_r <= '0';
                blk_data_r <= (others => '0');
                blk_sof_r <= '0';
                blk_sob_r <= '0';
                blk_comp_r <= (others => '0');
                out_valid_d1 <= '0';
                out_sob_d1 <= '0';
                out_sof_d1 <= '0';
                out_comp_d1 <= (others => '0');
                out_valid_d2 <= '0';
                out_sob_d2 <= '0';
                out_sof_d2 <= '0';
                out_comp_d2 <= (others => '0');
            else
                out_valid_d1 <= rd_valid_pipe;
                out_sob_d1 <= rd_sob_pipe;
                out_sof_d1 <= rd_sof_pipe;
                out_comp_d1 <= rd_comp_pipe;

                out_valid_d2 <= out_valid_d1;
                out_sob_d2 <= out_sob_d1;
                out_sof_d2 <= out_sof_d1;
                out_comp_d2 <= out_comp_d1;

                blk_valid_r <= out_valid_d2;
                blk_sob_r <= out_sob_d2;
                blk_sof_r <= out_sof_d2;
                blk_comp_r <= out_comp_d2;

                if out_comp_d2 <= 1 then
                    blk_data_r <= y_buf_rdata;
                elsif out_comp_d2 = 2 then
                    blk_data_r <= cb_buf_rdata;
                else
                    blk_data_r <= cr_buf_rdata;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
