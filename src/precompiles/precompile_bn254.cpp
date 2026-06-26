#include "precompile_bn254.h"

#include "evmone_precompiles/bn254.hpp"
#include <intx/intx.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <utility>
#include <vector>

namespace
{
using Bytes32 = std::array<uint8_t, 32>;
using Bytes64 = std::array<uint8_t, 64>;

evmmax::bn254::uint256 load_u256(const uint8_t* input) noexcept
{
    return intx::be::load<evmmax::bn254::uint256>(std::span<const uint8_t, 32>{input, 32});
}

void padded_copy(
    const uint8_t* input, size_t input_size, size_t offset, uint8_t* output, size_t output_size) noexcept
{
    std::fill_n(output, output_size, uint8_t{0});
    if (offset >= input_size)
        return;

    const auto copied = std::min(output_size, input_size - offset);
    std::copy_n(input + offset, copied, output);
}

std::optional<evmmax::bn254::AffinePoint> load_g1_point(
    const uint8_t* input, size_t input_size, size_t offset) noexcept
{
    Bytes64 bytes{};
    padded_copy(input, input_size, offset, bytes.data(), bytes.size());

    const auto point =
        evmmax::bn254::AffinePoint::from_bytes(std::span<const uint8_t, 64>{bytes.data(), bytes.size()});
    if (!point.has_value() || !evmmax::bn254::validate(*point))
        return std::nullopt;
    return point;
}

evmmax::bn254::uint256 load_u256_padded(const uint8_t* input, size_t input_size, size_t offset) noexcept
{
    Bytes32 bytes{};
    padded_copy(input, input_size, offset, bytes.data(), bytes.size());
    return intx::be::load<evmmax::bn254::uint256>(std::span<const uint8_t, 32>{bytes.data(), bytes.size()});
}

void store_g1_point(const evmmax::bn254::AffinePoint& point, uint8_t output[64]) noexcept
{
    point.to_bytes(std::span<uint8_t, 64>{output, 64});
}
}  // namespace

int evmz_bn254_add(const uint8_t* input, size_t input_size, uint8_t output[64])
{
    try
    {
        const auto p0 = load_g1_point(input, input_size, 0);
        const auto p1 = load_g1_point(input, input_size, 64);
        if (!p0.has_value() || !p1.has_value())
            return -1;

        store_g1_point(evmmax::ecc::add_affine(*p0, *p1), output);
        return 0;
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
        const auto point = load_g1_point(input, input_size, 0);
        if (!point.has_value())
            return -1;

        const auto scalar = load_u256_padded(input, input_size, 64);
        store_g1_point(evmmax::bn254::mul(*point, scalar), output);
        return 0;
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
        std::vector<std::pair<evmmax::bn254::Point, evmmax::bn254::ExtPoint>> pairs;
        pairs.reserve(input_size / pair_size);

        for (const auto* input_ptr = input; input_ptr != input + input_size; input_ptr += pair_size)
        {
            namespace bn = evmmax::bn254;
            const bn::Point p{load_u256(input_ptr), load_u256(input_ptr + 32)};
            const bn::ExtPoint q{
                {load_u256(input_ptr + 96), load_u256(input_ptr + 64)},
                {load_u256(input_ptr + 160), load_u256(input_ptr + 128)},
            };
            pairs.emplace_back(p, q);
        }

        const auto result = evmmax::bn254::pairing_check(pairs);
        if (!result.has_value())
            return -1;

        std::fill_n(output, output_size, uint8_t{0});
        output[output_size - 1] = *result ? 1 : 0;
        return 0;
    }
    catch (...)
    {
        return -1;
    }
}
