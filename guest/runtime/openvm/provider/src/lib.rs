#![no_std]

// ERE's OpenVM platform exports the zkvm-standards `read_input` and
// `write_output` C ABI that the Zig guest calls, along with the `zkvm_*`
// accelerators. This crate only bundles it into a static library.
extern crate ere_platform_openvm;
