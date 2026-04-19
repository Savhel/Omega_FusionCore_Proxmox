//! Protocole binaire TCP pour la communication agent ↔ store.
//!
//! # Format de trame
//!
//! ```text
//! Offset  Size  Field
//! ------  ----  -----
//!   0       2   magic       0x524D ("RM")
//!   2       1   opcode      voir enum Opcode
//!   3       1   flags       voir FLAGS_*
//!   4       4   vm_id       u32 big-endian  (0 si non applicable)
//!   8       8   page_id     u64 big-endian  (0 si non applicable)
//!  16       4   payload_len u32 big-endian  (octets qui suivent)
//!  20       *   payload     payload_len octets
//! ```
//!
//! Taille totale en-tête : 20 octets.
//! Taille maximale payload : 2 × PAGE_SIZE (8192) — protège contre les allocations abusives.

use std::io;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const MAGIC: u16 = 0x524D;
pub const PAGE_SIZE: usize = 4096;
pub const HEADER_SIZE: usize = 20;
pub const MAX_PAYLOAD: usize = PAGE_SIZE * 2;

/// Bit 0 du champ flags : la page est compressée (non utilisé en V1, réservé V2).
pub const FLAG_COMPRESSED: u8 = 0x01;

/// Opcodes du protocole.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opcode {
    // Requêtes client → store
    Ping = 0x01,
    PutPage = 0x10,
    GetPage = 0x11,
    DeletePage = 0x12,
    StatsRequest = 0x20,

    // Réponses store → client
    Pong = 0x02,
    Ok = 0x80,
    NotFound = 0x81,
    Error = 0x82,
    StatsResponse = 0x21,
}

impl TryFrom<u8> for Opcode {
    type Error = io::Error;

    fn try_from(v: u8) -> Result<Self, io::Error> {
        match v {
            0x01 => Ok(Opcode::Ping),
            0x02 => Ok(Opcode::Pong),
            0x10 => Ok(Opcode::PutPage),
            0x11 => Ok(Opcode::GetPage),
            0x12 => Ok(Opcode::DeletePage),
            0x20 => Ok(Opcode::StatsRequest),
            0x21 => Ok(Opcode::StatsResponse),
            0x80 => Ok(Opcode::Ok),
            0x81 => Ok(Opcode::NotFound),
            0x82 => Ok(Opcode::Error),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("opcode inconnu : 0x{v:02x}"),
            )),
        }
    }
}

/// Un message complet (en-tête + payload déjà lu).
#[derive(Debug, Clone)]
pub struct Message {
    pub opcode: Opcode,
    pub flags: u8,
    pub vm_id: u32,
    pub page_id: u64,
    pub payload: Vec<u8>,
}

impl Message {
    // ------------------------------------------------------------------ constructeurs

    pub fn new(opcode: Opcode, vm_id: u32, page_id: u64, payload: Vec<u8>) -> Self {
        Self {
            opcode,
            flags: 0,
            vm_id,
            page_id,
            payload,
        }
    }

    pub fn ping() -> Self {
        Self::new(Opcode::Ping, 0, 0, vec![])
    }

    pub fn pong() -> Self {
        Self::new(Opcode::Pong, 0, 0, vec![])
    }

    pub fn ok(vm_id: u32, page_id: u64) -> Self {
        Self::new(Opcode::Ok, vm_id, page_id, vec![])
    }

    pub fn not_found(vm_id: u32, page_id: u64) -> Self {
        Self::new(Opcode::NotFound, vm_id, page_id, vec![])
    }

    pub fn error_msg(detail: &str) -> Self {
        Self::new(Opcode::Error, 0, 0, detail.as_bytes().to_vec())
    }

    pub fn put_page(vm_id: u32, page_id: u64, data: Vec<u8>) -> Self {
        assert_eq!(data.len(), PAGE_SIZE, "PUT_PAGE : taille page incorrecte");
        Self::new(Opcode::PutPage, vm_id, page_id, data)
    }

    pub fn get_page(vm_id: u32, page_id: u64) -> Self {
        Self::new(Opcode::GetPage, vm_id, page_id, vec![])
    }

    pub fn delete_page(vm_id: u32, page_id: u64) -> Self {
        Self::new(Opcode::DeletePage, vm_id, page_id, vec![])
    }

    pub fn stats_request() -> Self {
        Self::new(Opcode::StatsRequest, 0, 0, vec![])
    }

    pub fn stats_response(json: String) -> Self {
        Self::new(Opcode::StatsResponse, 0, 0, json.into_bytes())
    }

    // ------------------------------------------------------------------ I/O async

    /// Lit un message complet depuis un stream asynchrone.
    pub async fn read_from<R: AsyncReadExt + Unpin>(reader: &mut R) -> io::Result<Self> {
        let mut header = [0u8; HEADER_SIZE];
        reader.read_exact(&mut header).await?;

        let magic = u16::from_be_bytes([header[0], header[1]]);
        if magic != MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("magic incorrect : 0x{magic:04x}"),
            ));
        }

        let opcode = Opcode::try_from(header[2])?;
        let flags = header[3];
        let vm_id = u32::from_be_bytes(header[4..8].try_into().unwrap());
        let page_id = u64::from_be_bytes(header[8..16].try_into().unwrap());
        let payload_len = u32::from_be_bytes(header[16..20].try_into().unwrap()) as usize;

        if payload_len > MAX_PAYLOAD {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("payload trop grand : {payload_len} octets"),
            ));
        }

        let mut payload = vec![0u8; payload_len];
        if payload_len > 0 {
            reader.read_exact(&mut payload).await?;
        }

        Ok(Self {
            opcode,
            flags,
            vm_id,
            page_id,
            payload,
        })
    }

    /// Écrit un message complet sur un stream asynchrone.
    pub async fn write_to<W: AsyncWriteExt + Unpin>(&self, writer: &mut W) -> io::Result<()> {
        let payload_len = self.payload.len() as u32;
        let mut buf = Vec::with_capacity(HEADER_SIZE + self.payload.len());

        buf.extend_from_slice(&MAGIC.to_be_bytes());
        buf.push(self.opcode as u8);
        buf.push(self.flags);
        buf.extend_from_slice(&self.vm_id.to_be_bytes());
        buf.extend_from_slice(&self.page_id.to_be_bytes());
        buf.extend_from_slice(&payload_len.to_be_bytes());
        buf.extend_from_slice(&self.payload);

        writer.write_all(&buf).await?;
        writer.flush().await
    }
}

// ---------------------------------------------------------------------------------
// Tests unitaires du protocole
// ---------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::BufReader;

    async fn roundtrip(msg: Message) -> Message {
        let mut buf: Vec<u8> = Vec::new();
        msg.write_to(&mut buf).await.unwrap();
        let mut reader = BufReader::new(buf.as_slice());
        Message::read_from(&mut reader).await.unwrap()
    }

    #[tokio::test]
    async fn test_ping_roundtrip() {
        let msg = Message::ping();
        let got = roundtrip(msg).await;
        assert_eq!(got.opcode as u8, Opcode::Ping as u8);
        assert!(got.payload.is_empty());
    }

    #[tokio::test]
    async fn test_put_page_roundtrip() {
        let data = vec![0xABu8; PAGE_SIZE];
        let msg = Message::put_page(42, 1234, data.clone());
        let got = roundtrip(msg).await;
        assert_eq!(got.opcode as u8, Opcode::PutPage as u8);
        assert_eq!(got.vm_id, 42);
        assert_eq!(got.page_id, 1234);
        assert_eq!(got.payload, data);
    }

    #[tokio::test]
    async fn test_bad_magic() {
        let mut buf = vec![
            0xDEu8,
            0xAD,
            Opcode::Ping as u8,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let mut reader = tokio::io::BufReader::new(buf.as_slice());
        let res = Message::read_from(&mut reader).await;
        assert!(res.is_err());
    }
}
