-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity synth_timing_wrapper is
    generic (
        LITE_MODE    : natural := 1;
        LITE_QUALITY : natural := 95;
        IMG_WIDTH    : natural := 1280;
        IMG_HEIGHT   : natural := 720;
        RGB_INPUT    : natural := 0;
        VID_DATA_W   : natural := 16
    );
    port (
        clk   : in  std_logic;
        rst_n : in  std_logic;

        vid_tdata  : in  std_logic_vector(VID_DATA_W-1 downto 0);
        vid_tvalid : in  std_logic;
        vid_tready : out std_logic;
        vid_tlast  : in  std_logic;
        vid_tuser  : in  std_logic;

        jpg_tvalid : out std_logic;
        jpg_tdata  : out std_logic_vector(7 downto 0);
        jpg_tlast  : out std_logic;

        axi_awaddr  : in  std_logic_vector(4 downto 0);
        axi_awvalid : in  std_logic;
        axi_awready : out std_logic;
        axi_wdata   : in  std_logic_vector(31 downto 0);
        axi_wstrb   : in  std_logic_vector(3 downto 0);
        axi_wvalid  : in  std_logic;
        axi_wready  : out std_logic;
        axi_bresp   : out std_logic_vector(1 downto 0);
        axi_bvalid  : out std_logic;
        axi_bready  : in  std_logic;
        axi_araddr  : in  std_logic_vector(4 downto 0);
        axi_arvalid : in  std_logic;
        axi_arready : out std_logic;
        axi_rdata   : out std_logic_vector(31 downto 0);
        axi_rresp   : out std_logic_vector(1 downto 0);
        axi_rvalid  : out std_logic;
        axi_rready  : in  std_logic
    );
end entity synth_timing_wrapper;

architecture rtl of synth_timing_wrapper is

    component mjpegzero_enc_top is
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
    end component;

    signal vid_tdata_r  : std_logic_vector(VID_DATA_W-1 downto 0);
    signal vid_tvalid_r : std_logic;
    signal vid_tlast_r  : std_logic;
    signal vid_tuser_r  : std_logic;

    signal axi_awaddr_r  : std_logic_vector(4 downto 0);
    signal axi_awvalid_r : std_logic;
    signal axi_wdata_r   : std_logic_vector(31 downto 0);
    signal axi_wstrb_r   : std_logic_vector(3 downto 0);
    signal axi_wvalid_r  : std_logic;
    signal axi_bready_r  : std_logic;
    signal axi_araddr_r  : std_logic_vector(4 downto 0);
    signal axi_arvalid_r : std_logic;
    signal axi_rready_r  : std_logic;

    signal vid_tready_w  : std_logic;
    signal jpg_tvalid_w  : std_logic;
    signal jpg_tdata_w   : std_logic_vector(7 downto 0);
    signal jpg_tlast_w   : std_logic;
    signal axi_awready_w : std_logic;
    signal axi_wready_w  : std_logic;
    signal axi_bresp_w   : std_logic_vector(1 downto 0);
    signal axi_bvalid_w  : std_logic;
    signal axi_arready_w : std_logic;
    signal axi_rdata_w   : std_logic_vector(31 downto 0);
    signal axi_rresp_w   : std_logic_vector(1 downto 0);
    signal axi_rvalid_w  : std_logic;

begin

    process (clk)
    begin
        if rising_edge(clk) then
            vid_tdata_r <= vid_tdata;
            vid_tvalid_r <= vid_tvalid;
            vid_tlast_r <= vid_tlast;
            vid_tuser_r <= vid_tuser;

            axi_awaddr_r <= axi_awaddr;
            axi_awvalid_r <= axi_awvalid;
            axi_wdata_r <= axi_wdata;
            axi_wstrb_r <= axi_wstrb;
            axi_wvalid_r <= axi_wvalid;
            axi_bready_r <= axi_bready;
            axi_araddr_r <= axi_araddr;
            axi_arvalid_r <= axi_arvalid;
            axi_rready_r <= axi_rready;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            vid_tready <= vid_tready_w;
            jpg_tvalid <= jpg_tvalid_w;
            jpg_tdata <= jpg_tdata_w;
            jpg_tlast <= jpg_tlast_w;
            axi_awready <= axi_awready_w;
            axi_wready <= axi_wready_w;
            axi_bresp <= axi_bresp_w;
            axi_bvalid <= axi_bvalid_w;
            axi_arready <= axi_arready_w;
            axi_rdata <= axi_rdata_w;
            axi_rresp <= axi_rresp_w;
            axi_rvalid <= axi_rvalid_w;
        end if;
    end process;

    u_dut : mjpegzero_enc_top
        generic map (
            IMG_WIDTH => IMG_WIDTH,
            IMG_HEIGHT => IMG_HEIGHT,
            LITE_MODE => LITE_MODE,
            LITE_QUALITY => LITE_QUALITY,
            RGB_INPUT => RGB_INPUT,
            VID_DATA_W => VID_DATA_W
        )
        port map (
            clk => clk,
            rst_n => rst_n,

            s_axis_vid_tdata => vid_tdata_r,
            s_axis_vid_tvalid => vid_tvalid_r,
            s_axis_vid_tready => vid_tready_w,
            s_axis_vid_tlast => vid_tlast_r,
            s_axis_vid_tuser => vid_tuser_r,

            m_axis_jpg_tvalid => jpg_tvalid_w,
            m_axis_jpg_tdata => jpg_tdata_w,
            m_axis_jpg_tlast => jpg_tlast_w,

            s_axi_awaddr => axi_awaddr_r,
            s_axi_awvalid => axi_awvalid_r,
            s_axi_awready => axi_awready_w,
            s_axi_wdata => axi_wdata_r,
            s_axi_wstrb => axi_wstrb_r,
            s_axi_wvalid => axi_wvalid_r,
            s_axi_wready => axi_wready_w,
            s_axi_bresp => axi_bresp_w,
            s_axi_bvalid => axi_bvalid_w,
            s_axi_bready => axi_bready_r,
            s_axi_araddr => axi_araddr_r,
            s_axi_arvalid => axi_arvalid_r,
            s_axi_arready => axi_arready_w,
            s_axi_rdata => axi_rdata_w,
            s_axi_rresp => axi_rresp_w,
            s_axi_rvalid => axi_rvalid_w,
            s_axi_rready => axi_rready_r
        );

end architecture rtl;
