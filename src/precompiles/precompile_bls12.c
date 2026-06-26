#include "precompile_bls12.h"

#include "blst.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t BLS12_FP_MODULUS[48] = {
    0x1a, 0x01, 0x11, 0xea, 0x39, 0x7f, 0xe6, 0x9a,
    0x4b, 0x1b, 0xa7, 0xb6, 0x43, 0x4b, 0xac, 0xd7,
    0x64, 0x77, 0x4b, 0x84, 0xf3, 0x85, 0x12, 0xbf,
    0x67, 0x30, 0xd2, 0xa0, 0xf6, 0xb0, 0xf6, 0x24,
    0x1e, 0xab, 0xff, 0xfe, 0xb1, 0x53, 0xff, 0xff,
    0xb9, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xab,
};

static bool all_zero(const uint8_t *bytes, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (bytes[i] != 0) return false;
    }
    return true;
}

static bool decode_fp(blst_fp *out, const uint8_t input[64]) {
    if (!all_zero(input, 16)) return false;
    if (memcmp(input + 16, BLS12_FP_MODULUS, 48) >= 0) return false;
    blst_fp_from_bendian(out, input + 16);
    return true;
}

static bool decode_fp2(blst_fp2 *out, const uint8_t input[128]) {
    return decode_fp(&out->fp[0], input) && decode_fp(&out->fp[1], input + 64);
}

static void encode_fp(uint8_t output[64], const blst_fp *input) {
    memset(output, 0, 16);
    blst_bendian_from_fp(output + 16, input);
}

static void encode_fp2(uint8_t output[128], const blst_fp2 *input) {
    encode_fp(output, &input->fp[0]);
    encode_fp(output + 64, &input->fp[1]);
}

static bool decode_g1(blst_p1_affine *out, const uint8_t input[128], bool subgroup_check) {
    if (all_zero(input, 128)) {
        memset(out, 0, sizeof(*out));
        return true;
    }

    if (!decode_fp(&out->x, input) || !decode_fp(&out->y, input + 64)) return false;
    if (!blst_p1_affine_on_curve(out)) return false;
    if (subgroup_check && !blst_p1_affine_in_g1(out)) return false;
    return true;
}

static bool decode_g2(blst_p2_affine *out, const uint8_t input[256], bool subgroup_check) {
    if (all_zero(input, 256)) {
        memset(out, 0, sizeof(*out));
        return true;
    }

    if (!decode_fp2(&out->x, input) || !decode_fp2(&out->y, input + 128)) return false;
    if (!blst_p2_affine_on_curve(out)) return false;
    if (subgroup_check && !blst_p2_affine_in_g2(out)) return false;
    return true;
}

static void encode_g1_affine(uint8_t output[128], const blst_p1_affine *input) {
    if (blst_p1_affine_is_inf(input)) {
        memset(output, 0, 128);
        return;
    }

    encode_fp(output, &input->x);
    encode_fp(output + 64, &input->y);
}

static void encode_g1(uint8_t output[128], const blst_p1 *input) {
    blst_p1_affine affine;
    blst_p1_to_affine(&affine, input);
    encode_g1_affine(output, &affine);
}

static void encode_g2_affine(uint8_t output[256], const blst_p2_affine *input) {
    if (blst_p2_affine_is_inf(input)) {
        memset(output, 0, 256);
        return;
    }

    encode_fp2(output, &input->x);
    encode_fp2(output + 128, &input->y);
}

static void encode_g2(uint8_t output[256], const blst_p2 *input) {
    blst_p2_affine affine;
    blst_p2_to_affine(&affine, input);
    encode_g2_affine(output, &affine);
}

static void reverse_scalar(uint8_t output[32], const uint8_t input[32]) {
    for (size_t i = 0; i < 32; i++) {
        output[i] = input[31 - i];
    }
}

int evmz_bls12_g1_add(const uint8_t *input, uint8_t output[128]) {
    blst_p1_affine a_affine;
    blst_p1_affine b_affine;
    if (!decode_g1(&a_affine, input, false) || !decode_g1(&b_affine, input + 128, false)) {
        return EVMZ_BLS12_INVALID;
    }

    blst_p1 a;
    blst_p1 b;
    blst_p1 result;
    blst_p1_from_affine(&a, &a_affine);
    blst_p1_from_affine(&b, &b_affine);
    blst_p1_add_or_double(&result, &a, &b);
    encode_g1(output, &result);
    return EVMZ_BLS12_OK;
}

int evmz_bls12_g2_add(const uint8_t *input, uint8_t output[256]) {
    blst_p2_affine a_affine;
    blst_p2_affine b_affine;
    if (!decode_g2(&a_affine, input, false) || !decode_g2(&b_affine, input + 256, false)) {
        return EVMZ_BLS12_INVALID;
    }

    blst_p2 a;
    blst_p2 b;
    blst_p2 result;
    blst_p2_from_affine(&a, &a_affine);
    blst_p2_from_affine(&b, &b_affine);
    blst_p2_add_or_double(&result, &a, &b);
    encode_g2(output, &result);
    return EVMZ_BLS12_OK;
}

int evmz_bls12_g1_msm(const uint8_t *input, size_t input_len, uint8_t output[128]) {
    if (input_len == 0 || input_len % 160 != 0) return EVMZ_BLS12_INVALID;
    const size_t count = input_len / 160;

    blst_p1_affine *points = malloc(count * sizeof(*points));
    const blst_p1_affine **point_ptrs = malloc(count * sizeof(*point_ptrs));
    uint8_t *scalars = malloc(count * 32);
    const uint8_t **scalar_ptrs = malloc(count * sizeof(*scalar_ptrs));
    const size_t scratch_size = blst_p1s_mult_pippenger_scratch_sizeof(count);
    limb_t *scratch = scratch_size == 0 ? NULL : malloc(scratch_size);
    if (points == NULL || point_ptrs == NULL || scalars == NULL || scalar_ptrs == NULL ||
        (scratch_size != 0 && scratch == NULL)) {
        free(points);
        free(point_ptrs);
        free(scalars);
        free(scalar_ptrs);
        free(scratch);
        return EVMZ_BLS12_OOM;
    }

    for (size_t i = 0; i < count; i++) {
        const uint8_t *item = input + i * 160;
        if (!decode_g1(&points[i], item, true)) {
            free(points);
            free(point_ptrs);
            free(scalars);
            free(scalar_ptrs);
            free(scratch);
            return EVMZ_BLS12_INVALID;
        }
        reverse_scalar(scalars + i * 32, item + 128);
        point_ptrs[i] = &points[i];
        scalar_ptrs[i] = scalars + i * 32;
    }

    blst_p1 result;
    blst_p1s_mult_pippenger(&result, point_ptrs, count, scalar_ptrs, 256, scratch);
    encode_g1(output, &result);

    free(points);
    free(point_ptrs);
    free(scalars);
    free(scalar_ptrs);
    free(scratch);
    return EVMZ_BLS12_OK;
}

int evmz_bls12_g2_msm(const uint8_t *input, size_t input_len, uint8_t output[256]) {
    if (input_len == 0 || input_len % 288 != 0) return EVMZ_BLS12_INVALID;
    const size_t count = input_len / 288;

    blst_p2_affine *points = malloc(count * sizeof(*points));
    const blst_p2_affine **point_ptrs = malloc(count * sizeof(*point_ptrs));
    uint8_t *scalars = malloc(count * 32);
    const uint8_t **scalar_ptrs = malloc(count * sizeof(*scalar_ptrs));
    const size_t scratch_size = blst_p2s_mult_pippenger_scratch_sizeof(count);
    limb_t *scratch = scratch_size == 0 ? NULL : malloc(scratch_size);
    if (points == NULL || point_ptrs == NULL || scalars == NULL || scalar_ptrs == NULL ||
        (scratch_size != 0 && scratch == NULL)) {
        free(points);
        free(point_ptrs);
        free(scalars);
        free(scalar_ptrs);
        free(scratch);
        return EVMZ_BLS12_OOM;
    }

    for (size_t i = 0; i < count; i++) {
        const uint8_t *item = input + i * 288;
        if (!decode_g2(&points[i], item, true)) {
            free(points);
            free(point_ptrs);
            free(scalars);
            free(scalar_ptrs);
            free(scratch);
            return EVMZ_BLS12_INVALID;
        }
        reverse_scalar(scalars + i * 32, item + 256);
        point_ptrs[i] = &points[i];
        scalar_ptrs[i] = scalars + i * 32;
    }

    blst_p2 result;
    blst_p2s_mult_pippenger(&result, point_ptrs, count, scalar_ptrs, 256, scratch);
    encode_g2(output, &result);

    free(points);
    free(point_ptrs);
    free(scalars);
    free(scalar_ptrs);
    free(scratch);
    return EVMZ_BLS12_OK;
}

int evmz_bls12_pairing_check(const uint8_t *input, size_t input_len, uint8_t output[32]) {
    if (input_len == 0 || input_len % 384 != 0) return EVMZ_BLS12_INVALID;

    blst_fp12 product;
    bool have_product = false;
    const size_t count = input_len / 384;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *item = input + i * 384;
        blst_p1_affine p;
        blst_p2_affine q;
        if (!decode_g1(&p, item, true) || !decode_g2(&q, item + 128, true)) {
            return EVMZ_BLS12_INVALID;
        }

        blst_fp12 loop;
        blst_miller_loop(&loop, &q, &p);
        if (!have_product) {
            memcpy(&product, &loop, sizeof(product));
            have_product = true;
        } else {
            blst_fp12_mul(&product, &product, &loop);
        }
    }

    blst_fp12 result;
    blst_final_exp(&result, &product);
    memset(output, 0, 32);
    output[31] = blst_fp12_is_one(&result) ? 1 : 0;
    return EVMZ_BLS12_OK;
}

int evmz_bls12_map_fp_to_g1(const uint8_t input[64], uint8_t output[128]) {
    blst_fp fp;
    if (!decode_fp(&fp, input)) return EVMZ_BLS12_INVALID;

    blst_p1 result;
    blst_map_to_g1(&result, &fp, NULL);
    encode_g1(output, &result);
    return EVMZ_BLS12_OK;
}

int evmz_bls12_map_fp2_to_g2(const uint8_t input[128], uint8_t output[256]) {
    blst_fp2 fp2;
    if (!decode_fp2(&fp2, input)) return EVMZ_BLS12_INVALID;

    blst_p2 result;
    blst_map_to_g2(&result, &fp2, NULL);
    encode_g2(output, &result);
    return EVMZ_BLS12_OK;
}
