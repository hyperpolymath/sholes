// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Minimal Git pkt-line framing for the long-running filter protocol.

use std::io::{self, ErrorKind, Read, Write};

/// A Git packet-line control or data record.
#[derive(Debug, Eq, PartialEq)]
pub enum Packet {
    /// A normal packet containing its payload without the four-byte header.
    Data(Vec<u8>),
    /// `0000`, terminating a section.
    Flush,
    /// `0001`, the protocol delimiter packet.
    Delimiter,
    /// `0002`, the response-end packet.
    ResponseEnd,
}

fn parse_hex_digit(byte: u8) -> Option<usize> {
    match byte {
        b'0'..=b'9' => Some((byte - b'0') as usize),
        b'a'..=b'f' => Some((byte - b'a' + 10) as usize),
        b'A'..=b'F' => Some((byte - b'A' + 10) as usize),
        _ => None,
    }
}

fn parse_length(header: [u8; 4]) -> io::Result<usize> {
    let mut length = 0;
    for digit in header {
        length = (length << 4)
            .checked_add(parse_hex_digit(digit).ok_or_else(|| {
                io::Error::new(ErrorKind::InvalidData, "invalid Git pkt-line length")
            })?)
            .ok_or_else(|| io::Error::new(ErrorKind::InvalidData, "pkt-line length overflow"))?;
    }
    Ok(length)
}

/// Read one packet, returning `None` only at a clean EOF before a header.
pub fn read_packet<R: Read>(reader: &mut R) -> io::Result<Option<Packet>> {
    let mut header = [0; 4];
    let mut first = [0; 1];
    let count = reader.read(&mut first)?;
    if count == 0 {
        return Ok(None);
    }
    header[0] = first[0];
    reader.read_exact(&mut header[1..])?;
    let length = parse_length(header)?;
    match length {
        0 => Ok(Some(Packet::Flush)),
        1 => Ok(Some(Packet::Delimiter)),
        2 => Ok(Some(Packet::ResponseEnd)),
        3 => Err(io::Error::new(
            ErrorKind::InvalidData,
            "pkt-line length 0003 is reserved",
        )),
        length => {
            // Git's maximum normal pkt-line length is 0xfff0 including header.
            if length > 0xfff0 {
                return Err(io::Error::new(ErrorKind::InvalidData, "pkt-line is too large"));
            }
            let mut payload = vec![0; length - 4];
            reader.read_exact(&mut payload)?;
            Ok(Some(Packet::Data(payload)))
        }
    }
}

/// Write one or more normal packets, splitting large content records.
pub fn write_data<W: Write>(writer: &mut W, data: &[u8]) -> io::Result<()> {
    // 0xfff0 is the largest complete pkt-line; four bytes are its header.
    const MAX_PAYLOAD: usize = 0xfff0 - 4;
    if data.is_empty() {
        return Ok(());
    }
    for chunk in data.chunks(MAX_PAYLOAD) {
        let length = chunk.len() + 4;
        write!(writer, "{length:04x}")?;
        writer.write_all(chunk)?;
    }
    Ok(())
}

/// Write a section terminator (`0000`).
pub fn write_flush<W: Write>(writer: &mut W) -> io::Result<()> {
    writer.write_all(b"0000")
}

#[cfg(test)]
mod tests {
    use super::{read_packet, write_data, write_flush, Packet};

    #[test]
    fn frames_and_reads_binary_data() {
        let payload = [0, 1, 13, 10, 255];
        let mut wire = Vec::new();
        write_data(&mut wire, &payload).unwrap();
        write_flush(&mut wire).unwrap();
        let mut cursor = wire.as_slice();
        assert_eq!(read_packet(&mut cursor).unwrap(), Some(Packet::Data(payload.to_vec())));
        assert_eq!(read_packet(&mut cursor).unwrap(), Some(Packet::Flush));
    }
}
