#![no_std]

use core::{mem, ptr, slice};
use ere_platform_openvm::{OpenVMPlatform, Platform};

/// C ABI bridge used by the Zig guest. OpenVM owns the input allocation, so
/// keep it alive for the remainder of the one-shot guest process.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn read_input(buf_ptr: *mut *const u8, buf_size: *mut usize) {
    let input = OpenVMPlatform::read_input();
    if input.is_empty() {
        unsafe {
            *buf_ptr = ptr::null();
            *buf_size = 0;
        }
        return;
    }
    unsafe {
        *buf_ptr = input.as_ptr();
        *buf_size = input.len();
    }
    mem::forget(input);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn write_output(output: *const u8, size: usize) {
    OpenVMPlatform::write_output(unsafe { slice::from_raw_parts(output, size) });
}
