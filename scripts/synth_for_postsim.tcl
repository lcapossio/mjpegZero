# synth_for_postsim.tcl — Synthesize mjpegzero_enc_top and export funcsim netlist
#
# Usage: vivado -mode batch -source scripts/synth_for_postsim.tcl \
#               -tclargs [full|lite] [720p|1080p|<width>x<height>] [quality]
#   lite:         LITE_MODE=1, same resolution default, fixed Q95
#   1080p lite 80: LITE_MODE=1, 1920x1080, fixed Q80
#
# Outputs: build/postsim/post_synth.dcp
#          build/postsim/funcsim.v    (for xsim functional sim)

set lite_mode    0
set lite_quality 95
set img_width    1280
set img_height   720

foreach raw_arg $argv {
    set arg [string tolower $raw_arg]
    if {$arg eq "lite" || $arg eq "fixed"} {
        set lite_mode 1
    } elseif {$arg eq "full" || $arg eq "runtime"} {
        set lite_mode 0
    } elseif {$arg eq "720p"} {
        set img_width 1280
        set img_height 720
    } elseif {$arg eq "1080p"} {
        set img_width 1920
        set img_height 1080
    } elseif {[regexp {^([0-9]+)x([0-9]+)$} $arg -> w h]} {
        set img_width $w
        set img_height $h
    } elseif {[regexp {^quality=([0-9]+)$} $arg -> q] || [regexp {^q([0-9]+)$} $arg -> q] || [regexp {^([0-9]+)$} $arg -> q]} {
        set lite_quality $q
    } else {
        puts "ERROR: unknown argument '$raw_arg'"
        exit 1
    }
}

set part xc7s50csga324-1
set top_module mjpegzero_enc_top

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ..]]
set rtl_dir    [file join $proj_dir rtl]

set src_files [list \
    $rtl_dir/bram_sdp.v \
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

set output_dir [file join $proj_dir build postsim]
file mkdir $output_dir

# Minimal XDC for clock period (required for synth_design)
set xdc_file [file join $output_dir timing.xdc]
set fp [open $xdc_file w]
puts $fp "create_clock -period 6.667 -name clk \[get_ports clk\]"
close $fp

read_verilog $src_files
read_xdc $xdc_file

synth_design -top $top_module -part $part \
    -generic "LITE_MODE=$lite_mode LITE_QUALITY=$lite_quality IMG_WIDTH=$img_width IMG_HEIGHT=$img_height" \
    -flatten_hierarchy rebuilt

write_checkpoint -force [file join $output_dir post_synth.dcp]

# Export functional simulation model (unisim blackboxes + init values baked in)
write_verilog -mode funcsim -force [file join $output_dir funcsim.v]

puts "======================================================================"
puts "POST-SYNTH NETLIST: $output_dir/funcsim.v"
puts "LITE_MODE=$lite_mode  LITE_QUALITY=$lite_quality  $img_width x $img_height"
puts "======================================================================"
