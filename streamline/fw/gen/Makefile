# SPDX-License-Identifier: Apache-2.0
# fw/gen — byte-identity gate for the typed-struct descriptor set
#
#   make check    compile fw/uvc_descriptors.c on the host and byte-compare
#                 every artifact against the committed golden/ bytes
#   make golden   re-extract golden bytes from the unmodified Lattice
#                 baseline (manual; needs the RD02306 tree — override its
#                 location with make BASELINE=/path golden)
#   make clean    remove transients (golden/ is kept: it is the truth)
#
# check reads only committed files, so it runs on any machine; golden is
# the one step that reaches outside streamline/, by design.

BASELINE ?= ../../../../RD02306_mipi_csi_to_usb_uvc/fpga_lifcl/propelsdk/riscv_mc/src

CFLAGS = -std=c11 -Wall -Wextra -I..

.PHONY: check golden clean

check:
	@test -f golden/dev_hs.bin || \
	    { echo "golden/ bytes missing — run 'make golden' (needs the Lattice tree)"; exit 1; }
	cc $(CFLAGS) -o build_check check_descriptors.c ../uvc_descriptors.c
	./build_check
	rm -f build_check

golden:
	mkdir -p golden
	cc -o build_dump_baseline dump_baseline.c -I shim -I $(BASELINE) -Wno-pragma-pack
	./build_dump_baseline
	rm -f build_dump_baseline

clean:
	rm -rf build build_check build_dump_baseline dump_baseline
