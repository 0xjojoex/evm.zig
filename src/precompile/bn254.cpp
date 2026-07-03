#include "bn254.h"

#include <mcl/bn_c256.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <span>
#include <vector>

namespace
{
constexpr int mcl_io_mode = MCLBN_IO_SERIALIZE | MCLBN_IO_BIG_ENDIAN;

using Bytes64 = std::array<uint8_t, 64>;

bool is_all_zero(std::span<const uint8_t> bytes) noexcept
{
    return std::all_of(bytes.begin(), bytes.end(), [](uint8_t byte) { return byte == 0; });
}

void padded_copy(
    const uint8_t* input, size_t input_size, size_t offset, uint8_t* output, size_t output_size) noexcept
{
    std::fill_n(output, output_size, uint8_t{0});
    if (offset >= input_size)
        return;
    std::copy_n(input + offset, std::min(output_size, input_size - offset), output);
}

bool fp_deserialize(mclBnFp* out, const uint8_t* bytes) noexcept
{
    return mclBnFp_setStr(out, reinterpret_cast<const char*>(bytes), 32, mcl_io_mode) == 0;
}

bool g1_deserialize(mclBnG1* out, const uint8_t* input, size_t input_size, size_t offset) noexcept
{
    Bytes64 bytes{};
    padded_copy(input, input_size, offset, bytes.data(), bytes.size());
    if (is_all_zero(bytes))
    {
        mclBnG1_clear(out);
        return true;
    }

    if (!fp_deserialize(&out->x, bytes.data()) || !fp_deserialize(&out->y, bytes.data() + 32))
        return false;
    mclBnFp_setInt32(&out->z, 1);
    return mclBnG1_isValid(out) != 0;
}

bool g2_deserialize(mclBnG2* out, const uint8_t* input) noexcept
{
    if (is_all_zero(std::span<const uint8_t>{input, 128}))
    {
        mclBnG2_clear(out);
        return true;
    }

    // EIP-197 serializes Fp2 as imaginary limb first, then real limb.
    if (!fp_deserialize(&out->x.d[1], input) || !fp_deserialize(&out->x.d[0], input + 32) ||
        !fp_deserialize(&out->y.d[1], input + 64) || !fp_deserialize(&out->y.d[0], input + 96))
        return false;

    mclBnFp_setInt32(&out->z.d[0], 1);
    mclBnFp_clear(&out->z.d[1]);
    return mclBnG2_isValid(out) != 0;
}

bool fp_serialize(uint8_t* out, const mclBnFp* value) noexcept
{
    std::array<uint8_t, 34> bytes{};
    if (mclBnFp_getStr(reinterpret_cast<char*>(bytes.data()), bytes.size(), value, mcl_io_mode) != 32)
        return false;
    std::copy_n(bytes.data(), 32, out);
    return true;
}

bool g1_serialize(uint8_t output[64], mclBnG1* point) noexcept
{
    if (mclBnG1_isZero(point))
    {
        std::fill_n(output, 64, uint8_t{0});
        return true;
    }

    mclBnG1 normalized{};
    mclBnG1_normalize(&normalized, point);
    return fp_serialize(output, &normalized.x) && fp_serialize(output + 32, &normalized.y);
}

bool ensure_init() noexcept
{
    static const int init_status = mclBn_init(MCL_BN_SNARK1, MCLBN_COMPILED_TIME_VAR);
    return init_status == 0;
}
}  // namespace

int evmz_bn254_add(const uint8_t* input, size_t input_size, uint8_t output[64])
{
    try
    {
        if (!ensure_init())
            return -1;

        mclBnG1 left{};
        mclBnG1 right{};
        if (!g1_deserialize(&left, input, input_size, 0) ||
            !g1_deserialize(&right, input, input_size, 64))
            return -1;

        mclBnG1 result{};
        mclBnG1_add(&result, &left, &right);
        return g1_serialize(output, &result) ? 0 : -1;
    }
    catch (...)
    {
        return -1;
    }
}

int evmz_bn254_mul(const uint8_t* input, size_t input_size, uint8_t output[64])
{
    try
    {
        if (!ensure_init())
            return -1;

        mclBnG1 point{};
        if (!g1_deserialize(&point, input, input_size, 0))
            return -1;

        uint8_t scalar_bytes[32]{};
        padded_copy(input, input_size, 64, scalar_bytes, sizeof(scalar_bytes));

        mclBnFr scalar{};
        if (mclBnFr_setBigEndianMod(&scalar, scalar_bytes, sizeof(scalar_bytes)) != 0)
            return -1;

        mclBnG1 result{};
        mclBnG1_mul(&result, &point, &scalar);
        return g1_serialize(output, &result) ? 0 : -1;
    }
    catch (...)
    {
        return -1;
    }
}

int evmz_bn254_pairing_check(const uint8_t* input, size_t input_size, uint8_t output[32])
{
    static constexpr size_t pair_size = 192;
    static constexpr size_t output_size = 32;

    if (input_size % pair_size != 0)
        return -1;

    try
    {
        if (!ensure_init())
            return -1;

        const size_t pair_count = input_size / pair_size;
        if (pair_count == 0)
        {
            std::fill_n(output, output_size, uint8_t{0});
            output[output_size - 1] = 1;
            return 0;
        }

        std::vector<mclBnG1> g1(pair_count);
        std::vector<mclBnG2> g2(pair_count);
        for (size_t i = 0; i < pair_count; ++i)
        {
            const auto* pair_input = input + i * pair_size;
            if (!g1_deserialize(&g1[i], pair_input, 64, 0) || !g2_deserialize(&g2[i], pair_input + 64))
                return -1;
        }

        mclBnGT result{};
        mclBn_millerLoopVec(&result, g1.data(), g2.data(), pair_count);
        mclBn_finalExp(&result, &result);

        std::fill_n(output, output_size, uint8_t{0});
        output[output_size - 1] = mclBnGT_isOne(&result) ? 1 : 0;
        return 0;
    }
    catch (...)
    {
        return -1;
    }
}
