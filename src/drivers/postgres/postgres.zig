//! Native PostgreSQL driver for zsql.
//!
//! Pure-Zig URL parsing, protocol framing, MD5/cleartext auth helpers, and a
//! startup handshake over TCP. No libpq. Live query execution lands next.
//!
//! Integration: set `ZSQL_PG_URL` to exercise a real handshake; CI stays green
//! without a Postgres server.

pub const url = @import("url.zig");
pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const conn = @import("conn.zig");

pub const Config = url.Config;
pub const SslMode = url.SslMode;
pub const parseUrl = url.parse;
pub const Conn = conn.Conn;

pub const enabled = true;

test {
    _ = url;
    _ = protocol;
    _ = auth;
    _ = conn;
}
