# synth_for_postsim_vhdl.tcl - Synthesize VHDL mjpegzero_enc_top and export funcsim netlist
#
# Usage: vivado -mode batch -source scripts/synth_for_postsim_vhdl.tcl \
#               -tclargs [lite [quality]]
#   lite:         LITE_MODE=1, 1280x720 (default Q95)
#   lite <1-100>: LITE_MODE=1, custom quality
#
# Outputs: build/postsim_vhdl/post_synth.dcp
#          build/postsim_vhdl/funcsim.v    (for xsim functional sim)

set lite_mode    0
set lite_quality 95
set img_width    1920
set img_height   1080

if {[llength $argv] > 0 && [lindex $argv 0] eq "lite"} {
    set lite_mode    1
    set img_width    1280
    set img_height   720
    if {[llength $argv] > 1} {
        set lite_quality [lindex $argv 1]
    }
}

set part xc7s50csga324-1
set top_module mjpegzero_enc_top

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ..]]
set rtl_dir    [file join $proj_dir rtl]
set vhdl_dir   [file join $rtl_dir vhdl]

set src_files [list \
    $vhdl_dir/mjpegzero_pkg.vhd \
    $vhdl_dir/axi4_lite_regs.vhd \
    $vhdl_dir/bram_sdp.vhd \
    $vhdl_dir/input_buffer.vhd \
    $vhdl_dir/dct_1d.vhd \
    $vhdl_dir/dct_2d.vhd \
    $vhdl_dir/quantizer.vhd \
    $vhdl_dir/huffman_encoder.vhd \
    $vhdl_dir/bitstream_packer.vhd \
    $vhdl_dir/rgb_to_ycbcr.vhd \
    $vhdl_dir/zigzag_reorder.vhd \
    $vhdl_dir/jfif_writer.vhd \
    $vhdl_dir/mjpegzero_enc_top.vhd \
]

set output_dir [file join $proj_dir build postsim_vhdl]
file mkdir $output_dir

set xdc_file [file join $output_dir timing.xdc]
set fp [open $xdc_file w]
puts $fp "create_clock -period 6.667 -name clk \[get_ports clk\]"
close $fp

read_vhdl -vhdl2008 $src_files
read_xdc $xdc_file

synth_design -top $top_module -part $part \
    -generic "LITE_MODE=$lite_mode LITE_QUALITY=$lite_quality IMG_WIDTH=$img_width IMG_HEIGHT=$img_height" \
    -flatten_hierarchy rebuilt

write_checkpoint -force [file join $output_dir post_synth.dcp]

write_verilog -mode funcsim -force [file join $output_dir funcsim.v]

puts "======================================================================"
puts "VHDL POST-SYNTH NETLIST: $output_dir/funcsim.v"
puts "LITE_MODE=$lite_mode  LITE_QUALITY=$lite_quality  $img_width x $img_height"
puts "======================================================================"
