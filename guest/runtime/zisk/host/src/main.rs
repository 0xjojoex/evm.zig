use evmz_guest_host_protocol::{serve, Success};
use std::{
    any::Any,
    env,
    error::Error,
    fs,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
};
use zisk_core::ZiskRom;
use zisk_transpiler_riscv::Riscv2zisk;
use ziskemu::{Emu, EmuOptions};

#[derive(Default)]
struct Options {
    elf: Option<PathBuf>,
}

fn main() -> Result<(), Box<dyn Error>> {
    let options = parse_args()?;
    let elf_path = options.elf.ok_or("missing --elf PATH")?;
    let elf = fs::read(elf_path)?;
    let rom = Riscv2zisk::new(&elf)
        .run()
        .map_err(|err| format!("ELF-to-ROM conversion failed: {err}"))?;

    serve(|input| execute(&rom, input))?;
    Ok(())
}

fn execute(rom: &ZiskRom, input: Vec<u8>) -> Result<Success, String> {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let options = EmuOptions::default();
        let mut emu = Emu::new(rom);
        emu.ctx = emu.create_emu_context(frame_input(&input), &options);
        emu.run_fast(&options);

        if !emu.ctx.inst_ctx.end {
            return Err(format!(
                "ZisK emulator did not terminate after {} steps",
                emu.number_of_steps()
            ));
        }
        if emu.ctx.inst_ctx.error {
            return Err(format!(
                "ZisK emulator failed at pc=0x{:x} after {} steps",
                emu.ctx.inst_ctx.pc,
                emu.number_of_steps()
            ));
        }

        Ok((emu.get_output_8(), emu.number_of_steps()))
    }))
    .map_err(|err| format!("ZisK emulator panicked: {}", panic_message(err)))??;
    Ok(Success {
        output: result.0,
        primary: result.1,
        secondary: 0,
    })
}

fn frame_input(input: &[u8]) -> Vec<u8> {
    let framed_len = (8 + input.len()).next_multiple_of(8);
    let mut framed = Vec::with_capacity(framed_len);
    framed.extend_from_slice(&(input.len() as u64).to_le_bytes());
    framed.extend_from_slice(input);
    framed.resize(framed_len, 0);
    framed
}

fn panic_message(err: Box<dyn Any + Send + 'static>) -> String {
    err.downcast_ref::<String>()
        .cloned()
        .or_else(|| err.downcast_ref::<&'static str>().map(ToString::to_string))
        .unwrap_or_else(|| "unknown panic".to_string())
}

fn parse_args() -> Result<Options, Box<dyn Error>> {
    let mut options = Options::default();
    let mut args = env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--elf") => options.elf = Some(args.next().ok_or("--elf requires PATH")?.into()),
            _ => return Err(format!("unknown argument: {}", arg.to_string_lossy()).into()),
        }
    }
    Ok(options)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_framing_has_length_and_word_padding() {
        assert_eq!(
            frame_input(&[1, 2, 3]),
            [3, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn emulator_panics_become_request_errors() {
        let reason = match execute(&ZiskRom::default(), Vec::new()) {
            Ok(_) => panic!("empty ROM unexpectedly executed"),
            Err(reason) => reason,
        };
        assert!(reason.starts_with("ZisK emulator panicked:"));
    }
}
