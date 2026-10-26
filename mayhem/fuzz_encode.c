// Structured fuzz input -> APRS encoders (position, object, message) and lat/long formatters,
// then the encoded text is parsed back through ax25_from_text + the APRS decoder.
#include "dw_fuzz_common.h"

#include <math.h>
#include <time.h>

#include "encode_aprs.h"
#include "latlong.h"

typedef struct {
	double lat, lon;
	int64_t thyme;
	float freq, tone, offset;
	int32_t alt_ft, power, height, gain, course, speed;
	uint8_t flags;
	uint8_t ambiguity;
	uint8_t symtab, symbol;
	uint8_t dir_len;
	uint8_t name_len;
	uint8_t id_len;
	uint8_t text_len;
} fuzz_params_t;

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc; (void)argv;
	dw_fuzz_quiet();
	return 0;
}

// Copy up to n bytes from the input into a NUL-terminated string.
static char *take_str(const uint8_t **p, const uint8_t *end, size_t n)
{
	size_t avail = (size_t)(end - *p);
	if (n > avail) n = avail;
	char *s = malloc(n + 1);
	if (s == NULL) abort();
	memcpy(s, *p, n);
	s[n] = '\0';
	*p += n;
	return s;
}

static void roundtrip(const char *info)
{
	char line[1024];
	snprintf(line, sizeof(line), "N0CALL>APDW18:%s", info);
	packet_t pp = ax25_from_text(line, 0);
	if (pp != NULL) {
	  dw_fuzz_packet(pp);
	}
}

// The encoders take validated numeric inputs (config file / GPS fix); keep the fuzzed values in the
// domain the callers guarantee so findings are real encoder defects, not float->int overflow noise.
static double clampd(double v, double lo, double hi)
{
	if (!isfinite(v)) return 0;
	return v < lo ? lo : v > hi ? hi : v;
}

// Below range reads as "not provided": G_UNKNOWN where callers use it, 0 for fields whose "none" is 0.
static int clampi(int32_t v, int32_t lo, int32_t hi, int32_t none)
{
	if (v < lo) return none;
	return v > hi ? hi : v;
}

static float clampf(float v, float lo, float hi, float none)
{
	if (!isfinite(v) || v < lo) return none;
	return v > hi ? hi : v;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_params_t prm;
	if (size < sizeof(prm)) {
	  return -1;
	}
	memcpy(&prm, data, sizeof(prm));
	prm.lat = clampd(prm.lat, -90.0, 90.0);
	prm.lon = clampd(prm.lon, -180.0, 180.0);
	prm.alt_ft = clampi(prm.alt_ft, -100000, 1000000, G_UNKNOWN);
	prm.power = clampi(prm.power, 0, 9999, 0);
	prm.height = clampi(prm.height, 0, 99999, 0);
	prm.gain = clampi(prm.gain, 0, 99, 0);
	prm.course = clampi(prm.course, 0, 360, G_UNKNOWN);
	prm.speed = clampi(prm.speed, 0, 9999, 0);
	prm.freq = clampf(prm.freq, 0, 9999, 0);
	prm.tone = clampf(prm.tone, 0, 999, G_UNKNOWN);
	prm.offset = clampf(prm.offset, -9.99f, 9.99f, G_UNKNOWN);
	const uint8_t *p = data + sizeof(prm);
	const uint8_t *end = data + size;

	char *dir = take_str(&p, end, prm.dir_len & 7);
	char *name = take_str(&p, end, prm.name_len & 15);
	char *id = take_str(&p, end, prm.id_len & 7);
	char *text = take_str(&p, end, (size_t)(prm.text_len & 0x7f) + (size_t)(end - p) / 4);
	char *comment = take_str(&p, end, (size_t)(end - p));

	char sl[16], so[16];
	latitude_to_str(prm.lat, prm.ambiguity % 6, sl);
	longitude_to_str(prm.lon, prm.ambiguity % 6, so);
	latitude_to_comp_str(prm.lat, sl);
	longitude_to_comp_str(prm.lon, so);

	char out[512];
	if (encode_position(prm.flags & 1, (prm.flags >> 1) & 1, prm.lat, prm.lon, prm.ambiguity % 6, prm.alt_ft,
		(char)prm.symtab, (char)prm.symbol, prm.power, prm.height, prm.gain, dir,
		prm.course, prm.speed, prm.freq, prm.tone, prm.offset, comment, out, sizeof(out)) > 0) {
	  roundtrip(out);
	}
	if (encode_object(name, (prm.flags >> 2) & 1, (time_t)prm.thyme, prm.lat, prm.lon, prm.ambiguity % 6,
		(char)prm.symtab, (char)prm.symbol, prm.power, prm.height, prm.gain, dir,
		prm.course, prm.speed, prm.freq, prm.tone, prm.offset, comment, out, sizeof(out)) > 0) {
	  roundtrip(out);
	}
	if (encode_message(name, text, id, out, sizeof(out)) > 0) {
	  roundtrip(out);
	}

	free(dir); free(name); free(id); free(text); free(comment);
	return 0;
}
