# phg_data_extension: (int)round(log2(height/10.0)) with height == 0 (UBSan float-cast-overflow)

`src/encode_aprs.c:315`: `height == 0` gives `log2(0) = -inf`, cast to `int` is undefined. Reached from
`encode_position`/`encode_object` whenever power or gain is set but height is 0. Fix: treat height <= 0
like the compressed path does (`height = 20` default) or clamp before the cast.
