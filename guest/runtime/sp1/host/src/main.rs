use evmz_guest_host_protocol::{serve, Success};
use sp1_core_executor::{MinimalExecutorEnum, Program};
use std::{
    env,
    error::Error,
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
    let mut executor = GuestExecutor::new(program);
    if let Some(input_path) = options.input {
        let success = executor.execute(&fs::read(input_path)?)?;
        if let Some(output_path) = options.output {
            fs::write(output_path, &success.output)?;
        }
        println!("sp1 cycles={}", success.primary);
        return Ok(());
    }
    if options.output.is_some() {
        return Err("--output requires --input".into());
    }
    serve(|input| executor.execute(&input))?;
    Ok(())
}

struct GuestExecutor {
    program: Arc<Program>,
    reusable: Option<MinimalExecutorEnum>,
}

impl GuestExecutor {
    fn new(program: Arc<Program>) -> Self {
        let reusable = cfg!(all(target_os = "linux", target_arch = "x86_64"))
            .then(|| MinimalExecutorEnum::new(program.clone(), false, None));
        Self { program, reusable }
    }

    fn execute(&mut self, input: &[u8]) -> Result<Success, String> {
        if let Some(executor) = &mut self.reusable {
            executor.reset();
            return execute(executor, input);
        }

        // SP1's portable executor does not implement reset yet.
        let mut executor = MinimalExecutorEnum::new(self.program.clone(), false, None);
        execute(&mut executor, input)
    }
}

fn execute(executor: &mut MinimalExecutorEnum, input: &[u8]) -> Result<Success, String> {
    executor.with_input(input);
    loop {
        let result = catch_unwind(AssertUnwindSafe(|| executor.try_execute_chunk()));
        match result {
            Ok(Ok(Some(_))) => {}
            Ok(Ok(None)) => break,
            Ok(Err(err)) => return Err(err.to_string()),
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
                ));
            }
        }
    }

    let exit_code = executor.exit_code();
    let cycles = executor.global_clk();
    if exit_code != 0 {
        return Err(format!("SP1 guest exited with code {exit_code}"));
    }
    Ok(Success {
        output: executor.public_values_stream().clone(),
        primary: cycles,
        secondary: 0,
    })
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
