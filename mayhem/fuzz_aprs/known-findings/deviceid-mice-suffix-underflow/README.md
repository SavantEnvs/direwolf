# deviceid_decode_mice reads before the start of the comment (stack-buffer-overflow)

`src/deviceid.c:707` (`deviceid_decode_mice`) computes `comment + strlen(comment) - strlen(pmice[n].suffix)`.
When the Mic-E comment is shorter than a table suffix the pointer lands before the buffer and
`strncmp_z` reads out of bounds (ASan: stack-buffer-overflow in `strncmp`, reached from
`aprs_mic_e` -> `decode_aprs`). Any received Mic-E packet with a short comment triggers it.

Fix: skip the suffix comparison when `strlen(comment) < strlen(suffix)`.
Reproduce: `/mayhem/fuzz_aprs-standalone mayhem/fuzz_aprs/known-findings/deviceid-mice-suffix-underflow/repro`
(or `-runs=1 repro` with the libFuzzer build).
