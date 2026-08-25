use sp1_build::{execute_build_program, BuildArgs, DEFAULT_TARGET};
use std::{env, error::Error, fs, iter, path::PathBuf};

fn main() -> Result<(), Box<dyn Error>> {
    prefer_rustup_shims()?;
    let mut args = env::args_os().skip(1);
    let provider_dir = PathBuf::from(args.next().ok_or("missing provider directory")?);
    let output = PathBuf::from(args.next().ok_or("missing output archive")?);
    let target_dir = PathBuf::from(args.next().ok_or("missing provider target directory")?);
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    env::set_var("CARGO_TARGET_DIR", &target_dir);

    execute_build_program(
        &BuildArgs {
            locked: true,
            ..BuildArgs::default()
        },
        Some(provider_dir.clone()),
    )?;
    let archive = target_dir
        .join("elf-compilation")
        .join(DEFAULT_TARGET)
        .join("release/libevmz_sp1_provider.a");
    fs::copy(archive, output)?;
    Ok(())
}

fn prefer_rustup_shims() -> Result<(), Box<dyn Error>> {
    let path = env::var_os("PATH").ok_or("PATH is unset")?;
    let paths: Vec<_> = env::split_paths(&path).collect();
    let rustup_bin = paths
        .iter()
        .find(|dir| dir.join("rustup").is_file())
        .ok_or("rustup is not on PATH")?;
    env::set_var(
        "PATH",
        env::join_paths(iter::once(rustup_bin).chain(paths.iter()))?,
    );
    Ok(())
}
