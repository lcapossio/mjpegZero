# SPDX-License-Identifier: Apache-2.0
# mjpegZero — Synopsys Design Constraints for GOWIN EDA
# Target: 150 MHz (6.667 ns period)

create_clock -period 6.667 -name clk [get_ports clk]

set_input_delay  -clock clk -max 1.5 [get_ports {vid_tdata vid_tvalid vid_tlast vid_tuser}]
set_input_delay  -clock clk -max 1.5 [get_ports {axi_awaddr axi_awvalid axi_wdata axi_wstrb axi_wvalid axi_bready}]
set_input_delay  -clock clk -max 1.5 [get_ports {axi_araddr axi_arvalid axi_rready}]
set_output_delay -clock clk -max 1.5 [get_ports {jpg_tvalid jpg_tdata jpg_tlast vid_tready}]
set_output_delay -clock clk -max 1.5 [get_ports {axi_awready axi_wready axi_bresp axi_bvalid}]
set_output_delay -clock clk -max 1.5 [get_ports {axi_arready axi_rdata axi_rresp axi_rvalid}]

set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports {vid_tdata vid_tvalid vid_tlast vid_tuser}]
set_false_path -from [get_ports {axi_awaddr axi_awvalid axi_wdata axi_wstrb axi_wvalid axi_bready}]
set_false_path -from [get_ports {axi_araddr axi_arvalid axi_rready}]
set_false_path -to   [get_ports {jpg_tvalid jpg_tdata jpg_tlast vid_tready}]
set_false_path -to   [get_ports {axi_awready axi_wready axi_bresp axi_bvalid}]
set_false_path -to   [get_ports {axi_arready axi_rdata axi_rresp axi_rvalid}]
