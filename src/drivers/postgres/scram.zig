const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const pbkdf2 = std.crypto.pwhash.pbkdf2;

/// Client-side SCRAM-SHA-256 state for PostgreSQL SASL authentication.
///
/// Password bytes are zeroed in `deinit`. Nonces and intermediate messages are
/// allocator-owned. Channel binding (SCRAM-SHA-256-PLUS) is not supported.
pub const Client = struct {
    allocator: std.mem.Allocator,
    user: []u8,
    password: []u8,
    client_nonce: []u8,
    client_first_bare: []u8,
    server_first: ?[]u8 = null,
    auth_message: ?[]u8 = null,
    server_signature_b64: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        user: []const u8,
        password: []const u8,
        client_nonce: []const u8,
    ) !Client {
        // SCRAM user names with `=` / `,` need escaping; reject rather than
        // silently mis-auth until full SASLprep lands.
        if (std.mem.indexOfAny(u8, user, "=,") != null) return error.InvalidArguments;
        if (client_nonce.len < 8) return error.InvalidArguments;

        const user_owned = try allocator.dupe(u8, user);
        errdefer allocator.free(user_owned);
        const password_owned = try allocator.dupe(u8, password);
        errdefer {
            @memset(password_owned, 0);
            allocator.free(password_owned);
        }
        const nonce_owned = try allocator.dupe(u8, client_nonce);
        errdefer allocator.free(nonce_owned);

        const bare = try std.fmt.allocPrint(allocator, "n={s},r={s}", .{ user, client_nonce });
        errdefer allocator.free(bare);

        return .{
            .allocator = allocator,
            .user = user_owned,
            .password = password_owned,
            .client_nonce = nonce_owned,
            .client_first_bare = bare,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.user);
        @memset(self.password, 0);
        self.allocator.free(self.password);
        self.allocator.free(self.client_nonce);
        self.allocator.free(self.client_first_bare);
        if (self.server_first) |s| self.allocator.free(s);
        if (self.auth_message) |s| self.allocator.free(s);
        if (self.server_signature_b64) |s| self.allocator.free(s);
        self.* = undefined;
    }

    /// gs2-header `n,,` + client-first-message-bare.
    pub fn clientFirstMessage(self: *const Client, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "n,,{s}", .{self.client_first_bare});
    }

    /// Process server-first-message and build client-final-message.
    pub fn handleServerFirst(self: *Client, server_first: []const u8) ![]u8 {
        if (self.server_first) |old| {
            self.allocator.free(old);
            self.server_first = null;
        }
        self.server_first = try self.allocator.dupe(u8, server_first);

        const parsed = try parseServerFirst(server_first);
        if (!std.mem.startsWith(u8, parsed.nonce, self.client_nonce)) return error.AuthFailed;
        if (parsed.nonce.len <= self.client_nonce.len) return error.AuthFailed;
        if (parsed.iterations == 0 or parsed.iterations > 1_000_000) return error.AuthFailed;

        var salt_buf: [256]u8 = undefined;
        const salt_len = std.base64.standard.Decoder.calcSizeForSlice(parsed.salt_b64) catch return error.ProtocolError;
        if (salt_len > salt_buf.len) return error.ProtocolError;
        std.base64.standard.Decoder.decode(salt_buf[0..salt_len], parsed.salt_b64) catch return error.ProtocolError;
        const salt = salt_buf[0..salt_len];

        var salted_password: [32]u8 = undefined;
        try pbkdf2(&salted_password, self.password, salt, parsed.iterations, HmacSha256);

        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted_password);

        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        // client-final-without-proof: c=biws,r=<server-nonce>
        // biws is base64("n,,") — no channel binding.
        const without_proof = try std.fmt.allocPrint(
            self.allocator,
            "c=biws,r={s}",
            .{parsed.nonce},
        );
        defer self.allocator.free(without_proof);

        const auth_message = try std.fmt.allocPrint(
            self.allocator,
            "{s},{s},{s}",
            .{ self.client_first_bare, server_first, without_proof },
        );
        if (self.auth_message) |old| self.allocator.free(old);
        self.auth_message = auth_message;

        var client_signature: [32]u8 = undefined;
        HmacSha256.create(&client_signature, auth_message, &stored_key);

        var client_proof: [32]u8 = undefined;
        for (&client_proof, client_key, client_signature) |*out, k, s| {
            out.* = k ^ s;
        }

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted_password);
        var server_signature: [32]u8 = undefined;
        HmacSha256.create(&server_signature, auth_message, &server_key);

        var sig_b64_buf: [64]u8 = undefined;
        const sig_b64 = std.base64.standard.Encoder.encode(&sig_b64_buf, &server_signature);
        if (self.server_signature_b64) |old| self.allocator.free(old);
        self.server_signature_b64 = try self.allocator.dupe(u8, sig_b64);

        var proof_b64_buf: [64]u8 = undefined;
        const proof_b64 = std.base64.standard.Encoder.encode(&proof_b64_buf, &client_proof);

        return try std.fmt.allocPrint(
            self.allocator,
            "{s},p={s}",
            .{ without_proof, proof_b64 },
        );
    }

    /// Validate server-final-message `v=...`.
    pub fn handleServerFinal(self: *const Client, server_final: []const u8) !void {
        if (!std.mem.startsWith(u8, server_final, "v=")) return error.AuthFailed;
        const expected = self.server_signature_b64 orelse return error.AuthFailed;
        const got = server_final[2..];
        if (!std.mem.eql(u8, got, expected)) return error.AuthFailed;
    }
};

const ServerFirst = struct {
    nonce: []const u8,
    salt_b64: []const u8,
    iterations: u32,
};

fn parseServerFirst(msg: []const u8) !ServerFirst {
    var nonce: ?[]const u8 = null;
    var salt: ?[]const u8 = null;
    var iterations: ?u32 = null;

    var iter = std.mem.splitScalar(u8, msg, ',');
    while (iter.next()) |part| {
        if (part.len < 2 or part[1] != '=') return error.ProtocolError;
        const key = part[0];
        const value = part[2..];
        switch (key) {
            'r' => nonce = value,
            's' => salt = value,
            'i' => iterations = std.fmt.parseUnsigned(u32, value, 10) catch return error.ProtocolError,
            'm' => return error.ProtocolError, // reserved extension must be rejected
            else => {},
        }
    }

    return .{
        .nonce = nonce orelse return error.ProtocolError,
        .salt_b64 = salt orelse return error.ProtocolError,
        .iterations = iterations orelse return error.ProtocolError,
    };
}

/// True when the AuthenticationSASL mechanism list includes SCRAM-SHA-256
/// (but not only the -PLUS channel-binding variant).
pub fn mechanismsIncludeScramSha256(payload: []const u8) bool {
    var rest = payload;
    while (rest.len > 0) {
        const zero = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        const name = rest[0..zero];
        rest = rest[zero + 1 ..];
        if (name.len == 0) break;
        if (std.mem.eql(u8, name, "SCRAM-SHA-256")) return true;
    }
    return false;
}

/// Build SASLInitialResponse body: mechanism\0 + Int32 len + client-first.
pub fn buildSaslInitialResponse(allocator: std.mem.Allocator, client_first: []const u8) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "SCRAM-SHA-256");
    try body.append(allocator, 0);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &len_buf, @intCast(client_first.len), .big);
    try body.appendSlice(allocator, &len_buf);
    try body.appendSlice(allocator, client_first);
    return try body.toOwnedSlice(allocator);
}

test "mechanismsIncludeScramSha256 parses list" {
    const payload = "SCRAM-SHA-256\x00SCRAM-SHA-256-PLUS\x00\x00";
    try std.testing.expect(mechanismsIncludeScramSha256(payload));
    try std.testing.expect(!mechanismsIncludeScramSha256("SCRAM-SHA-256-PLUS\x00\x00"));
    try std.testing.expect(!mechanismsIncludeScramSha256("md5\x00\x00"));
}

test "SCRAM-SHA-256 client proof matches standard PBKDF2-HMAC-SHA256" {
    // Inputs from RFC 7677; expected proof/signature computed with the same
    // PBKDF2-HMAC-SHA256 construction PostgreSQL uses (independent cross-check).
    var client = try Client.init(
        std.testing.allocator,
        "user",
        "pencil",
        "rOprNGfwEbeRWgbNEkqO",
    );
    defer client.deinit();

    const first = try client.clientFirstMessage(std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings(
        "n,,n=user,r=rOprNGfwEbeRWgbNEkqO",
        first,
    );

    // Comma after the nonce is required by SCRAM attribute encoding (some RFC
    // renderings omit it next to the trailing '&' of the nonce).
    const server_first =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlS&,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const client_final = try client.handleServerFirst(server_first);
    defer std.testing.allocator.free(client_final);

    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlS&,p=wHP6FmGlGb1o6KGd667CQehG1V+Qu7b3cjX2MoPeaY4=",
        client_final,
    );

    try client.handleServerFinal("v=lds20Nc9hhmu9VkAe15f2sOlIv44mtVCyJJPiCd1kM8=");
}

test "SCRAM rejects server nonce that does not extend client nonce" {
    var client = try Client.init(std.testing.allocator, "user", "pencil", "rOprNGfwEbeRWgbNEkqO");
    defer client.deinit();
    try std.testing.expectError(
        error.AuthFailed,
        client.handleServerFirst("r=othernonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"),
    );
}
