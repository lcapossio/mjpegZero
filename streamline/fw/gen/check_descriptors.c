// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// check_descriptors — byte-identity gate for the descriptor set
//
// Compiles fw/uvc_descriptors.c (the typed-struct descriptor set) on the
// host and compares every artifact byte-for-byte against golden/*.bin
// extracted from the unmodified Lattice baseline by dump_baseline.c.
// Exit 0 = all identical.
// -----------------------------------------------------------------------------

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uvc_descriptors.h"

static int fails;

static void check(const char *name, const void *got, size_t got_len)
{
    char path[256];
    snprintf(path, sizeof path, "golden/%s", name);

    FILE *f = fopen(path, "rb");
    if (!f) { printf("  MISS %-14s (no golden file)\n", name); fails++; return; }
    uint8_t gold[4096];
    size_t gold_len = fread(gold, 1, sizeof gold, f);
    fclose(f);

    if (gold_len == got_len && memcmp(gold, got, got_len) == 0) {
        printf("  OK   %-14s %zu bytes\n", name, got_len);
        return;
    }
    fails++;
    printf("  FAIL %-14s struct %zu vs golden %zu bytes\n", name, got_len, gold_len);
    for (size_t i = 0; i < got_len && i < gold_len; i++)
        if (((const uint8_t *)got)[i] != gold[i]) {
            printf("         first diff at byte %zu: struct 0x%02X golden 0x%02X\n",
                   i, ((const uint8_t *)got)[i], gold[i]);
            break;
        }
}

int main(void)
{
    const uvc_descriptors_t *d = &uvc_descriptors_yuy2;
    check("dev_hs.bin",   d->dev_desc_hs,   d->dev_desc_hs_len);
    check("dev_ss.bin",   d->dev_desc_ss,   d->dev_desc_ss_len);
    check("dev_qual.bin", d->dev_qual_desc, d->dev_qual_desc_len);
    check("bos.bin",      d->bos_desc,      d->bos_desc_len);
    check("cfg_hs.bin",   d->cfg_desc_hs,   d->cfg_desc_hs_len);
    check("cfg_ss.bin",   d->cfg_desc_ss,   d->cfg_desc_ss_len);
    return fails ? 1 : 0;
}
