# synth_postsim_vtpg.tcl - synthesize mjpegzero_enc_top at 1280x16 LITE q75 and
# export a funcsim netlist, for feeding REAL vtpgZero colorbars into the netlist
# (faithful sim-vs-synth contrast test).
set part xc7a100tcsg324-1
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ..]]
set rtl_dir    [file join $proj_dir rtl]
set src_files [list \
    $rtl_dir/bram_sdp.v $rtl_dir/dct_1d.v $rtl_dir/dct_2d.v $rtl_dir/input_buffer.v \
    $rtl_dir/quantizer.v $rtl_dir/zigzag_reorder.v $rtl_dir/huffman_encoder.v \
    $rtl_dir/bitstream_packer.v $rtl_dir/jfif_writer.v $rtl_dir/axi4_lite_regs.v \
    $rtl_dir/mjpegzero_enc_top.v ]
set output_dir [file join $proj_dir build postsim_vtpg]
file mkdir $output_dir
set xdc_file [file join $output_dir timing.xdc]
set fp [open $xdc_file w]; puts $fp "create_clock -period 10.0 -name clk \[get_ports clk\]"; close $fp
read_verilog $src_files
read_xdc $xdc_file
synth_design -top mjpegzero_enc_top -part $part \
    -generic "LITE_MODE=1 LITE_QUALITY=75 IMG_WIDTH=1280 IMG_HEIGHT=16" \
    -flatten_hierarchy rebuilt -directive PerformanceOptimized -verilog_define XILINX_7SERIES
write_checkpoint -force [file join $output_dir post_synth.dcp]
write_verilog -mode funcsim -force [file join $output_dir funcsim.v]
puts "POSTSIM-VTPG NETLIST: $output_dir/funcsim.v  (1280x16 LITE q75)"
