// Shared setup + packet pipeline for the libFuzzer harnesses.
#ifndef DW_FUZZ_COMMON_H
#define DW_FUZZ_COMMON_H

#include "direwolf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "ax25_pad.h"
#include "decode_aprs.h"
#include "deviceid.h"
#include "symbols.h"
#include "textcolor.h"

// dw_printf writes everything to stdout. Point stdout at a small in-memory stream (writes past its end
// just fail) so the fuzzing loop is quiet without touching any file.
static char dw_fuzz_sink[4096];

static void dw_fuzz_mute_stdout(void)
{
	FILE *f = fmemopen(dw_fuzz_sink, sizeof(dw_fuzz_sink), "w");
	if (f == NULL) {
	  abort();
	}
	stdout = f;
}

static void dw_fuzz_quiet(void)
{
	dw_fuzz_mute_stdout();
	text_color_init(0);
	deviceid_init();
	symbols_init();
}

// Exercise the APRS decoder and the AX.25 accessors on a parsed packet, then free it.
static void dw_fuzz_packet(packet_t pp)
{
	char addrs[512];
	unsigned char *pinfo;
	unsigned char packed[AX25_MAX_PACKET_LEN];
	decode_aprs_t A;
	cmdres_t cr;
	char desc[80];
	int pf, nr, ns;

	ax25_format_addrs(pp, addrs);
	int info_len = ax25_get_info(pp, &pinfo);
	ax25_safe_print((char *)pinfo, info_len, 1);

	memset(&A, 0, sizeof(A));
	decode_aprs(&A, pp, 0, NULL);
	decode_aprs_print(&A);

	(void)ax25_check_addresses(pp);
	(void)ax25_frame_type(pp, &cr, desc, &pf, &nr, &ns);
	(void)ax25_is_aprs(pp);
	(void)ax25_get_dti(pp);
	(void)ax25_dedupe_crc(pp);
	(void)ax25_m_m_crc(pp);
	(void)ax25_pack(pp, packed);
	ax25_delete(pp);
}

#endif
