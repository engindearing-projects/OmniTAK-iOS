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

#endif /* OmniTAKMobile_Bridging_Header_h */
