/* Translation root for `src/crypto/libsecp256k1.zig`: the upstream headers the
 * native secp256k1 bindings use (see `addNativeSecp256k1` in build.zig). */
#include <secp256k1.h>
#include <secp256k1_ecdh.h>
#include <secp256k1_preallocated.h>
#include <secp256k1_recovery.h>
