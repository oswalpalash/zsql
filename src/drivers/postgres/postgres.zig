//! Native PostgreSQL driver for zsql.
//!
//! This module intentionally starts with pure-Zig protocol and URL helpers so
//! unit tests run without a live server or libpq. TCP connect and full query
//! execution land in subsequent slices.

pub const url = @import("url.zig");
pub const protocol = @import("protocol.zig");

pub const Config = url.Config;
pub const SslMode = url.SslMode;
pub const parseUrl = url.parse;

pub const enabled = true;

test {
    _ = url;
    _ = protocol;
}
