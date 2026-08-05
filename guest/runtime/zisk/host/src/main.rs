use std::{
    any::Any,
    env,
    error::Error,
    fs,
    io::{self, Read, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    time::Instant,
};
use zisk_core::{Riscv2zisk, ZiskRom};
use ziskemu::{Emu, EmuOptions};

const READY: &[u8; 8] = b"EVZKH001";
const MAX_INPUT_BYTES: usize = 512 * 1024 * 1024;
const RESPONSE_HEADER_BYTES: usize = 32;

#[derive(Default)]
struct Options {
    elf: Option<PathBuf>,
}

struct Success {
    output: Vec<u8>,
    steps: u64,
    duration_nanos: u64,
}

fn main() -> Result<(), Box<dyn Error>> {
    let options = parse_args()?;
    let elf_path = options.elf.ok_or("missing --elf PATH")?;
    let elf = fs::read(elf_path)?;
    let rom = Riscv2zisk::new(&elf)
        .run()
        .map_err(|err| format!("ELF-to-ROM conversion failed: {err}"))?;

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();
    writer.write_all(READY)?;
    writer.flush()?;

    while let Some(input) = read_request(&mut reader)? {
        match execute(&rom, input) {
            Ok(success) => write_response(
                &mut writer,
                0,
                success.steps,
                success.duration_nanos,
                &success.output,
            )?,
            Err(reason) => write_response(&mut writer, 1, 0, 0, reason.as_bytes())?,
        }
        writer.flush()?;
    }
    Ok(())
}

fn execute(rom: &ZiskRom, input: Vec<u8>) -> Result<Success, String> {
    let start = Instant::now();
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
    let duration_nanos = start.elapsed().as_nanos().try_into().unwrap_or(u64::MAX);
    Ok(Success {
        output: result.0,
        steps: result.1,
        duration_nanos,
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
    steps: u64,
    duration_nanos: u64,
    payload: &[u8],
) -> io::Result<()> {
    let mut header = [0_u8; RESPONSE_HEADER_BYTES];
    header[0] = status;
    header[8..16].copy_from_slice(&steps.to_le_bytes());
    header[16..24].copy_from_slice(&duration_nanos.to_le_bytes());
    header[24..32].copy_from_slice(&(payload.len() as u64).to_le_bytes());
    writer.write_all(&header)?;
    writer.write_all(payload)
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
    fn request_stream_accepts_multiple_inputs_and_eof() {
        let bytes = [2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 3];
        let mut reader = &bytes[..];
        assert_eq!(read_request(&mut reader).unwrap(), Some(vec![1, 2]));
        assert_eq!(read_request(&mut reader).unwrap(), Some(vec![3]));
        assert_eq!(read_request(&mut reader).unwrap(), None);
    }

    #[test]
    fn response_header_is_fixed_width_little_endian() {
        let mut bytes = Vec::new();
        write_response(&mut bytes, 1, 42, 99, b"bad").unwrap();
        assert_eq!(bytes.len(), RESPONSE_HEADER_BYTES + 3);
        assert_eq!(bytes[0], 1);
        assert_eq!(u64::from_le_bytes(bytes[8..16].try_into().unwrap()), 42);
        assert_eq!(u64::from_le_bytes(bytes[16..24].try_into().unwrap()), 99);
        assert_eq!(u64::from_le_bytes(bytes[24..32].try_into().unwrap()), 3);
        assert_eq!(&bytes[32..], b"bad");
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
