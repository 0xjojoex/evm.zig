#include "kzg.h"

#include "blst.h"

#include <stdbool.h>
#include <string.h>

/*
 * [tau]G2: the second G2 monomial point of the Ethereum mainnet KZG ceremony
 * (c-kzg-4844 src/trusted_setup.txt, g2_monomial[1]), stored as uncompressed
 * affine big-endian Fp coordinates. Compressed form (96 bytes):
 *   b5bfd7dd8cdeb128843bc287230af38926187075cbfbefa81009a2ce615ac53d
 *   2914e5870cb452d2afaaab24f3499f72185cbfee53492714734429b7b38608e2
 *   3926c911cceceac9a36851477ba4c60b087041de621000edc98edada20c1def2
 * This is the only setup value KZG proof *verification* needs; the full
 * trusted setup (8192 G1 points, FK20 tables) is prover-side machinery.
 */
static const uint8_t TAU_G2_X_C0[48] = {
    0x18, 0x5c, 0xbf, 0xee, 0x53, 0x49, 0x27, 0x14, 0x73, 0x44, 0x29, 0xb7, 0xb3, 0x86, 0x08, 0xe2,
    0x39, 0x26, 0xc9, 0x11, 0xcc, 0xec, 0xea, 0xc9, 0xa3, 0x68, 0x51, 0x47, 0x7b, 0xa4, 0xc6, 0x0b,
    0x08, 0x70, 0x41, 0xde, 0x62, 0x10, 0x00, 0xed, 0xc9, 0x8e, 0xda, 0xda, 0x20, 0xc1, 0xde, 0xf2,
};
static const uint8_t TAU_G2_X_C1[48] = {
    0x15, 0xbf, 0xd7, 0xdd, 0x8c, 0xde, 0xb1, 0x28, 0x84, 0x3b, 0xc2, 0x87, 0x23, 0x0a, 0xf3, 0x89,
    0x26, 0x18, 0x70, 0x75, 0xcb, 0xfb, 0xef, 0xa8, 0x10, 0x09, 0xa2, 0xce, 0x61, 0x5a, 0xc5, 0x3d,
    0x29, 0x14, 0xe5, 0x87, 0x0c, 0xb4, 0x52, 0xd2, 0xaf, 0xaa, 0xab, 0x24, 0xf3, 0x49, 0x9f, 0x72,
};
static const uint8_t TAU_G2_Y_C0[48] = {
    0x01, 0x43, 0x53, 0xbd, 0xb9, 0x6b, 0x62, 0x6d, 0xd7, 0xd5, 0xee, 0x85, 0x99, 0xd1, 0xfc, 0xa2,
    0x13, 0x15, 0x69, 0x49, 0x0e, 0x28, 0xde, 0x18, 0xe8, 0x24, 0x51, 0xa4, 0x96, 0xa9, 0xc9, 0x79,
    0x4c, 0xe2, 0x6d, 0x10, 0x59, 0x41, 0xf3, 0x83, 0xee, 0x68, 0x9b, 0xfb, 0xbb, 0x83, 0x2a, 0x99,
};
static const uint8_t TAU_G2_Y_C1[48] = {
    0x16, 0x66, 0xc5, 0x4b, 0x0a, 0x32, 0x52, 0x95, 0x03, 0x43, 0x2f, 0xca, 0xe0, 0x18, 0x1b, 0x4b,
    0xef, 0x79, 0xde, 0x09, 0xfc, 0x63, 0x67, 0x1f, 0xda, 0x5e, 0xd1, 0xba, 0x9b, 0xfa, 0x07, 0x89,
    0x94, 0x95, 0x34, 0x6f, 0x3d, 0x7a, 0xc9, 0xcd, 0x23, 0x04, 0x8e, 0xf3, 0x0d, 0x0a, 0x15, 0x4f,
};

/* Fr order is 255 bits; canonical scalars always fit. */
#define KZG_SCALAR_BITS 255

static void tau_g2(blst_p2_affine *out) {
    blst_fp_from_bendian(&out->x.fp[0], TAU_G2_X_C0);
    blst_fp_from_bendian(&out->x.fp[1], TAU_G2_X_C1);
    blst_fp_from_bendian(&out->y.fp[0], TAU_G2_Y_C0);
    blst_fp_from_bendian(&out->y.fp[1], TAU_G2_Y_C1);
}

static bool decode_fr(blst_scalar *out, const uint8_t bytes[32]) {
    blst_scalar_from_bendian(out, bytes);
    return blst_scalar_fr_check(out);
}

static bool decode_g1(blst_p1_affine *out, const uint8_t bytes[48]) {
    if (blst_p1_uncompress(out, bytes) != BLST_SUCCESS) return false;
    return blst_p1_affine_in_g1(out);
}

/* Verify p(z) == y for the polynomial committed to by `commitment`:
 * e(C - [y]G1, G2) == e(W, [tau]G2 - [z]G2), checked as
 * e(-(C - [y]G1), G2) * e(W, [tau]G2 - [z]G2) == 1. */
int evmz_kzg_verify_proof(
    const uint8_t commitment[48],
    const uint8_t z[32],
    const uint8_t y[32],
    const uint8_t proof[48]) {
    blst_scalar z_scalar, y_scalar;
    blst_p1_affine c_affine, w_affine;
    if (!decode_fr(&z_scalar, z) || !decode_fr(&y_scalar, y)) return EVMZ_KZG_INVALID;
    if (!decode_g1(&c_affine, commitment) || !decode_g1(&w_affine, proof)) return EVMZ_KZG_INVALID;

    blst_p2 x_minus_z, z_g2;
    blst_p2_mult(&z_g2, blst_p2_generator(), z_scalar.b, KZG_SCALAR_BITS);
    blst_p2_cneg(&z_g2, true);
    blst_p2_affine tau_affine;
    tau_g2(&tau_affine);
    blst_p2 tau;
    blst_p2_from_affine(&tau, &tau_affine);
    blst_p2_add_or_double(&x_minus_z, &tau, &z_g2);

    blst_p1 p_minus_y, y_g1, c_proj;
    blst_p1_mult(&y_g1, blst_p1_generator(), y_scalar.b, KZG_SCALAR_BITS);
    blst_p1_cneg(&y_g1, true);
    blst_p1_from_affine(&c_proj, &c_affine);
    blst_p1_add_or_double(&p_minus_y, &c_proj, &y_g1);
    blst_p1_cneg(&p_minus_y, true);

    blst_p1_affine lhs_affine;
    blst_p1_to_affine(&lhs_affine, &p_minus_y);
    blst_p2_affine x_minus_z_affine, g2_gen_affine;
    blst_p2_to_affine(&x_minus_z_affine, &x_minus_z);
    blst_p2_to_affine(&g2_gen_affine, blst_p2_generator());

    blst_fp12 lhs_loop, rhs_loop, product, result;
    blst_miller_loop(&lhs_loop, &g2_gen_affine, &lhs_affine);
    blst_miller_loop(&rhs_loop, &x_minus_z_affine, &w_affine);
    blst_fp12_mul(&product, &lhs_loop, &rhs_loop);
    blst_final_exp(&result, &product);
    return blst_fp12_is_one(&result) ? EVMZ_KZG_OK : EVMZ_KZG_INVALID;
}
