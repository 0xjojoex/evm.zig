/* XKCP ships this preprocessed assembly with a lowercase .s suffix. Include it
   through .S so Clang expands its platform and symbol macros cross-platform. */
/* Assemble the SHA3 lane even for baseline targets; runtime dispatch guards it. */
.arch armv8.4-a+sha3
#include "KeccakP-1600-x1-v84a-asm.s"
