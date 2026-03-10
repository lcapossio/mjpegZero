# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# host.tcl — Vivado Hardware Manager script for Arty S7-50 MJPEG demo
#
# Runs inside Vivado (batch or Tcl console) and communicates with the FPGA
# via the Xilinx JTAG-to-AXI Master IP.
#
# Usage (batch mode, called by demo.py):
#   vivado -mode batch -source host.tcl \
#          -tclargs <command> [args...]
#
# Commands:
#   program  <bitstream.bit>
#   encode   <in.yuyv> <out.jpg>
#   encode8  <dir_with_8_yuyv_files> <out_dir>
#   status
#   reset
#
# AXI address map (matches arty_s7_top.v):
#   0x0000_0000  PIXEL_PORT  (write burst)
#   0x0200_0000  DEMO_CTRL   bit0=start, bit1=reset
#   0x0200_0004  DEMO_STATUS bit0=enc_done
#   0x0200_0008  JPEG_SIZE   [17:0]
#   0x0300_0000  JPEG_PORT   (read burst)

# ============================================================================
# Constants
# ============================================================================
set AXI_PIXEL  0x00000000
set AXI_CTRL   0x02000000
set AXI_STATUS 0x02000000  ;# read: [0]=enc_done  (same addr as CTRL write)
set AXI_SIZE   0x02000004  ;# read: [17:0]=jpeg_byte_cnt
set AXI_JPEG   0x03000000

set IMG_W      1280
set IMG_H      720
set FRAME_BYTES [expr {$IMG_W * $IMG_H * 2}]   ;# 1 843 200
set JPEG_MAX   262144                            ;# 256 KB

set BURST_WORDS 256   ;# AXI4 max burst = 256 beats (Vivado enforces this hard limit)

# ============================================================================
# Hardware helpers
# ============================================================================

proc hw_connect {} {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    open_hw_target
    # Refresh device so Vivado discovers debug cores (incl. JTAG-to-AXI)
    refresh_hw_device [lindex [get_hw_devices] 0]
    # Report actual TCK if property exists (Digilent onboard cable may not expose it)
    set tgt [current_hw_target]
    if {[lsearch [list_property $tgt] PARAM.JTAG_TCK_FREQ] >= 0} {
        set_property PARAM.JTAG_TCK_FREQ 30000000 $tgt
        puts "JTAG TCK: [expr {[get_property PARAM.JTAG_TCK_FREQ $tgt] / 1000000.0}] MHz"
    } else {
        puts "JTAG TCK: auto (cable does not expose PARAM.JTAG_TCK_FREQ)"
    }
    puts "Hardware connected: $tgt"
}

proc hw_axi {} {
    set axil [get_hw_axis -quiet]
    if {[llength $axil] == 0} {
        error "No JTAG-to-AXI found. Is the bitstream programmed?"
    }
    refresh_hw_axi [lindex $axil 0]
    return [lindex $axil 0]
}

proc axi_write_word {axi addr data} {
    set txn [create_hw_axi_txn tmp_wr $axi \
        -type write -address [format "0x%08x" $addr] -len 1 \
        -data [format "%08x" $data] -force]
    run_hw_axi -quiet $txn
    delete_hw_axi_txn $txn
}

proc axi_read_word {axi addr} {
    set txn [create_hw_axi_txn tmp_rd $axi \
        -type read -address [format "0x%08x" $addr] -len 1 -force]
    run_hw_axi -quiet $txn
    set val [get_property DATA $txn]
    delete_hw_axi_txn $txn
    return [expr {"0x$val"}]
}

# Write a list of 32-bit hex words in bursts of $BURST_WORDS
proc axi_write_burst {axi base_addr words} {
    global BURST_WORDS
    set n [llength $words]
    set addr $base_addr
    for {set i 0} {$i < $n} {incr i $BURST_WORDS} {
        set chunk [lrange $words $i [expr {$i + $BURST_WORDS - 1}]]
        set len   [llength $chunk]
        set txn [create_hw_axi_txn burst_wr $axi \
            -type write -address [format "0x%08x" $addr] \
            -len $len \
            -data [join $chunk " "] -force]
        run_hw_axi -quiet $txn
        delete_hw_axi_txn $txn
        incr addr [expr {$len * 4}]
    }
}

# Read $n_words 32-bit words starting at $base_addr
proc axi_read_burst {axi base_addr n_words} {
    global BURST_WORDS
    set result {}
    set addr $base_addr
    set rem  $n_words
    while {$rem > 0} {
        set len [expr {min($rem, $BURST_WORDS)}]
        set txn [create_hw_axi_txn burst_rd $axi \
            -type read -address [format "0x%08x" $addr] -len $len -force]
        run_hw_axi -quiet $txn
        # Vivado returns burst DATA with the last word first (reversed order).
        # Strip spaces, split into 8-char (32-bit) words, then un-reverse.
        set raw [string map {" " ""} [get_property DATA $txn]]
        delete_hw_axi_txn $txn
        set chunk {}
        set rlen [string length $raw]
        for {set j 0} {$j < $rlen} {incr j 8} {
            lappend chunk [string range $raw $j [expr {$j+7}]]
        }
        # Vivado returns burst DATA in reversed word order (last word first).
        # For the last (partial) burst, Vivado may prepend stale words at the
        # START of the chunk (chunk[0..extra-1]).  Take the LAST $len elements
        # to discard any stale prefix before un-reversing.
        set nchunk [llength $chunk]
        puts "  \[DEBUG burst\] addr=[format 0x%08x $addr] len=$len nchunk=$nchunk rem=$rem"
        if {$nchunk > 0} {
            puts "  \[DEBUG burst\] chunk\[0..2\]=[lrange $chunk 0 2]"
            puts "  \[DEBUG burst\] chunk\[end-2..end\]=[lrange $chunk end-2 end]"
        }
        foreach w [lreverse [lrange $chunk [expr {$nchunk - $len}] end]] { lappend result $w }
        incr addr [expr {$len * 4}]
        incr rem  [expr {-$len}]
    }
    return $result
}

# ============================================================================
# Binary file helpers
# ============================================================================

# Read binary file, return list of 32-bit hex strings (LE byte order).
# Uses binary scan i* for bulk C-level conversion — ~20x faster than byte loop.
proc read_yuyv {path} {
    set fd [open $path rb]
    set data [read $fd]
    close $fd
    # Pad to 4-byte boundary
    set rem [expr {[string length $data] % 4}]
    if {$rem} { append data [string repeat "\x00" [expr {4 - $rem}]] }
    # 'i' = little-endian int32; on LE host this reads bytes as-is into int value
    binary scan $data i* ints
    # Format each int as 8-char hex (MSB first → [31:0] for AXI write)
    return [lmap v $ints { format "%08x" [expr {$v & 0xFFFFFFFF}] }]
}

# Write JPEG bytes from list of 32-bit hex words (LE) to file, trim to n_bytes.
# Each AXI word is MSB-first hex: "AABBCCDD" means value 0xAABBCCDD, stored LE
# in BRAM as bytes DD CC BB AA.  Byte-swap each word before writing.
proc write_jpeg {path hex_words n_bytes} {
    set le_hex ""
    foreach w $hex_words {
        append le_hex \
            [string range $w 6 7] \
            [string range $w 4 5] \
            [string range $w 2 3] \
            [string range $w 0 1]
    }
    set bin [binary format H* $le_hex]
    set fd [open $path wb]
    puts -nonewline $fd [string range $bin 0 [expr {$n_bytes - 1}]]
    close $fd
}

# ============================================================================
# High-level commands
# ============================================================================

proc cmd_program {bitfile} {
    set dev [lindex [get_hw_devices] 0]
    set_property PROGRAM.FILE $bitfile $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    puts "Programmed: $bitfile"
    # Allow encoder init to complete (~10 ms)
    after 50
}

proc cmd_reset {} {
    global AXI_CTRL
    set axi [hw_axi]
    axi_write_word $axi $AXI_CTRL 0x2   ;# bit1 = reset
    after 1
    axi_write_word $axi $AXI_CTRL 0x0
    puts "FPGA demo state reset."
}

proc cmd_status {} {
    global AXI_STATUS AXI_SIZE
    set axi [hw_axi]
    set st   [axi_read_word $axi $AXI_STATUS]
    set sz   [axi_read_word $axi $AXI_SIZE]
    puts "STATUS: [expr {$st & 1}] (1=done)   JPEG_SIZE: $sz bytes"
}

proc cmd_encode {yuyv_path jpeg_path} {
    global AXI_PIXEL AXI_CTRL AXI_STATUS AXI_SIZE AXI_JPEG FRAME_BYTES JPEG_MAX

    set axi [hw_axi]

    # 1. Reset state
    axi_write_word $axi $AXI_CTRL 0x2
    after 1
    axi_write_word $axi $AXI_CTRL 0x0

    # 2. Issue START before upload — pixel FIFO is only 64 words deep, so the
    #    encoder must drain it concurrently (enc_running=1) or m_wready stalls.
    axi_write_word $axi $AXI_CTRL 0x1

    # 3. Parse and upload YUYV pixels while encoder drains the FIFO in real-time
    puts -nonewline "  Parsing [file tail $yuyv_path]... "
    flush stdout
    set t0 [clock milliseconds]
    set words [read_yuyv $yuyv_path]
    set t1 [clock milliseconds]
    puts "parsed in [expr {$t1-$t0}] ms ([expr {[llength $words]}] words)"
    puts -nonewline "  Uploading ($FRAME_BYTES bytes over JTAG-AXI)... "
    flush stdout
    axi_write_burst $axi $AXI_PIXEL $words
    set t2 [clock milliseconds]
    set upload_ms [expr {$t2-$t1}]
    puts "[expr {$upload_ms}] ms  ([expr {int($FRAME_BYTES * 1000.0 / max($upload_ms,1) / 1024)}] KB/s)"

    # 4. Poll STATUS until enc_done
    puts -nonewline "  Waiting for encode... "
    flush stdout
    set deadline [expr {[clock milliseconds] + 5000}]
    while {([clock milliseconds] < $deadline)} {
        set st [axi_read_word $axi $AXI_STATUS]
        if {$st & 1} break
        after 10
    }
    if {!($st & 1)} {
        puts "TIMEOUT — encoding did not complete"
        return 0
    }
    puts "done."

    # 5. Read JPEG
    set n_bytes [axi_read_word $axi $AXI_SIZE]
    if {$n_bytes == 0 || $n_bytes > $JPEG_MAX} {
        puts "ERROR: invalid JPEG size $n_bytes"
        return 0
    }
    set n_words [expr {($n_bytes + 3) / 4}]
    puts -nonewline "  Downloading JPEG ($n_bytes bytes)... "
    flush stdout
    set t2 [clock milliseconds]
    set hex_words [axi_read_burst $axi $AXI_JPEG $n_words]
    set t3 [clock milliseconds]
    puts "[expr {$t3-$t2}] ms"

    write_jpeg $jpeg_path $hex_words $n_bytes
    puts "  Saved: $jpeg_path"
    return 1
}

proc cmd_probe {} {
    global AXI_JPEG
    set axi [hw_axi]
    set base $AXI_JPEG
    puts "=== Single-word reads at JPEG_BASE+0x400 (word 256+) ==="
    for {set i 0} {$i < 8} {incr i} {
        set addr [expr {$base + 0x400 + $i*4}]
        set val [axi_read_word $axi $addr]
        puts "  \[[format 0x%08x $addr]\] = [format 0x%08x $val]"
    }
    puts "=== Burst read: 8 words from JPEG_BASE+0x400 ==="
    set words [axi_read_burst $axi [expr {$base + 0x400}] 8]
    set i 0
    foreach w $words {
        set addr [expr {$base + 0x400 + $i*4}]
        puts "  \[[format 0x%08x $addr]\] = $w"
        incr i
    }
}

proc cmd_encode8 {yuyv_dir out_dir} {
    file mkdir $out_dir
    set files [lsort [glob -nocomplain [file join $yuyv_dir *.yuyv]]]
    if {[llength $files] == 0} {
        puts "No .yuyv files found in $yuyv_dir"
        return
    }
    set n 0
    foreach f $files {
        set stem [file rootname [file tail $f]]
        set out  [file join $out_dir "${stem}.jpg"]
        puts "Frame [incr n]/[llength $files]: [file tail $f]"
        cmd_encode $f $out
    }
    puts "Done: $n frames encoded to $out_dir"
}

# ============================================================================
# Entry point
# ============================================================================
set argv_list $argv
if {[llength $argv_list] == 0} {
    puts "host.tcl: no command given. Run from demo.py or Vivado Tcl console."
    puts "Commands: program <bit>  encode <in.yuyv> <out.jpg>  encode8 <dir> <out_dir>  status  reset"
} else {
    hw_connect
    set cmd [lindex $argv_list 0]
    switch $cmd {
        "program" { cmd_program [lindex $argv_list 1] }
        "encode"  { cmd_encode  [lindex $argv_list 1] [lindex $argv_list 2] }
        "encode8" { cmd_encode8 [lindex $argv_list 1] [lindex $argv_list 2] }
        "status"  { cmd_status }
        "reset"   { cmd_reset }
        "probe"   { cmd_probe }
        default   { puts "Unknown command: $cmd" }
    }
}
