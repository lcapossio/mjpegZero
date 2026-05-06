-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

-- Native VHDL structural top for mjpegzero_enc_top.
--
-- This is the first real top-down translation step. The top-level control,
-- reset, frame accounting, component-ID tracking, and flow-control logic are
-- VHDL. Pipeline leaves still bind to the existing Verilog modules for tight
-- mixed-language equivalence against the current implementation.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mjpegzero_enc_top is
    generic (
        LITE_MODE     : natural := 1;
        LITE_QUALITY  : natural := 95;
        IMG_WIDTH     : natural := 1280;
        IMG_HEIGHT    : natural := 720;
        EXIF_ENABLE   : natural := 0;
        EXIF_X_RES    : natural := 72;
        EXIF_Y_RES    : natural := 72;
        EXIF_RES_UNIT : natural := 2;
        RGB_INPUT     : natural := 0;
        VID_DATA_W    : natural := 16
    );
    port (
        clk   : in  std_logic;
        rst_n : in  std_logic;

        s_axis_vid_tdata  : in  std_logic_vector(VID_DATA_W - 1 downto 0);
        s_axis_vid_tvalid : in  std_logic;
        s_axis_vid_tready : out std_logic;
        s_axis_vid_tlast  : in  std_logic;
        s_axis_vid_tuser  : in  std_logic;

        m_axis_jpg_tvalid : out std_logic;
        m_axis_jpg_tdata  : out std_logic_vector(7 downto 0);
        m_axis_jpg_tlast  : out std_logic;

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
        s_axi_rready  : in  std_logic
    );
end entity mjpegzero_enc_top;

architecture rtl of mjpegzero_enc_top is

    component axi4_lite_regs is
        generic (LITE_MODE : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axi_awaddr : in std_logic_vector(4 downto 0);
            s_axi_awvalid : in std_logic; s_axi_awready : out std_logic;
            s_axi_wdata : in std_logic_vector(31 downto 0);
            s_axi_wstrb : in std_logic_vector(3 downto 0);
            s_axi_wvalid : in std_logic; s_axi_wready : out std_logic;
            s_axi_bresp : out std_logic_vector(1 downto 0);
            s_axi_bvalid : out std_logic; s_axi_bready : in std_logic;
            s_axi_araddr : in std_logic_vector(4 downto 0);
            s_axi_arvalid : in std_logic; s_axi_arready : out std_logic;
            s_axi_rdata : out std_logic_vector(31 downto 0);
            s_axi_rresp : out std_logic_vector(1 downto 0);
            s_axi_rvalid : out std_logic; s_axi_rready : in std_logic;
            ctrl_enable : out std_logic; ctrl_soft_reset : out std_logic;
            ctrl_quality : out std_logic_vector(6 downto 0);
            ctrl_restart_interval : out std_logic_vector(15 downto 0);
            sts_busy : in std_logic; sts_frame_done_pulse : in std_logic;
            sts_frame_cnt : in std_logic_vector(31 downto 0);
            sts_frame_size : in std_logic_vector(31 downto 0)
        );
    end component;

    component input_buffer is
        generic (IMG_WIDTH : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axis_tdata : in std_logic_vector(15 downto 0);
            s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
            s_axis_tlast : in std_logic; s_axis_tuser : in std_logic;
            blk_valid : out std_logic; blk_data : out std_logic_vector(7 downto 0);
            blk_sof : out std_logic; blk_sob : out std_logic;
            blk_comp : out std_logic_vector(1 downto 0);
            blk_ready : in std_logic; lines_done : out std_logic
        );
    end component;

    component dct_2d is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(11 downto 0);
            in_sof : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sof : out std_logic
        );
    end component;

    component quantizer is
        generic (LITE_MODE : natural; LITE_QUALITY : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            comp_id : in std_logic_vector(1 downto 0);
            quality : in std_logic_vector(6 downto 0);
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sof : in std_logic; in_sob : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sof : out std_logic; out_sob : out std_logic;
            qt_rd_addr : in std_logic_vector(5 downto 0);
            qt_rd_is_chroma : in std_logic; qt_rd_data : out std_logic_vector(7 downto 0)
        );
    end component;

    component zigzag_reorder is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sob : in std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(15 downto 0);
            out_sob : out std_logic
        );
    end component;

    component huffman_encoder is
        generic (LITE_MODE : natural);
        port (
            clk : in std_logic; rst_n : in std_logic;
            comp_id : in std_logic_vector(1 downto 0); restart : in std_logic;
            in_valid : in std_logic; in_data : in std_logic_vector(15 downto 0);
            in_sob : in std_logic;
            out_valid : out std_logic; out_bits : out std_logic_vector(31 downto 0);
            out_len : out std_logic_vector(5 downto 0);
            out_sob : out std_logic; out_eob : out std_logic;
            out_ready : in std_logic
        );
    end component;

    component bitstream_packer is
        port (
            clk : in std_logic; rst_n : in std_logic;
            in_valid : in std_logic; in_bits : in std_logic_vector(31 downto 0);
            in_len : in std_logic_vector(5 downto 0);
            in_flush : in std_logic; in_restart : in std_logic;
            bp_ready : out std_logic;
            out_valid : out std_logic; out_data : out std_logic_vector(7 downto 0);
            out_last : out std_logic; out_ready : in std_logic;
            byte_count : out std_logic_vector(31 downto 0)
        );
    end component;

    component jfif_writer is
        generic (
            IMG_WIDTH : natural; IMG_HEIGHT : natural;
            LITE_MODE : natural; LITE_QUALITY : natural;
            EXIF_ENABLE : natural; EXIF_X_RES : natural;
            EXIF_Y_RES : natural; EXIF_RES_UNIT : natural
        );
        port (
            clk : in std_logic; rst_n : in std_logic;
            frame_start : in std_logic; frame_done : in std_logic;
            restart_interval : in std_logic_vector(15 downto 0);
            qt_rd_addr : out std_logic_vector(5 downto 0);
            qt_rd_is_chroma : out std_logic;
            qt_rd_data : in std_logic_vector(7 downto 0);
            scan_valid : in std_logic; scan_data : in std_logic_vector(7 downto 0);
            scan_last : in std_logic; scan_ready : out std_logic;
            m_axis_tvalid : out std_logic; m_axis_tdata : out std_logic_vector(7 downto 0);
            m_axis_tlast : out std_logic; headers_done : out std_logic
        );
    end component;

    component rgb_to_ycbcr is
        port (
            clk : in std_logic; rst_n : in std_logic;
            s_axis_tdata : in std_logic_vector(23 downto 0);
            s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
            s_axis_tlast : in std_logic; s_axis_tuser : in std_logic;
            m_axis_tdata : out std_logic_vector(15 downto 0);
            m_axis_tvalid : out std_logic; m_axis_tready : in std_logic;
            m_axis_tlast : out std_logic; m_axis_tuser : out std_logic
        );
    end component;

    constant TOTAL_BLOCKS : natural := (IMG_WIDTH / 16) * (IMG_HEIGHT / 8) * 4;

    signal ctrl_enable : std_logic;
    signal ctrl_soft_reset : std_logic;
    signal ctrl_quality : std_logic_vector(6 downto 0);
    signal ctrl_restart_interval : std_logic_vector(15 downto 0);
    signal sts_busy : std_logic;
    signal sts_frame_done_pulse : std_logic;
    signal frame_cnt : unsigned(31 downto 0) := (others => '0');
    signal rst_int_n : std_logic;

    signal ibuf_blk_valid : std_logic;
    signal ibuf_blk_data : std_logic_vector(7 downto 0);
    signal ibuf_blk_sof : std_logic;
    signal ibuf_blk_sob : std_logic;
    signal ibuf_blk_comp : std_logic_vector(1 downto 0);
    signal ibuf_blk_ready : std_logic;
    signal ibuf_lines_done : std_logic;

    signal dct_in_data : std_logic_vector(11 downto 0);
    signal dct_in_valid : std_logic;
    signal dct_in_sof : std_logic;
    signal dct_out_valid : std_logic;
    signal dct_out_data : std_logic_vector(15 downto 0);
    signal dct_out_sof : std_logic;

    signal quant_out_valid : std_logic;
    signal quant_out_data : std_logic_vector(15 downto 0);
    signal quant_out_sob : std_logic;
    signal zz_out_valid : std_logic;
    signal zz_out_data : std_logic_vector(15 downto 0);
    signal zz_out_sob : std_logic;

    signal huff_out_valid : std_logic;
    signal huff_out_bits : std_logic_vector(31 downto 0);
    signal huff_out_len : std_logic_vector(5 downto 0);
    signal huff_out_eob : std_logic;
    signal huff_bp_ready : std_logic;

    signal bs_out_valid : std_logic;
    signal bs_out_data : std_logic_vector(7 downto 0);
    signal bs_out_last : std_logic;
    signal bs_out_ready : std_logic;
    signal bs_byte_count : std_logic_vector(31 downto 0);

    signal qt_rd_addr : std_logic_vector(5 downto 0);
    signal qt_rd_is_chroma : std_logic;
    signal qt_rd_data : std_logic_vector(7 downto 0);
    signal jfif_headers_done : std_logic;

    type comp_fifo_q_t is array (0 to 3) of std_logic_vector(1 downto 0);
    type comp_fifo_h_t is array (0 to 7) of std_logic_vector(1 downto 0);
    signal comp_fifo_q : comp_fifo_q_t := (others => (others => '0'));
    signal comp_fifo_h : comp_fifo_h_t := (others => (others => '0'));
    signal comp_fifo_q_wr : unsigned(2 downto 0) := (others => '0');
    signal comp_fifo_q_rd : unsigned(2 downto 0) := (others => '0');
    signal comp_fifo_h_wr : unsigned(3 downto 0) := (others => '0');
    signal comp_fifo_h_rd : unsigned(3 downto 0) := (others => '0');
    signal quant_comp_id : std_logic_vector(1 downto 0);
    signal huff_comp_id : std_logic_vector(1 downto 0);

    signal frame_active : std_logic := '0';
    signal frame_start_pulse : std_logic := '0';
    signal frame_done_pulse : std_logic := '0';
    signal mcu_count : unsigned(16 downto 0) := (others => '0');
    signal mcu_in_segment : unsigned(15 downto 0) := (others => '0');
    signal restart_trigger : std_logic := '0';
    signal frame_hdr_started : std_logic := '0';
    signal pipeline_depth : unsigned(2 downto 0) := (others => '0');

    signal vid_yuyv_tdata : std_logic_vector(15 downto 0);
    signal vid_yuyv_tvalid : std_logic;
    signal vid_yuyv_tready : std_logic;
    signal vid_yuyv_tlast : std_logic;
    signal vid_yuyv_tuser : std_logic;
    signal quant_out_sof_unused : std_logic;
    signal huff_out_sob_unused : std_logic;

begin

    assert IMG_WIDTH > 0 and IMG_HEIGHT > 0
        report "IMG_WIDTH and IMG_HEIGHT must be positive" severity failure;
    assert (IMG_WIDTH mod 16) = 0
        report "IMG_WIDTH must be a multiple of 16 for 4:2:2 MCUs" severity failure;
    assert (IMG_HEIGHT mod 8) = 0
        report "IMG_HEIGHT must be a multiple of 8" severity failure;
    assert LITE_QUALITY >= 1 and LITE_QUALITY <= 100
        report "LITE_QUALITY must be in the range 1..100" severity failure;
    assert EXIF_RES_UNIT >= 1 and EXIF_RES_UNIT <= 3
        report "EXIF_RES_UNIT must be 1, 2, or 3" severity failure;

    rst_int_n <= rst_n and not ctrl_soft_reset;
    dct_in_data <= std_logic_vector(signed(std_logic_vector(resize(unsigned(ibuf_blk_data), 12))) - to_signed(128, 12));
    dct_in_valid <= ibuf_blk_valid;
    dct_in_sof <= ibuf_blk_sob;
    quant_comp_id <= comp_fifo_q(to_integer(comp_fifo_q_rd(1 downto 0)));
    huff_comp_id <= comp_fifo_h(to_integer(comp_fifo_h_rd(2 downto 0)));
    sts_busy <= frame_active;
    sts_frame_done_pulse <= frame_done_pulse;
    ibuf_blk_ready <= ctrl_enable and jfif_headers_done when pipeline_depth < 2 else '0';

    p_comp_fifo_q : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                comp_fifo_q_wr <= (others => '0');
                comp_fifo_q_rd <= (others => '0');
            else
                if ibuf_blk_valid = '1' and ibuf_blk_sob = '1' then
                    comp_fifo_q(to_integer(comp_fifo_q_wr(1 downto 0))) <= ibuf_blk_comp;
                    comp_fifo_q_wr <= comp_fifo_q_wr + 1;
                end if;
                if dct_out_valid = '1' and dct_out_sof = '1' then
                    comp_fifo_q_rd <= comp_fifo_q_rd + 1;
                end if;
            end if;
        end if;
    end process;

    p_comp_fifo_h : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                comp_fifo_h_wr <= (others => '0');
                comp_fifo_h_rd <= (others => '0');
            else
                if ibuf_blk_valid = '1' and ibuf_blk_sob = '1' then
                    comp_fifo_h(to_integer(comp_fifo_h_wr(2 downto 0))) <= ibuf_blk_comp;
                    comp_fifo_h_wr <= comp_fifo_h_wr + 1;
                end if;
                if zz_out_valid = '1' and zz_out_sob = '1' then
                    comp_fifo_h_rd <= comp_fifo_h_rd + 1;
                end if;
            end if;
        end if;
    end process;

    p_frame_control : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                frame_active <= '0';
                frame_start_pulse <= '0';
                frame_done_pulse <= '0';
                frame_cnt <= (others => '0');
                mcu_count <= (others => '0');
                mcu_in_segment <= (others => '0');
                restart_trigger <= '0';
                frame_hdr_started <= '0';
            else
                frame_start_pulse <= '0';
                frame_done_pulse <= '0';
                restart_trigger <= '0';

                if ibuf_lines_done = '1' and frame_hdr_started = '0' then
                    frame_start_pulse <= '1';
                    frame_hdr_started <= '1';
                end if;

                if ibuf_blk_sof = '1' and ibuf_blk_valid = '1' then
                    frame_active <= '1';
                    mcu_count <= (others => '0');
                    mcu_in_segment <= (others => '0');
                end if;

                if huff_out_eob = '1' and huff_out_valid = '1' and huff_bp_ready = '1' then
                    mcu_count <= mcu_count + 1;

                    if mcu_count(1 downto 0) = "11" then
                        if ctrl_restart_interval /= x"0000" and
                                mcu_count /= to_unsigned(TOTAL_BLOCKS - 1, mcu_count'length) then
                            if mcu_in_segment + 1 >= unsigned(ctrl_restart_interval) then
                                restart_trigger <= '1';
                                mcu_in_segment <= (others => '0');
                            else
                                mcu_in_segment <= mcu_in_segment + 1;
                            end if;
                        end if;
                    end if;

                    if mcu_count = to_unsigned(TOTAL_BLOCKS - 1, mcu_count'length) then
                        frame_active <= '0';
                        frame_done_pulse <= '1';
                        frame_cnt <= frame_cnt + 1;
                        frame_hdr_started <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

    p_pipeline_depth : process(clk)
        variable push_block : boolean;
        variable pop_block : boolean;
    begin
        if rising_edge(clk) then
            if rst_int_n = '0' then
                pipeline_depth <= (others => '0');
            else
                push_block := ibuf_blk_valid = '1' and ibuf_blk_sob = '1' and ibuf_blk_ready = '1';
                pop_block := huff_out_eob = '1' and huff_out_valid = '1' and huff_bp_ready = '1';
                if push_block and not pop_block then
                    pipeline_depth <= pipeline_depth + 1;
                elsif pop_block and not push_block then
                    pipeline_depth <= pipeline_depth - 1;
                end if;
            end if;
        end if;
    end process;

    g_rgb_input : if RGB_INPUT /= 0 generate
    begin
        u_rgb2yuv : rgb_to_ycbcr
            port map (
                clk => clk, rst_n => rst_int_n,
                s_axis_tdata => s_axis_vid_tdata(23 downto 0),
                s_axis_tvalid => s_axis_vid_tvalid and ctrl_enable,
                s_axis_tready => s_axis_vid_tready,
                s_axis_tlast => s_axis_vid_tlast,
                s_axis_tuser => s_axis_vid_tuser,
                m_axis_tdata => vid_yuyv_tdata,
                m_axis_tvalid => vid_yuyv_tvalid,
                m_axis_tready => vid_yuyv_tready,
                m_axis_tlast => vid_yuyv_tlast,
                m_axis_tuser => vid_yuyv_tuser
            );
    end generate;

    g_yuyv_input : if RGB_INPUT = 0 generate
    begin
        s_axis_vid_tready <= vid_yuyv_tready;
        vid_yuyv_tdata <= s_axis_vid_tdata(15 downto 0);
        vid_yuyv_tvalid <= s_axis_vid_tvalid and ctrl_enable;
        vid_yuyv_tlast <= s_axis_vid_tlast;
        vid_yuyv_tuser <= s_axis_vid_tuser;
    end generate;

    u_regs : axi4_lite_regs
        generic map (LITE_MODE => LITE_MODE)
        port map (
            clk => clk, rst_n => rst_n,
            s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid,
            s_axi_awready => s_axi_awready, s_axi_wdata => s_axi_wdata,
            s_axi_wstrb => s_axi_wstrb, s_axi_wvalid => s_axi_wvalid,
            s_axi_wready => s_axi_wready, s_axi_bresp => s_axi_bresp,
            s_axi_bvalid => s_axi_bvalid, s_axi_bready => s_axi_bready,
            s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid,
            s_axi_arready => s_axi_arready, s_axi_rdata => s_axi_rdata,
            s_axi_rresp => s_axi_rresp, s_axi_rvalid => s_axi_rvalid,
            s_axi_rready => s_axi_rready, ctrl_enable => ctrl_enable,
            ctrl_soft_reset => ctrl_soft_reset, ctrl_quality => ctrl_quality,
            ctrl_restart_interval => ctrl_restart_interval, sts_busy => sts_busy,
            sts_frame_done_pulse => sts_frame_done_pulse,
            sts_frame_cnt => std_logic_vector(frame_cnt),
            sts_frame_size => bs_byte_count
        );

    u_input_buffer : input_buffer
        generic map (IMG_WIDTH => IMG_WIDTH)
        port map (
            clk => clk, rst_n => rst_int_n,
            s_axis_tdata => vid_yuyv_tdata, s_axis_tvalid => vid_yuyv_tvalid,
            s_axis_tready => vid_yuyv_tready, s_axis_tlast => vid_yuyv_tlast,
            s_axis_tuser => vid_yuyv_tuser, blk_valid => ibuf_blk_valid,
            blk_data => ibuf_blk_data, blk_sof => ibuf_blk_sof,
            blk_sob => ibuf_blk_sob, blk_comp => ibuf_blk_comp,
            blk_ready => ibuf_blk_ready, lines_done => ibuf_lines_done
        );

    u_dct : dct_2d
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => dct_in_valid,
            in_data => dct_in_data, in_sof => dct_in_sof,
            out_valid => dct_out_valid, out_data => dct_out_data,
            out_sof => dct_out_sof
        );

    u_quantizer : quantizer
        generic map (LITE_MODE => LITE_MODE, LITE_QUALITY => LITE_QUALITY)
        port map (
            clk => clk, rst_n => rst_int_n, comp_id => quant_comp_id,
            quality => ctrl_quality, in_valid => dct_out_valid,
            in_data => dct_out_data, in_sof => dct_out_sof,
            in_sob => dct_out_sof, out_valid => quant_out_valid,
            out_data => quant_out_data, out_sof => quant_out_sof_unused,
            out_sob => quant_out_sob, qt_rd_addr => qt_rd_addr,
            qt_rd_is_chroma => qt_rd_is_chroma, qt_rd_data => qt_rd_data
        );

    u_zigzag : zigzag_reorder
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => quant_out_valid,
            in_data => quant_out_data, in_sob => quant_out_sob,
            out_valid => zz_out_valid, out_data => zz_out_data,
            out_sob => zz_out_sob
        );

    u_huffman : huffman_encoder
        generic map (LITE_MODE => LITE_MODE)
        port map (
            clk => clk, rst_n => rst_int_n, comp_id => huff_comp_id,
            restart => restart_trigger, in_valid => zz_out_valid,
            in_data => zz_out_data, in_sob => zz_out_sob,
            out_valid => huff_out_valid, out_bits => huff_out_bits,
            out_len => huff_out_len, out_sob => huff_out_sob_unused,
            out_eob => huff_out_eob, out_ready => huff_bp_ready
        );

    u_bitpacker : bitstream_packer
        port map (
            clk => clk, rst_n => rst_int_n, in_valid => huff_out_valid,
            in_bits => huff_out_bits, in_len => huff_out_len,
            in_flush => frame_done_pulse, in_restart => restart_trigger,
            bp_ready => huff_bp_ready, out_valid => bs_out_valid,
            out_data => bs_out_data, out_last => bs_out_last,
            out_ready => bs_out_ready, byte_count => bs_byte_count
        );

    u_jfif : jfif_writer
        generic map (
            IMG_WIDTH => IMG_WIDTH, IMG_HEIGHT => IMG_HEIGHT,
            LITE_MODE => LITE_MODE, LITE_QUALITY => LITE_QUALITY,
            EXIF_ENABLE => EXIF_ENABLE, EXIF_X_RES => EXIF_X_RES,
            EXIF_Y_RES => EXIF_Y_RES, EXIF_RES_UNIT => EXIF_RES_UNIT
        )
        port map (
            clk => clk, rst_n => rst_int_n,
            frame_start => frame_start_pulse, frame_done => frame_done_pulse,
            restart_interval => ctrl_restart_interval,
            qt_rd_addr => qt_rd_addr, qt_rd_is_chroma => qt_rd_is_chroma,
            qt_rd_data => qt_rd_data, scan_valid => bs_out_valid,
            scan_data => bs_out_data, scan_last => bs_out_last,
            scan_ready => bs_out_ready, m_axis_tvalid => m_axis_jpg_tvalid,
            m_axis_tdata => m_axis_jpg_tdata, m_axis_tlast => m_axis_jpg_tlast,
            headers_done => jfif_headers_done
        );

end architecture rtl;
