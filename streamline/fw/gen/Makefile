# SPDX-License-Identifier: Apache-2.0
# fw/gen — byte-identity gate for the typed-struct descriptor set
#
#   make golden   extract golden bytes from the unmodified Lattice baseline
#   make check    compile fw/uvc_descriptors.c on the host and byte-compare
#                 every artifact against golden/
#   make clean    remove transients (golden/ is kept: it is the truth)
#
# The baseline tree location can be overridden: make BASELINE=/path golden

BASELINE ?= ../../../../RD02306_mipi_csi_to_usb_uvc/fpga_lifcl/propelsdk/riscv_mc/src

CFLAGS = -std=c11 -Wall -Wextra -I..

.PHONY: check golden clean

check: golden
	cc $(CFLAGS) -o build_check check_descriptors.c ../uvc_descriptors.c
	./build_check
	rm -f build_check

golden: golden/.stamp

golden/.stamp: dump_baseline.c $(BASELINE)/lsc_usb_desc.h
	mkdir -p golden
	cc -o build_dump_baseline dump_baseline.c -I shim -I $(BASELINE) -Wno-pragma-pack
	./build_dump_baseline
	rm -f build_dump_baseline
	touch $@

clean:
	rm -rf build build_check build_dump_baseline dump_baseline
