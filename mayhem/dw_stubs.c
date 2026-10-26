/* direwolf.c (the daemon's main) is not linked into the harnesses; recv.c calls back into it. */
#include "direwolf.h"
#include "ax25_pad.h"
#include "hdlc_rec2.h"

void app_process_rec_packet (int chan, int subchan, int slice, packet_t pp, alevel_t alevel, fec_type_t fec_type, retry_t retries, char *spectrum)
{
	(void)chan; (void)subchan; (void)slice; (void)alevel; (void)fec_type; (void)retries; (void)spectrum;
	ax25_delete (pp);
}
