// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// dump_baseline — extract the Lattice reference descriptors as golden bytes
//
// Compiles the baseline's lsc_usb_desc.h (unmodified, in place) on the host
// and writes each descriptor object's exact bytes to golden/*.bin. These
// files are the truth that check_descriptors.c holds fw/uvc_descriptors.c
// to, byte for byte, for the YUY2 configuration.
// -----------------------------------------------------------------------------

#include <stdio.h>
#include <stdlib.h>

#include "lsc_usb_desc.h"   // baseline, included from its own tree

static void w(const char *name, const void *p, size_t len)
{
    FILE *f = fopen(name, "wb");
    if (!f) { perror(name); exit(1); }
    fwrite(p, 1, len, f);
    fclose(f);
    printf("%-28s %4zu bytes\n", name, len);
}

int main(void)
{
    w("golden/dev_hs.bin",  &u20_device_desc,       sizeof u20_device_desc);
    w("golden/dev_ss.bin",  &u30_device_desc,       sizeof u30_device_desc);
    w("golden/dev_qual.bin",&device_qual_desc,      sizeof device_qual_desc);
    w("golden/bos.bin",     &bos_desc,              sizeof bos_desc);
    w("golden/cfg_hs.bin",  &yuy2_bulk_cfg_desc_hs, sizeof yuy2_bulk_cfg_desc_hs);
    w("golden/cfg_ss.bin",  &yuy2_bulk_cfg_desc_ss, sizeof yuy2_bulk_cfg_desc_ss);
    return 0;
}
