# PHG height: `(1 << n) * 10` signed overflow (UBSan)

Same site as fuzz_aprs/known-findings/phg-shift-exponent (`src/decode_aprs.c:4190`), reached through
monitor-format text. `1 << 30` times 10 overflows `int`. Fix: validate the PHG digits and widen/clamp.
