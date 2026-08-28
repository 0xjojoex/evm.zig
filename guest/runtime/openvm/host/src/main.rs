use std::{
    env,
    error::Error,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    path::{Path, PathBuf},
    time::Instant,
};

use openvm_sdk::{
    config::{AggregationSystemParams, AppConfig},
    Sdk, StdIn,
};
use openvm_sdk_config::SdkVmConfig;

const READY: &[u8; 8] = b"EVOMH001";
const MAX_INPUT_BYTES: usize = 512 * 1024 * 1024;
const RESPONSE_HEADER_BYTES: usize = 40;

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

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();
    writer.write_all(READY)?;
    writer.flush()?;

    while let Some(input) = read_request(&mut reader)? {
        let start = Instant::now();
        let result = catch_unwind(AssertUnwindSafe(|| {
            sdk.execute_metered_cost(&metered, make_stdin(&input))
        }));
        let duration_nanos = start.elapsed().as_nanos().try_into().unwrap_or(u64::MAX);
        match result {
            Ok(Ok((output, (trace_cells, instret)))) => write_response(
                &mut writer,
                0,
                instret,
                trace_cells,
                duration_nanos,
                &output,
            )?,
            Ok(Err(error)) => write_response(
                &mut writer,
                1,
                0,
                0,
                duration_nanos,
                error.to_string().as_bytes(),
            )?,
            Err(_) => write_response(
                &mut writer,
                1,
                0,
                0,
                duration_nanos,
                b"OpenVM executor panicked",
            )?,
        }
        writer.flush()?;
    }
    Ok(())
}

fn read_request(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut length_bytes = [0_u8; 8];
    if reader.read(&mut length_bytes[..1])? == 0 {
        return Ok(None);
    }
    reader.read_exact(&mut length_bytes[1..])?;
    let length = usize::try_from(u64::from_le_bytes(length_bytes))
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "input length exceeds usize"))?;
    if length > MAX_INPUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "input exceeds host limit",
        ));
    }
    let mut input = vec![0_u8; length];
    reader.read_exact(&mut input)?;
    Ok(Some(input))
}

fn write_response(
    writer: &mut impl Write,
    status: u8,
    instret: u64,
    trace_cells: u64,
    duration_nanos: u64,
    payload: &[u8],
) -> io::Result<()> {
    let mut header = [0_u8; RESPONSE_HEADER_BYTES];
    header[0] = status;
    header[8..16].copy_from_slice(&instret.to_le_bytes());
    header[16..24].copy_from_slice(&trace_cells.to_le_bytes());
    header[24..32].copy_from_slice(&duration_nanos.to_le_bytes());
    header[32..40].copy_from_slice(&(payload.len() as u64).to_le_bytes());
    writer.write_all(&header)?;
    writer.write_all(payload)
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

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::{read_request, write_response, RESPONSE_HEADER_BYTES};

    #[test]
    fn server_protocol_carries_both_openvm_metrics() {
        let mut request = Cursor::new([3, 0, 0, 0, 0, 0, 0, 0, 0x15, 0x01, 0xaa]);
        assert_eq!(
            read_request(&mut request).unwrap().unwrap(),
            [0x15, 0x01, 0xaa]
        );
        assert!(read_request(&mut request).unwrap().is_none());

        let mut response = Vec::new();
        write_response(&mut response, 0, 42, 84, 7, &[1, 2, 3]).unwrap();
        assert_eq!(response.len(), RESPONSE_HEADER_BYTES + 3);
        assert_eq!(u64::from_le_bytes(response[8..16].try_into().unwrap()), 42);
        assert_eq!(u64::from_le_bytes(response[16..24].try_into().unwrap()), 84);
        assert_eq!(u64::from_le_bytes(response[24..32].try_into().unwrap()), 7);
        assert_eq!(u64::from_le_bytes(response[32..40].try_into().unwrap()), 3);
        assert_eq!(&response[40..], &[1, 2, 3]);
    }
}
