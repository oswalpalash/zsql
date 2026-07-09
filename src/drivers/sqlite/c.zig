//! Explicit SQLite C ABI bindings.
//!
//! Prefer these over `@cImport` so Linux CI does not depend on clang
//! translation of system headers, which has been a source of ABI crashes.

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ERROR: c_int = 1;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_LOCKED: c_int = 6;
pub const SQLITE_MISUSE: c_int = 21;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;
pub const SQLITE_OPEN_MEMORY: c_int = 0x00000080;
pub const SQLITE_OPEN_NOMUTEX: c_int = 0x00008000;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

/// Destructor sentinel: SQLite makes its own private copy of the data.
pub const SQLITE_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
/// Destructor sentinel: data is static / owned by the caller for the statement lifetime.
pub const SQLITE_STATIC: ?*const fn (?*anyopaque) callconv(.c) void = null;

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: *?*sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;

pub extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;

pub extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*?[*:0]const u8,
) c_int;

pub extern fn sqlite3_finalize(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_step(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_clear_bindings(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_db_handle(pStmt: ?*sqlite3_stmt) ?*sqlite3;

pub extern fn sqlite3_bind_parameter_count(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_parameter_index(pStmt: ?*sqlite3_stmt, zName: [*:0]const u8) c_int;
pub extern fn sqlite3_bind_null(pStmt: ?*sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_int(pStmt: ?*sqlite3_stmt, index: c_int, value: c_int) c_int;
pub extern fn sqlite3_bind_int64(pStmt: ?*sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(pStmt: ?*sqlite3_stmt, index: c_int, value: f64) c_int;
pub extern fn sqlite3_bind_text(
    pStmt: ?*sqlite3_stmt,
    index: c_int,
    value: [*]const u8,
    n: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;
pub extern fn sqlite3_bind_blob(
    pStmt: ?*sqlite3_stmt,
    index: c_int,
    value: ?*const anyopaque,
    n: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;

pub extern fn sqlite3_column_count(pStmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_name(pStmt: ?*sqlite3_stmt, N: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_type(pStmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern fn sqlite3_column_int64(pStmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern fn sqlite3_column_double(pStmt: ?*sqlite3_stmt, iCol: c_int) f64;
pub extern fn sqlite3_column_text(pStmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_blob(pStmt: ?*sqlite3_stmt, iCol: c_int) ?*const anyopaque;
pub extern fn sqlite3_column_bytes(pStmt: ?*sqlite3_stmt, iCol: c_int) c_int;

pub extern fn sqlite3_changes(db: ?*sqlite3) c_int;
pub extern fn sqlite3_changes64(db: ?*sqlite3) i64;
pub extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;

pub extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;

pub extern fn sqlite3_expanded_sql(pStmt: ?*sqlite3_stmt) ?[*:0]u8;
pub extern fn sqlite3_free(p: ?*anyopaque) void;
