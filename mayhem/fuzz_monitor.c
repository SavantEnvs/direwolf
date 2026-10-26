// Monitor-format text ("SRC>DEST,DIGI*:info") -> ax25_from_text -> APRS decoder.
#include "dw_fuzz_common.h"

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc; (void)argv;
	dw_fuzz_quiet();
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (size < 2 || size > 1024) {
	  return -1;
	}
	int strict = data[0] & 1;
	char *text = malloc(size);
	if (text == NULL) {
	  return -1;
	}
	memcpy(text, data + 1, size - 1);
	text[size - 1] = '\0';

	packet_t pp = ax25_from_text(text, strict);
	free(text);
	if (pp == NULL) {
	  return -1;
	}
	dw_fuzz_packet(pp);
	return 0;
}
