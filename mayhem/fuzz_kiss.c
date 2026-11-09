// Byte stream from a KISS client -> kiss_rec_byte (SLIP framing) -> kiss_process_msg -> AX.25 + transmit queue.
#include "direwolf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "audio.h"
#include "ax25_pad.h"
#include "config.h"
#include "kiss_frame.h"
#include "kissnet.h"
#include "textcolor.h"
#include "tq.h"

static struct audio_s audio_config;
static struct misc_config_s misc_config;

static void sendfun(int chan, int kiss_cmd, unsigned char *fbuf, int flen,
		struct kissport_status_s *kps, int client)
{
	(void)chan; (void)kiss_cmd; (void)fbuf; (void)flen; (void)kps; (void)client;
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc; (void)argv;
	// dw_printf writes to stdout: use a small in-memory stream (writes past its end fail) to stay quiet.
	static char sink[4096];
	FILE *f = fmemopen(sink, sizeof(sink), "w");
	if (f == NULL) {
	  abort();
	}
	stdout = f;
	text_color_init(0);
	for (int c = 0; c < MAX_RADIO_CHANS; c++) {
	  audio_config.chan_medium[c] = MEDIUM_RADIO;
	}
	kiss_frame_init(&audio_config);
	kissnet_init(&misc_config);
	tq_init(&audio_config);
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static kiss_frame_t kf;
	memset(&kf, 0, sizeof(kf));

	for (size_t i = 0; i < size; i++) {
	  kiss_rec_byte(&kf, data[i], 0, NULL, -1, sendfun);
	}

	// Frames the client asked us to transmit pile up in the queue; empty it every run.
	for (int c = 0; c < MAX_RADIO_CHANS; c++) {
	  for (int p = 0; p < TQ_NUM_PRIO; p++) {
	    packet_t pp;
	    while ((pp = tq_remove(c, p)) != NULL) {
	      ax25_delete(pp);
	    }
	  }
	}
	return 0;
}
