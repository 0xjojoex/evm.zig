#![no_std]

// ERE owns SP1's zkVM accelerator ABI. Retain the platform and its libzkevm
// dependency in this C-compatible static archive.
use ere_platform_sp1 as _;
