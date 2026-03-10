# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# hw_test_a7.tcl — Program A7-100T bitstream and run encode test
# Usage: vivado -mode batch -source scripts/hw_test_a7.tcl -tclargs <in.yuyv> <out.jpg>
#   Defaults: test_720p.yuyv → hw_test_a7.jpg

set repo_root [file normalize [file join [file dirname [info script]] ..]]

# Source host.tcl procs without triggering its entry point
set saved_argv $argv
set argv {}
source [file join $repo_root example_proj/common/python/host.tcl]
set argv $saved_argv

# Parse args: [in.yuyv] [out.jpg]
set in_yuyv  [file join $repo_root test_720p.yuyv]
set out_jpg  [file join $repo_root hw_test_a7.jpg]
if {[llength $saved_argv] >= 1} { set in_yuyv [lindex $saved_argv 0] }
if {[llength $saved_argv] >= 2} { set out_jpg [lindex $saved_argv 1] }

# Connect, program, encode
hw_connect
cmd_program [file join $repo_root example_proj/arty_a7_100t/build/arty_a7_demo.bit]
cmd_encode  $in_yuyv $out_jpg

# Quick sanity: check first 2 bytes of output = FFD8 (SOI)
set fd [open $out_jpg rb]
binary scan [read $fd 2] H4 hdr
close $fd
if {$hdr eq "ffd8"} {
    puts "SOI marker present (FFD8)"
} else {
    puts "WARNING: SOI marker missing (got $hdr)"
}

# Check last 2 bytes = FFD9 (EOI)
set fd [open $out_jpg rb]
seek $fd -2 end
binary scan [read $fd 2] H4 trailer
close $fd
if {$trailer eq "ffd9"} {
    puts "EOI marker present (FFD9)"
} else {
    puts "WARNING: EOI marker missing (got $trailer)"
}

set fsize [file size $out_jpg]
puts "Output file: $out_jpg ($fsize bytes)"
