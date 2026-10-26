// AX.25 frame bytes -> ax25_from_frame -> APRS decoder (src/decode_aprs.c) and AX.25 accessors.
#include "dw_fuzz_common.h"

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc; (void)argv;
	dw_fuzz_quiet();
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (size == 0 || size > 2 * AX25_MAX_PACKET_LEN) {
	  return -1;
	}
	unsigned char *buf = malloc(size);
	if (buf == NULL) {
	  return -1;
	}
	memcpy(buf, data, size);

	alevel_t alevel;
	memset(&alevel, 0, sizeof(alevel));
	packet_t pp = ax25_from_frame(buf, (int)size, alevel);
	free(buf);
	if (pp == NULL) {
	  return -1;
	}
	dw_fuzz_packet(pp);
	return 0;
}
