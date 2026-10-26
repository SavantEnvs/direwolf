# PHG data extension shifts by an unchecked digit (UBSan shift-exponent)

`src/decode_aprs.c:4190`: `g_height = (1 << (pdext[4] - '0')) * 10;` — `pdext[4]` is attacker-controlled, so the
exponent can be negative or exceed 31 (undefined behaviour; also `*10` can overflow). Fix: require
`pdext[3..5]` to be digits (`'0'..'9'`) before using them, as the later `pdext[6]` check already does.
