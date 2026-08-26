use std::{
    io::{self, Read, Write},
    time::Instant,
};

pub const READY: &[u8; 8] = b"EVMZH001";
pub const RESPONSE_HEADER_BYTES: usize = 40;
const MAX_INPUT_BYTES: usize = 512 * 1024 * 1024;

pub struct Success {
    pub output: Vec<u8>,
    pub primary: u64,
    pub secondary: u64,
}

pub fn serve(mut execute: impl FnMut(Vec<u8>) -> Result<Success, String>) -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();
    writer.write_all(READY)?;
    writer.flush()?;

    while let Some(input) = read_request(&mut reader)? {
        let start = Instant::now();
        let result = execute(input);
        let duration_nanos = start.elapsed().as_nanos().try_into().unwrap_or(u64::MAX);
        match result {
            Ok(success) => write_response(
                &mut writer,
                0,
                success.primary,
                success.secondary,
                duration_nanos,
                &success.output,
            )?,
            Err(reason) => write_response(&mut writer, 1, 0, 0, duration_nanos, reason.as_bytes())?,
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
    primary: u64,
    secondary: u64,
    duration_nanos: u64,
    payload: &[u8],
) -> io::Result<()> {
    let mut header = [0_u8; RESPONSE_HEADER_BYTES];
    header[0] = status;
    header[8..16].copy_from_slice(&primary.to_le_bytes());
    header[16..24].copy_from_slice(&secondary.to_le_bytes());
    header[24..32].copy_from_slice(&duration_nanos.to_le_bytes());
    header[32..40].copy_from_slice(&(payload.len() as u64).to_le_bytes());
    writer.write_all(&header)?;
    writer.write_all(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_stream_accepts_multiple_inputs_and_eof() {
        let bytes = [2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 3];
        let mut reader = &bytes[..];
        assert_eq!(read_request(&mut reader).unwrap(), Some(vec![1, 2]));
        assert_eq!(read_request(&mut reader).unwrap(), Some(vec![3]));
        assert_eq!(read_request(&mut reader).unwrap(), None);
    }

    #[test]
    fn response_header_carries_two_counters_and_duration() {
        let mut bytes = Vec::new();
        write_response(&mut bytes, 1, 42, 84, 99, b"bad").unwrap();
        assert_eq!(bytes.len(), RESPONSE_HEADER_BYTES + 3);
        assert_eq!(bytes[0], 1);
        assert_eq!(u64::from_le_bytes(bytes[8..16].try_into().unwrap()), 42);
        assert_eq!(u64::from_le_bytes(bytes[16..24].try_into().unwrap()), 84);
        assert_eq!(u64::from_le_bytes(bytes[24..32].try_into().unwrap()), 99);
        assert_eq!(u64::from_le_bytes(bytes[32..40].try_into().unwrap()), 3);
        assert_eq!(&bytes[40..], b"bad");
    }
}
