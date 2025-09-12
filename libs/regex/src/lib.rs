#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use core::ffi::{c_char, c_int, c_uchar, c_ulonglong};
use core::{slice, str};

use regex_automata::meta::{Builder, Regex};
use regex_automata::util::syntax; // syntax::parse

// -------- minimal bump allocator (no dealloc; enough for compile/match) --------
use core::alloc::{GlobalAlloc, Layout};
use core::sync::atomic::{AtomicUsize, Ordering};

struct BumpAlloc;
const HEAP_SIZE: usize = 4 * 1024 * 1024;
static mut HEAP: [u8; HEAP_SIZE] = [0; HEAP_SIZE];
static OFF: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for BumpAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let align = layout.align();
        let size = layout.size();
        let mut off = OFF.load(Ordering::Relaxed);
        let base = core::ptr::addr_of_mut!(HEAP) as usize;
        loop {
            let aligned = (base + off + (align - 1)) & !(align - 1);
            let new_off = aligned + size - base;
            if new_off > HEAP_SIZE { return core::ptr::null_mut(); }
            match OFF.compare_exchange(off, new_off, Ordering::SeqCst, Ordering::Relaxed) {
                Ok(_) => return aligned as *mut u8,
                Err(o) => off = o,
            }
        }
    }
    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // no-op (bump)
    }
}

#[global_allocator]
static GLOBAL: BumpAlloc = BumpAlloc;

#[panic_handler]
fn panic_handler(_: &core::panic::PanicInfo) -> ! {
    // Use abort to end the program for wasm/unix.
    loop {
        #[cfg(target_arch = "wasm32")]
        core::arch::wasm32::unreachable();
        #[cfg(not(target_arch = "wasm32"))]
        core::hint::spin_loop();
    }
}

// ---------------------- C ABI ----------------------

#[repr(C)]
pub struct AifwRegex {
    re: Regex,
}

/// Compile the regular expression.
/// Returns a handle; returns null on failure.
#[no_mangle]
pub extern "C" fn aifw_regex_compile(pattern: *const c_char) -> *mut AifwRegex {
    if pattern.is_null() { return core::ptr::null_mut(); }

    // compute C string length
    let len = unsafe {
        let mut l = 0usize;
        while *pattern.add(l) != 0 { l += 1; }
        l
    };
    let bytes = unsafe { slice::from_raw_parts(pattern as *const u8, len) };
    let p = match str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return core::ptr::null_mut()
    };

    let hir = match syntax::parse(p) {
        Ok(h) => h,
        Err(_) => return core::ptr::null_mut(),
    };
    let re = match Builder::new().build_from_hir(&hir) {
        Ok(r) => r,
        Err(_) => return core::ptr::null_mut(),
    };
    Box::into_raw(Box::new(AifwRegex { re }))
}

#[no_mangle]
pub extern "C" fn aifw_regex_free(ptr_re: *mut AifwRegex) {
    if !ptr_re.is_null() {
        unsafe { drop(Box::from_raw(ptr_re)); }
    }
}

/// Find a match in the haystack.
/// Returns 1 if a match was found, 0 if not, and < 0 on error.
#[no_mangle]
pub extern "C" fn aifw_regex_find(
    ptr_re: *mut AifwRegex,
    hay_ptr: *const c_uchar,
    hay_len: c_ulonglong,
    start: c_ulonglong,
    out_start: *mut c_ulonglong,
    out_end: *mut c_ulonglong,
) -> c_int {
    if ptr_re.is_null() || hay_ptr.is_null() || out_start.is_null() || out_end.is_null() {
        return -1;
    }
    let re = unsafe { &*ptr_re };
    let hay = unsafe { slice::from_raw_parts(hay_ptr as *const u8, hay_len as usize) };
    let s = core::cmp::min(start as usize, hay.len());
    let sub = &hay[s..];
    match re.re.find(sub) {
        Some(m) => {
            unsafe {
                *out_start = (s + m.start()) as c_ulonglong;
                *out_end = (s + m.end()) as c_ulonglong;
            }
            1
        }
        None => 0,
    }
}
