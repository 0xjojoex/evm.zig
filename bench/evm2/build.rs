use std::{env, process::Command};

fn main() {
    println!("cargo:rerun-if-env-changed=EVM2_DISPATCH_BACKEND");
    println!("cargo:rerun-if-env-changed=RUSTC");
    let rustc = Command::new(env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
        .arg("--version")
        .output()
        .expect("read compiler version");
    assert!(rustc.status.success());
    let version = String::from_utf8(rustc.stdout).expect("UTF-8 compiler version");
    let nightly = version.contains("nightly");
    let dispatch = env::var("EVM2_DISPATCH_BACKEND")
        .unwrap_or_else(|_| if nightly { "tco" } else { "packed" }.into());
    let engine = match (dispatch.as_str(), nightly) {
        ("packed", false) => "evm2-interpreter",
        ("packed", true) => "evm2-packed-nightly",
        ("tco", true) => "evm2-tail",
        _ => panic!("benchmark requires packed dispatch or nightly tco"),
    };
    println!("cargo:rustc-env=EVM2_BENCH_ENGINE={engine}");
    println!("cargo:rustc-env=EVM2_BENCH_DISPATCH={dispatch}");
    println!("cargo:rustc-env=EVM2_BENCH_RUSTC={}", version.trim());
}
