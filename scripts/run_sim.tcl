# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Vivado xsim Simulation Script for mjpegZero
# Compiles, elaborates, and runs the testbench
# ============================================================================

set script_dir [file dirname [info script]]
set proj_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file normalize [file join $proj_dir rtl]]
set sim_dir [file normalize [file join $proj_dir sim]]
set build_dir [file normalize [file join $proj_dir build/sim]]

file mkdir $build_dir

# Change to build directory for output files
cd $build_dir

# Copy test vectors to build directory so testbench can find them
file mkdir $build_dir/test_vectors
foreach f [glob -nocomplain $sim_dir/test_vectors/*] {
    file copy -force $f $build_dir/test_vectors/
}

puts "======================================================================"
puts "Compiling RTL sources..."
puts "======================================================================"

# Compile Verilog sources
set verilog_files [list \
    $rtl_dir/vendor/sim/bram_sdp.v \
    $rtl_dir/dct_1d.v \
    $rtl_dir/dct_2d.v \
    $rtl_dir/input_buffer.v \
    $rtl_dir/quantizer.v \
    $rtl_dir/zigzag_reorder.v \
    $rtl_dir/huffman_encoder.v \
    $rtl_dir/bitstream_packer.v \
    $rtl_dir/jfif_writer.v \
    $rtl_dir/axi4_lite_regs.v \
    $rtl_dir/mjpegzero_enc_top.v \
]

foreach f $verilog_files {
    puts "  Compiling: [file tail $f]"
}

exec xvlog {*}$verilog_files 2>@1

puts ""
puts "Compiling testbench..."
exec xvlog --sv $sim_dir/tb_mjpegzero_enc.sv 2>@1

puts ""
puts "======================================================================"
puts "Elaborating design..."
puts "======================================================================"
exec xelab tb_mjpegzero_enc -s sim_snapshot -timescale 1ns/1ps 2>@1

puts ""
puts "======================================================================"
puts "Running simulation..."
puts "======================================================================"
exec xsim sim_snapshot -R 2>@1

puts ""
puts "======================================================================"
puts "Simulation complete!"
puts "======================================================================"

# Check if output file was created
if {[file exists $build_dir/sim_output.jpg]} {
    set fsize [file size $build_dir/sim_output.jpg]
    puts "Output JPEG: $build_dir/sim_output.jpg ($fsize bytes)"
} else {
    puts "WARNING: No sim_output.jpg produced"
}
