const std = @import("std");

/// TLS negotiation preference from a connection URL or explicit config.
/// TLS itself is not implemented yet; parsing preserves the request so later
/// slices can enforce it.
pub const SslMode = enum {
    disable,
    allow,
    prefer,
    require,
    verify_ca,
    verify_full,

    pub fn parse(text: []const u8) !SslMode {
        if (std.ascii.eqlIgnoreCase(text, "disable")) return .disable;
        if (std.ascii.eqlIgnoreCase(text, "allow")) return .allow;
        if (std.ascii.eqlIgnoreCase(text, "prefer")) return .prefer;
        if (std.ascii.eqlIgnoreCase(text, "require")) return .require;
        if (std.ascii.eqlIgnoreCase(text, "verify-ca")) return .verify_ca;
        if (std.ascii.eqlIgnoreCase(text, "verify_ca")) return .verify_ca;
        if (std.ascii.eqlIgnoreCase(text, "verify-full")) return .verify_full;
        if (std.ascii.eqlIgnoreCase(text, "verify_full")) return .verify_full;
        return error.InvalidUrl;
    }

    pub fn asText(self: SslMode) []const u8 {
        return switch (self) {
            .disable => "disable",
            .allow => "allow",
            .prefer => "prefer",
            .require => "require",
            .verify_ca => "verify-ca",
            .verify_full => "verify-full",
        };
    }
};

/// Allocator-owned PostgreSQL connection configuration parsed from a URL or
/// built explicitly. Call `deinit` to free owned fields.
///
/// Password bytes are retained for authentication only. Formatters and error
/// paths must never include the password.
pub const Config = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    port: u16,
    user: []u8,
    password: []u8,
    database: []u8,
    ssl_mode: SslMode,
    application_name: []u8,
    /// Optional connect timeout in seconds from `connect_timeout=`.
    connect_timeout_secs: ?u32 = null,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        // Zero password before free so secrets do not linger in the heap longer
        // than necessary.
        @memset(self.password, 0);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        self.allocator.free(self.application_name);
        self.* = undefined;
    }

    /// Redacted summary suitable for logs. Never includes the password.
    pub fn formatRedacted(self: Config, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "postgres://{s}@{s}:{d}/{s}?sslmode={s}",
            .{ self.user, self.host, self.port, self.database, self.ssl_mode.asText() },
        );
    }
};

/// Parse a PostgreSQL URL into an owned `Config`.
///
/// Supported forms:
/// - `postgres://user:pass@host:port/db?sslmode=disable`
/// - `postgresql://user@host/db`
///
/// Path is treated as the database name (leading `/` stripped). Empty path
/// leaves database empty so callers can default it later. Percent-encoding is
/// decoded for user, password, host, database, and query values.
pub fn parse(allocator: std.mem.Allocator, url: []const u8) !Config {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    if (!std.ascii.eqlIgnoreCase(uri.scheme, "postgres") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "postgresql"))
    {
        return error.InvalidUrl;
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const host_raw = if (uri.host) |host_component|
        try componentToOwned(arena, host_component)
    else
        try arena.dupe(u8, "localhost");
    if (host_raw.len == 0) return error.InvalidUrl;

    const user_raw = if (uri.user) |user_component|
        try componentToOwned(arena, user_component)
    else
        try arena.dupe(u8, "");

    const password_raw = if (uri.password) |password_component|
        try componentToOwned(arena, password_component)
    else
        try arena.dupe(u8, "");

    const path_raw = try componentToOwned(arena, uri.path);
    const database_raw = stripLeadingSlash(path_raw);

    var ssl_mode: SslMode = .prefer;
    var application_name: []const u8 = "zsql";
    var connect_timeout_secs: ?u32 = null;

    if (uri.query) |query_component| {
        const query_raw = try componentToOwned(arena, query_component);
        var query_iter = std.mem.splitScalar(u8, query_raw, '&');
        while (query_iter.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidUrl;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.ascii.eqlIgnoreCase(key, "sslmode")) {
                ssl_mode = try SslMode.parse(value);
            } else if (std.ascii.eqlIgnoreCase(key, "application_name")) {
                application_name = value;
            } else if (std.ascii.eqlIgnoreCase(key, "connect_timeout")) {
                connect_timeout_secs = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidUrl;
            } else {
                // Unknown query keys are ignored so drivers can grow support
                // without breaking existing URLs.
            }
        }
    }

    const port = uri.port orelse 5432;

    // Copy out of the arena into long-lived allocator-owned buffers.
    const host = try allocator.dupe(u8, host_raw);
    errdefer allocator.free(host);
    const user = try allocator.dupe(u8, user_raw);
    errdefer allocator.free(user);
    const password = try allocator.dupe(u8, password_raw);
    errdefer {
        @memset(password, 0);
        allocator.free(password);
    }
    const database = try allocator.dupe(u8, database_raw);
    errdefer allocator.free(database);
    const application = try allocator.dupe(u8, application_name);
    errdefer allocator.free(application);

    return .{
        .allocator = allocator,
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
        .ssl_mode = ssl_mode,
        .application_name = application,
        .connect_timeout_secs = connect_timeout_secs,
    };
}

fn stripLeadingSlash(path: []const u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path[1..];
    return path;
}

fn componentToOwned(allocator: std.mem.Allocator, component: std.Uri.Component) ![]u8 {
    // toRawMaybeAlloc may return a slice into the original URI (no free) or an
    // arena allocation. Always dupe so callers own a stable buffer.
    const raw = try component.toRawMaybeAlloc(allocator);
    return try allocator.dupe(u8, raw);
}

test "parse postgres URL with auth host port database and params" {
    var config = try parse(
        std.testing.allocator,
        "postgres://ada:s3cret%21@db.example:6543/appdb?sslmode=disable&application_name=zsql-test&connect_timeout=10",
    );
    defer config.deinit();

    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(u16, 6543), config.port);
    try std.testing.expectEqualStrings("ada", config.user);
    try std.testing.expectEqualStrings("s3cret!", config.password);
    try std.testing.expectEqualStrings("appdb", config.database);
    try std.testing.expect(config.ssl_mode == .disable);
    try std.testing.expectEqualStrings("zsql-test", config.application_name);
    try std.testing.expectEqual(@as(?u32, 10), config.connect_timeout_secs);
}

test "parse postgresql scheme defaults and percent-decoded user" {
    var config = try parse(
        std.testing.allocator,
        "postgresql://a%40b@localhost/my%2Fdb",
    );
    defer config.deinit();

    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 5432), config.port);
    try std.testing.expectEqualStrings("a@b", config.user);
    try std.testing.expectEqualStrings("", config.password);
    try std.testing.expectEqualStrings("my/db", config.database);
    try std.testing.expect(config.ssl_mode == .prefer);
    try std.testing.expectEqualStrings("zsql", config.application_name);
    try std.testing.expectEqual(@as(?u32, null), config.connect_timeout_secs);
}

test "parse rejects non-postgres schemes and bad sslmode" {
    try std.testing.expectError(error.InvalidUrl, parse(std.testing.allocator, "mysql://localhost/db"));
    try std.testing.expectError(error.InvalidUrl, parse(std.testing.allocator, "postgres://localhost/db?sslmode=nope"));
    try std.testing.expectError(error.InvalidUrl, parse(std.testing.allocator, "not a url"));
}

test "redacted format never includes password" {
    var config = try parse(
        std.testing.allocator,
        "postgres://ada:super-secret@localhost:5432/app?sslmode=require",
    );
    defer config.deinit();

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try config.formatRedacted(&writer);
    const text = writer.buffered();
    try std.testing.expectEqualStrings(
        "postgres://ada@localhost:5432/app?sslmode=require",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "super-secret") == null);
}
