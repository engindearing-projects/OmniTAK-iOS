//
//  OmniTAKMobile-Bridging-Header.h
//  OmniTAKMobile
//
//  Bridging header — exposes C APIs to Swift.
//

#ifndef OmniTAKMobile_Bridging_Header_h
#define OmniTAKMobile_Bridging_Header_h

// Rust FFI (daemon tools)
#import "omnitak_mobile.h"

// Unishox2 — Apache-2.0 compression for Meshtastic ATAK Plugin portnum-72
// Used by TAKPacketCodec to encode/decode TAKPacket fields when is_compressed=true.
// Vendored from siara-cc/Unishox2 @ master (2d68225c), same algorithm as
// meshtastic/firmware src/mesh/compression/ (pre-#10105 drop).
#import "unishox2.h"

// Bounded entry points. `olen` is the most bytes the call may write to `out`.
// Both return the number of bytes written, a value above `olen` when the result
// does not fit, or a negative number for input that cannot be decoded.
static inline int omni_unishox2_decompress(const char *in, int len, char *out, int olen) {
    return unishox2_decompress(in, len, out, olen, USX_PSET_DFLT);
}
static inline int omni_unishox2_compress(const char *in, int len, char *out, int olen) {
    return unishox2_compress(in, len, out, olen, USX_PSET_DFLT);
}

// The library's "simple" calls take no output size and write as far as the
// compressed stream tells them to. Keep them out of Swift.
int unishox2_decompress_simple(const char *in, int len, char *out)
    __attribute__((unavailable("no output bound: use omni_unishox2_decompress")));
int unishox2_compress_simple(const char *in, int len, char *out)
    __attribute__((unavailable("no output bound: use omni_unishox2_compress")));

#endif /* OmniTAKMobile_Bridging_Header_h */
