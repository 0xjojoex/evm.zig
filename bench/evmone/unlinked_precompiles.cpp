// Aborting stand-ins for evmone's BLS12-381 and KZG precompile backends.
//
// evmone implements both through blst, which the transaction lane does not build. Its workloads
// never call these precompiles; a workload that does must link blst instead of this file.
#include <evmone_precompiles/bls.hpp>
#include <evmone_precompiles/kzg.hpp>

#include <cstdio>
#include <cstdlib>

namespace
{
[[noreturn]] bool unlinked(const char* name) noexcept
{
    std::fprintf(stderr, "evmone-tx-loop: %s needs blst, which this runner does not link\n", name);
    std::abort();
}
}  // namespace

namespace evmone::crypto
{
namespace bls
{
bool g1_add(uint8_t[64], uint8_t[64], const uint8_t[64], const uint8_t[64], const uint8_t[64],
    const uint8_t[64]) noexcept
{
    return unlinked("BLS12_G1ADD");
}

bool g1_mul(
    uint8_t[64], uint8_t[64], const uint8_t[64], const uint8_t[64], const uint8_t[32]) noexcept
{
    return unlinked("BLS12_G1MSM");
}

bool g2_add(uint8_t[128], uint8_t[128], const uint8_t[128], const uint8_t[128],
    const uint8_t[128], const uint8_t[128]) noexcept
{
    return unlinked("BLS12_G2ADD");
}

bool g2_mul(uint8_t[128], uint8_t[128], const uint8_t[128], const uint8_t[128],
    const uint8_t[32]) noexcept
{
    return unlinked("BLS12_G2MSM");
}

bool g1_msm(uint8_t[64], uint8_t[64], const uint8_t*, size_t)
{
    return unlinked("BLS12_G1MSM");
}

bool g2_msm(uint8_t[128], uint8_t[128], const uint8_t*, size_t)
{
    return unlinked("BLS12_G2MSM");
}

bool map_fp_to_g1(uint8_t[64], uint8_t[64], const uint8_t[64]) noexcept
{
    return unlinked("BLS12_MAP_FP_TO_G1");
}

bool map_fp2_to_g2(uint8_t[128], uint8_t[128], const uint8_t[128]) noexcept
{
    return unlinked("BLS12_MAP_FP2_TO_G2");
}

bool pairing_check(uint8_t[32], const uint8_t*, size_t) noexcept
{
    return unlinked("BLS12_PAIRING_CHECK");
}
}  // namespace bls

bool kzg_verify_proof(const std::byte[VERSIONED_HASH_SIZE], const std::byte[32],
    const std::byte[32], const std::byte[48], const std::byte[48]) noexcept
{
    return unlinked("POINT_EVALUATION");
}
}  // namespace evmone::crypto
