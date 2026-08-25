use evmz_guest_host_protocol::{serve, Success};
use std::{
    env,
    error::Error,
    ffi::OsString,
    fs,
    panic::{catch_unwind, AssertUnwindSafe},
    path::{Path, PathBuf},
};

use openvm_sdk::{
    config::{AggregationSystemParams, AppConfig},
    Sdk, StdIn,
};
use openvm_sdk_config::SdkVmConfig;

fn main() -> Result<(), Box<dyn Error>> {
    if env::var_os("OPENVM_DEBUG_PC").is_some_and(|value| value == "1") {
        tracing_subscriber::fmt()
            .with_max_level(tracing_subscriber::filter::LevelFilter::DEBUG)
            .with_target(false)
            .without_time()
            .init();
    }

    let mut args = env::args_os().skip(1);
    let mode = required(&mut args, "--server")?;
    if mode != Path::new("--server") {
        return Err("usage: evmz-openvm-host --server CONFIG ELF".into());
    }
    let config_path = required(&mut args, "OpenVM config")?;
    let elf_path = required(&mut args, "guest ELF")?;
    if args.next().is_some() {
        return Err("usage: evmz-openvm-host --server CONFIG ELF".into());
    }
    run_server(&config_path, &elf_path)
}

fn load_config(path: &Path) -> Result<AppConfig<SdkVmConfig>, Box<dyn Error>> {
    let config_text = fs::read_to_string(path)?;
    let mut config: AppConfig<SdkVmConfig> = toml::from_str(&config_text)?;
    config.app_vm_config.system.config = config
        .app_vm_config
        .system
        .config
        .clone()
        .with_public_values_bytes(256);
    Ok(config)
}

fn run_server(config_path: &Path, elf_path: &Path) -> Result<(), Box<dyn Error>> {
    let sdk = Sdk::new(
        load_config(config_path)?,
        AggregationSystemParams::default(),
    )?;
    let exe = sdk.convert_to_exe(fs::read(elf_path)?)?;
    let metered = sdk.compile_metered_cost(exe)?;

    serve(|input| {
        let result = catch_unwind(AssertUnwindSafe(|| {
            sdk.execute_metered_cost(&metered, make_stdin(&input))
        }));
        match result {
            Ok(Ok((output, (trace_cells, instret)))) => Ok(Success {
                output,
                primary: instret,
                secondary: trace_cells,
            }),
            Ok(Err(error)) => Err(error.to_string()),
            Err(_) => Err("OpenVM executor panicked".to_string()),
        }
    })?;
    Ok(())
}

fn required(
    args: &mut impl Iterator<Item = OsString>,
    name: &str,
) -> Result<PathBuf, Box<dyn Error>> {
    args.next()
        .map(PathBuf::from)
        .ok_or_else(|| format!("missing {name}").into())
}

fn make_stdin(input: &[u8]) -> StdIn {
    let mut stdin = StdIn::default();
    stdin.write_bytes(input);
    stdin
}
