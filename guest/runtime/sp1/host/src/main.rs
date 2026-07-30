use sp1_core_executor::{MinimalExecutorEnum, Program};
use std::{
    env,
    error::Error,
    fmt::Write,
    fs,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

#[derive(Default)]
struct Options {
    elf: Option<PathBuf>,
    input: Option<PathBuf>,
    output: Option<PathBuf>,
}

fn main() -> Result<(), Box<dyn Error>> {
    let options = parse_args()?;
    let elf_path = options.elf.ok_or("missing --elf PATH")?;
    let program = Arc::new(Program::from(&fs::read(elf_path)?)?);
    let mut executor = MinimalExecutorEnum::new(program, false, None);

    if let Some(path) = options.input {
        executor.with_input(&fs::read(path)?);
    }
    loop {
        let result = catch_unwind(AssertUnwindSafe(|| executor.try_execute_chunk()));
        match result {
            Ok(Ok(Some(_))) => {}
            Ok(Ok(None)) => break,
            Ok(Err(err)) => return Err(err.into()),
            Err(_) => {
                let registers = executor.registers();
                return Err(format!(
                    "SP1 executor panicked at pc=0x{:x} after {} cycles \
                     (ra=0x{:x}, sp=0x{:x}, a0=0x{:x})",
                    executor.pc(),
                    executor.global_clk(),
                    registers[1],
                    registers[2],
                    registers[10]
                )
                .into());
            }
        }
    }

    let exit_code = executor.exit_code();
    let cycles = executor.global_clk();
    let public_values = executor.into_public_values_stream();
    if let Some(path) = options.output {
        fs::write(path, &public_values)?;
    }

    println!(
        "sp1 cycles={cycles} exit_code={exit_code} public_values=0x{}",
        encode_hex(&public_values)
    );
    if exit_code != 0 {
        return Err(format!("SP1 guest exited with code {exit_code}").into());
    }
    Ok(())
}

fn parse_args() -> Result<Options, Box<dyn Error>> {
    let mut options = Options::default();
    let mut args = env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--elf") => options.elf = Some(args.next().ok_or("--elf requires PATH")?.into()),
            Some("--input") => {
                options.input = Some(args.next().ok_or("--input requires PATH")?.into())
            }
            Some("--output") => {
                options.output = Some(args.next().ok_or("--output requires PATH")?.into())
            }
            _ => return Err(format!("unknown argument: {}", arg.to_string_lossy()).into()),
        }
    }
    Ok(options)
}

fn encode_hex(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    encoded
}
