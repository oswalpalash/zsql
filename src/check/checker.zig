const std = @import("std");
const inspect = @import("inspect.zig");
const params = @import("../core/params.zig");

pub const CheckError = error{
    PlaceholderCountMismatch,
    UnknownNamedParameter,
    ExtraNamedParameter,
    UnknownTable,
    UnknownColumn,
    AmbiguousColumn,
    TypeMismatch,
    NullabilityMismatch,
    InvalidSql,
    TooManyTables,
    TooManyProjections,
};

pub const ArgSpec = struct {
    name: []const u8,
};

pub const FieldSpec = struct {
    name: []const u8,
    /// Optional: when set, must match a schema column type name (case-insensitive).
    type_name: ?[]const u8 = null,
    nullable: bool = false,
};

/// A table reference discovered in SQL or supplied by the caller.
/// `alias` is optional (FROM users u / FROM users AS u).
const TableRef = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

const Projection = struct {
    /// Unqualified column name, or the part after the last `.`.
    column: []const u8,
    /// Optional table or alias qualifier before `.`.
    qualifier: ?[]const u8 = null,
    /// True for `*` or `table.*` — skipped for type checks, still requires known table.
    is_star: bool = false,
};

const max_tables = 16;
const max_projections = 64;

/// Lightweight offline SQL check against a schema artifact and parameter/row specs.
///
/// Validates named placeholders and that each result field exists on the named
/// table(s). Supports multi-table / JOIN scope via `from_tables`, qualified
/// column names (`users.email` / `u.email`), optional SELECT-list projection
/// checks (`check_projections`), and optional WHERE column checks (`check_where`).
///
/// Values are never required at check time. Allocation-free.
pub fn checkQuery(options: struct {
    sql: []const u8,
    schema: inspect.Schema,
    args: []const ArgSpec = &.{},
    row: []const FieldSpec = &.{},
    /// Single-table scope (legacy / common case).
    from_table: ?[]const u8 = null,
    /// Multi-table scope for JOIN checks. When non-empty, overrides `from_table`.
    from_tables: []const []const u8 = &.{},
    /// When true, parse a simple SELECT list and ensure each bare/qualified
    /// projection resolves against the table scope (and schema).
    check_projections: bool = false,
    /// When true, parse simple WHERE column references and resolve them against
    /// the table scope. Function calls, SQL keywords, casts, and bind markers
    /// are skipped. Opt-in so complex expressions do not surprise callers.
    check_where: bool = false,
}) CheckError!void {
    const summary = params.summarize(options.sql) catch return error.InvalidSql;

    if (summary.named > 0) {
        var it = params.Iterator.init(options.sql);
        while (it.next() catch return error.InvalidSql) |ph| {
            if (ph.style != .named) continue;
            const name = stripMarker(ph.name);
            var found = false;
            for (options.args) |arg| {
                if (std.mem.eql(u8, arg.name, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownNamedParameter;
        }
        for (options.args) |arg| {
            var used = false;
            var it2 = params.Iterator.init(options.sql);
            while (it2.next() catch return error.InvalidSql) |ph| {
                if (ph.style != .named) continue;
                if (std.mem.eql(u8, stripMarker(ph.name), arg.name)) {
                    used = true;
                    break;
                }
            }
            if (!used) return error.ExtraNamedParameter;
        }
    } else if (options.args.len != 0) {
        if (summary.expectedBindCount() != options.args.len) return error.PlaceholderCountMismatch;
    }

    var table_buf: [max_tables]TableRef = undefined;
    const scope = try resolveTableScope(options.sql, options.schema, options.from_table, options.from_tables, &table_buf);

    if (options.row.len != 0) {
        if (scope.len == 0) {
            // Fall back: single-table schema or error on unknown columns when no scope.
            if (options.schema.tables.len == 1) {
                const table = options.schema.tables[0];
                for (options.row) |field| {
                    const resolved = try resolveField(options.schema, &.{.{ .name = table.name }}, field.name);
                    try checkFieldAgainstColumn(field, resolved.col);
                }
            } else {
                for (options.row) |field| {
                    // Unscoped multi-table schema: only accept fully qualified names
                    // that match a schema table, or unique unqualified names.
                    const resolved = try resolveField(options.schema, schemaAsScope(options.schema, &table_buf), field.name);
                    try checkFieldAgainstColumn(field, resolved.col);
                }
            }
        } else {
            for (options.row) |field| {
                const resolved = try resolveField(options.schema, scope, field.name);
                try checkFieldAgainstColumn(field, resolved.col);
            }
        }
    }

    const resolve_scope = if (scope.len != 0)
        scope
    else
        schemaAsScope(options.schema, &table_buf);

    if (options.check_projections) {
        var proj_buf: [max_projections]Projection = undefined;
        const projs = try parseSelectProjections(options.sql, &proj_buf);
        for (projs) |proj| {
            if (proj.is_star) {
                if (proj.qualifier) |q| {
                    // table.* — qualifier must resolve to a known table/alias in scope.
                    _ = findTableRef(resolve_scope, q) orelse return error.UnknownTable;
                }
                continue;
            }
            if (proj.qualifier) |q| {
                _ = try resolveQualified(options.schema, resolve_scope, q, proj.column);
            } else {
                _ = try resolveField(options.schema, resolve_scope, proj.column);
            }
        }
    }

    if (options.check_where) {
        var where_buf: [max_projections]Projection = undefined;
        const refs = try parseWhereColumnRefs(options.sql, &where_buf);
        for (refs) |ref| {
            if (ref.qualifier) |q| {
                _ = try resolveQualified(options.schema, resolve_scope, q, ref.column);
            } else {
                _ = try resolveField(options.schema, resolve_scope, ref.column);
            }
        }
    }
}

fn schemaAsScope(schema: inspect.Schema, buf: *[max_tables]TableRef) []const TableRef {
    const n = @min(schema.tables.len, max_tables);
    for (schema.tables[0..n], 0..) |t, i| {
        buf[i] = .{ .name = t.name };
    }
    return buf[0..n];
}

fn resolveTableScope(
    sql: []const u8,
    schema: inspect.Schema,
    from_table: ?[]const u8,
    from_tables: []const []const u8,
    buf: *[max_tables]TableRef,
) CheckError![]const TableRef {
    if (from_tables.len != 0) {
        if (from_tables.len > max_tables) return error.TooManyTables;
        for (from_tables, 0..) |name, i| {
            if (findTable(schema, name) == null) return error.UnknownTable;
            buf[i] = .{ .name = name };
        }
        return buf[0..from_tables.len];
    }
    if (from_table) |name| {
        if (findTable(schema, name) == null) return error.UnknownTable;
        buf[0] = .{ .name = name };
        return buf[0..1];
    }
    // Auto-extract FROM / JOIN table refs when the caller did not pin scope.
    return parseFromJoinTables(sql, schema, buf);
}

const ResolvedColumn = struct {
    table: inspect.Table,
    col: inspect.Column,
};

fn checkFieldAgainstColumn(field: FieldSpec, col: inspect.Column) CheckError!void {
    if (field.type_name) |want| {
        if (!typesCompatible(want, col.type_name)) return error.TypeMismatch;
    }
    if (!field.nullable and col.nullable) return error.NullabilityMismatch;
}

fn resolveField(schema: inspect.Schema, scope: []const TableRef, field_name: []const u8) CheckError!ResolvedColumn {
    if (std.mem.indexOfScalar(u8, field_name, '.')) |dot| {
        const qual = field_name[0..dot];
        const col_name = field_name[dot + 1 ..];
        if (col_name.len == 0) return error.UnknownColumn;
        return resolveQualified(schema, scope, qual, col_name);
    }
    return resolveUnqualified(schema, scope, field_name);
}

fn resolveQualified(
    schema: inspect.Schema,
    scope: []const TableRef,
    qual: []const u8,
    col_name: []const u8,
) CheckError!ResolvedColumn {
    const ref = findTableRef(scope, qual) orelse {
        // Allow direct schema table name even if not in explicit scope.
        if (findTable(schema, qual)) |table| {
            const col = findColumn(table, col_name) orelse return error.UnknownColumn;
            return .{ .table = table, .col = col };
        }
        return error.UnknownTable;
    };
    const table = findTable(schema, ref.name) orelse return error.UnknownTable;
    const col = findColumn(table, col_name) orelse return error.UnknownColumn;
    return .{ .table = table, .col = col };
}

fn resolveUnqualified(schema: inspect.Schema, scope: []const TableRef, col_name: []const u8) CheckError!ResolvedColumn {
    var found: ?ResolvedColumn = null;
    for (scope) |ref| {
        const table = findTable(schema, ref.name) orelse continue;
        if (findColumn(table, col_name)) |col| {
            if (found != null) return error.AmbiguousColumn;
            found = .{ .table = table, .col = col };
        }
    }
    return found orelse error.UnknownColumn;
}

fn findTableRef(scope: []const TableRef, qual: []const u8) ?TableRef {
    for (scope) |ref| {
        if (std.mem.eql(u8, ref.name, qual)) return ref;
        if (ref.alias) |a| {
            if (std.mem.eql(u8, a, qual)) return ref;
        }
    }
    return null;
}

fn stripMarker(name: []const u8) []const u8 {
    if (name.len == 0) return name;
    return switch (name[0]) {
        ':', '@', '$' => name[1..],
        else => name,
    };
}

fn findTable(schema: inspect.Schema, name: []const u8) ?inspect.Table {
    for (schema.tables) |table| {
        if (std.mem.eql(u8, table.name, name)) return table;
    }
    return null;
}

fn findColumn(table: inspect.Table, name: []const u8) ?inspect.Column {
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

/// Loose type compatibility for offline checks across SQLite / Postgres names.
/// Exact match (case-insensitive) always succeeds; common aliases also match.
fn typesCompatible(want: []const u8, have: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(want, have)) return true;
    const a = normalizeTypeName(want);
    const b = normalizeTypeName(have);
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    // Integer family
    if (isIntegerType(a) and isIntegerType(b)) return true;
    // Text family
    if (isTextType(a) and isTextType(b)) return true;
    // Float family
    if (isFloatType(a) and isFloatType(b)) return true;
    // Bool family
    if (isBoolType(a) and isBoolType(b)) return true;
    // Blob family
    if (isBlobType(a) and isBlobType(b)) return true;
    return false;
}

fn normalizeTypeName(name: []const u8) []const u8 {
    // Strip common modifiers: "character varying", "timestamp without time zone"
    if (std.ascii.eqlIgnoreCase(name, "character varying")) return "varchar";
    if (std.ascii.eqlIgnoreCase(name, "double precision")) return "float8";
    if (std.ascii.indexOfIgnoreCase(name, "timestamp") != null) return "timestamp";
    return name;
}

fn isIntegerType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "integer") or
        std.ascii.eqlIgnoreCase(name, "int") or
        std.ascii.eqlIgnoreCase(name, "int2") or
        std.ascii.eqlIgnoreCase(name, "int4") or
        std.ascii.eqlIgnoreCase(name, "int8") or
        std.ascii.eqlIgnoreCase(name, "smallint") or
        std.ascii.eqlIgnoreCase(name, "bigint") or
        std.ascii.eqlIgnoreCase(name, "serial") or
        std.ascii.eqlIgnoreCase(name, "bigserial");
}

fn isTextType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "text") or
        std.ascii.eqlIgnoreCase(name, "varchar") or
        std.ascii.eqlIgnoreCase(name, "character") or
        std.ascii.eqlIgnoreCase(name, "char") or
        std.ascii.eqlIgnoreCase(name, "name") or
        std.ascii.eqlIgnoreCase(name, "citext");
}

fn isFloatType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "real") or
        std.ascii.eqlIgnoreCase(name, "float") or
        std.ascii.eqlIgnoreCase(name, "float4") or
        std.ascii.eqlIgnoreCase(name, "float8") or
        std.ascii.eqlIgnoreCase(name, "double") or
        std.ascii.eqlIgnoreCase(name, "numeric");
}

fn isBoolType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "bool") or
        std.ascii.eqlIgnoreCase(name, "boolean");
}

fn isBlobType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "blob") or
        std.ascii.eqlIgnoreCase(name, "bytea") or
        std.ascii.eqlIgnoreCase(name, "bytes");
}

// --- Lightweight SQL surface scan (quotes / comments aware) ---

const Scanner = struct {
    sql: []const u8,
    index: usize = 0,

    fn init(sql: []const u8) Scanner {
        return .{ .sql = sql };
    }

    fn peek(self: Scanner) ?u8 {
        if (self.index >= self.sql.len) return null;
        return self.sql[self.index];
    }

    fn advance(self: *Scanner) void {
        self.index += 1;
    }

    fn skipTrivia(self: *Scanner) CheckError!void {
        while (self.index < self.sql.len) {
            const c = self.sql[self.index];
            if (std.ascii.isWhitespace(c)) {
                self.index += 1;
                continue;
            }
            if (c == '-' and self.index + 1 < self.sql.len and self.sql[self.index + 1] == '-') {
                self.index += 2;
                while (self.index < self.sql.len and self.sql[self.index] != '\n') : (self.index += 1) {}
                continue;
            }
            if (c == '/' and self.index + 1 < self.sql.len and self.sql[self.index + 1] == '*') {
                self.index += 2;
                while (self.index + 1 < self.sql.len) : (self.index += 1) {
                    if (self.sql[self.index] == '*' and self.sql[self.index + 1] == '/') {
                        self.index += 2;
                        break;
                    }
                } else return error.InvalidSql;
                continue;
            }
            if (c == '\'') {
                try self.skipQuoted('\'');
                continue;
            }
            if (c == '"') {
                try self.skipQuoted('"');
                continue;
            }
            if (c == '`') {
                try self.skipQuoted('`');
                continue;
            }
            if (c == '[') {
                self.index += 1;
                while (self.index < self.sql.len and self.sql[self.index] != ']') : (self.index += 1) {}
                if (self.index < self.sql.len) self.index += 1;
                continue;
            }
            break;
        }
    }

    fn skipQuoted(self: *Scanner, quote: u8) CheckError!void {
        self.index += 1;
        while (self.index < self.sql.len) {
            if (self.sql[self.index] == quote) {
                self.index += 1;
                if (self.index < self.sql.len and self.sql[self.index] == quote) {
                    self.index += 1; // escaped quote
                    continue;
                }
                return;
            }
            self.index += 1;
        }
        return error.InvalidSql;
    }

    /// Read a SQL identifier or * . Returns null at EOF / non-ident.
    fn readIdentOrStar(self: *Scanner) CheckError!?[]const u8 {
        try self.skipTrivia();
        if (self.index >= self.sql.len) return null;
        const c = self.sql[self.index];
        if (c == '*') {
            const start = self.index;
            self.index += 1;
            return self.sql[start..self.index];
        }
        if (c == '"' or c == '`' or c == '[') {
            const open = c;
            const close: u8 = if (open == '[') ']' else open;
            const start = self.index + 1;
            self.index += 1;
            while (self.index < self.sql.len and self.sql[self.index] != close) : (self.index += 1) {}
            if (self.index >= self.sql.len) return error.InvalidSql;
            const slice = self.sql[start..self.index];
            self.index += 1;
            return slice;
        }
        if (!(std.ascii.isAlphabetic(c) or c == '_')) return null;
        const start = self.index;
        self.index += 1;
        while (self.index < self.sql.len) {
            const ch = self.sql[self.index];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$') {
                self.index += 1;
            } else break;
        }
        return self.sql[start..self.index];
    }

    fn matchKeyword(self: *Scanner, kw: []const u8) CheckError!bool {
        try self.skipTrivia();
        if (self.index + kw.len > self.sql.len) return false;
        const slice = self.sql[self.index .. self.index + kw.len];
        if (!std.ascii.eqlIgnoreCase(slice, kw)) return false;
        // Boundary: next char must not continue an identifier.
        if (self.index + kw.len < self.sql.len) {
            const next = self.sql[self.index + kw.len];
            if (std.ascii.isAlphanumeric(next) or next == '_') return false;
        }
        self.index += kw.len;
        return true;
    }

    fn startsWithKeyword(self: Scanner, kw: []const u8) bool {
        var tmp = self;
        return (tmp.matchKeyword(kw) catch false);
    }
};

/// Parse table refs after FROM / JOIN. Returns empty slice if none found.
fn parseFromJoinTables(sql: []const u8, schema: inspect.Schema, buf: *[max_tables]TableRef) CheckError![]const TableRef {
    var sc = Scanner.init(sql);
    var count: usize = 0;

    // Find first FROM keyword at statement level (simple scan).
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) break;
        if (try sc.matchKeyword("from")) break;
        // Skip other tokens roughly: advance one ident or one char.
        if (try sc.readIdentOrStar()) |_| {
            continue;
        } else if (sc.index < sc.sql.len) {
            sc.advance();
        }
    } else return buf[0..0];

    // After FROM: table [alias] [, table [alias]]* [JOIN table [alias] ...]*
    while (sc.index < sc.sql.len and count < max_tables) {
        try sc.skipTrivia();
        // Stop at WHERE / GROUP / ORDER / LIMIT / HAVING / UNION / RETURNING / ;
        if (sc.startsWithKeyword("where") or
            sc.startsWithKeyword("group") or
            sc.startsWithKeyword("order") or
            sc.startsWithKeyword("limit") or
            sc.startsWithKeyword("having") or
            sc.startsWithKeyword("union") or
            sc.startsWithKeyword("returning") or
            sc.startsWithKeyword("window") or
            (sc.peek() == ';'))
        {
            break;
        }

        // JOIN keywords (optional INNER/LEFT/RIGHT/FULL/CROSS before JOIN)
        if (try sc.matchKeyword("inner") or
            try sc.matchKeyword("left") or
            try sc.matchKeyword("right") or
            try sc.matchKeyword("full") or
            try sc.matchKeyword("cross") or
            try sc.matchKeyword("outer"))
        {
            _ = try sc.matchKeyword("outer"); // LEFT OUTER
            _ = try sc.matchKeyword("join");
            // fall through to table name
        } else if (try sc.matchKeyword("join")) {
            // bare JOIN
        } else if (sc.peek() == ',') {
            sc.advance();
        }

        try sc.skipTrivia();
        // ON / USING clauses after a join — skip until next join/comma/where
        if (try sc.matchKeyword("on") or try sc.matchKeyword("using")) {
            // Skip until next JOIN keyword or terminator. Naive paren-aware skip.
            var depth: i32 = 0;
            while (sc.index < sc.sql.len) {
                try sc.skipTrivia();
                if (sc.index >= sc.sql.len) break;
                if (depth == 0) {
                    if (sc.startsWithKeyword("inner") or
                        sc.startsWithKeyword("left") or
                        sc.startsWithKeyword("right") or
                        sc.startsWithKeyword("full") or
                        sc.startsWithKeyword("cross") or
                        sc.startsWithKeyword("join") or
                        sc.startsWithKeyword("where") or
                        sc.startsWithKeyword("group") or
                        sc.startsWithKeyword("order") or
                        sc.startsWithKeyword("limit") or
                        sc.startsWithKeyword("having") or
                        sc.startsWithKeyword("union") or
                        sc.startsWithKeyword("returning") or
                        sc.peek() == ',' or sc.peek() == ';')
                    {
                        break;
                    }
                }
                const c = sc.peek() orelse break;
                if (c == '(') {
                    depth += 1;
                    sc.advance();
                } else if (c == ')') {
                    depth -= 1;
                    sc.advance();
                } else {
                    // consume ident or single char
                    if ((try sc.readIdentOrStar()) == null) sc.advance();
                }
            }
            continue;
        }

        const table_name = (try sc.readIdentOrStar()) orelse break;
        if (std.mem.eql(u8, table_name, "*")) return error.InvalidSql;

        // Optional AS alias / bare alias
        var alias: ?[]const u8 = null;
        try sc.skipTrivia();
        if (try sc.matchKeyword("as")) {
            alias = try sc.readIdentOrStar() orelse return error.InvalidSql;
        } else {
            // Bare alias: next ident that is not a clause keyword
            const save = sc.index;
            if (!sc.startsWithKeyword("inner") and
                !sc.startsWithKeyword("left") and
                !sc.startsWithKeyword("right") and
                !sc.startsWithKeyword("full") and
                !sc.startsWithKeyword("cross") and
                !sc.startsWithKeyword("join") and
                !sc.startsWithKeyword("on") and
                !sc.startsWithKeyword("using") and
                !sc.startsWithKeyword("where") and
                !sc.startsWithKeyword("group") and
                !sc.startsWithKeyword("order") and
                !sc.startsWithKeyword("limit") and
                !sc.startsWithKeyword("having") and
                !sc.startsWithKeyword("union") and
                !sc.startsWithKeyword("returning") and
                !sc.startsWithKeyword("window") and
                sc.peek() != ',' and sc.peek() != ';')
            {
                if (try sc.readIdentOrStar()) |maybe_alias| {
                    alias = maybe_alias;
                } else {
                    sc.index = save;
                }
            }
        }

        // Only keep refs that exist in the schema (ignore CTE/subquery noise).
        if (findTable(schema, table_name) != null) {
            if (count >= max_tables) return error.TooManyTables;
            buf[count] = .{ .name = table_name, .alias = alias };
            count += 1;
        }
    }

    return buf[0..count];
}

/// Parse simple SELECT projections up to FROM. Expressions with `(` are skipped.
fn parseSelectProjections(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    // Optional WITH ... skip to SELECT (best-effort: first SELECT)
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (try sc.matchKeyword("select")) break;
        if ((try sc.readIdentOrStar()) == null and sc.index < sc.sql.len) sc.advance();
    } else return error.InvalidSql;

    // Optional DISTINCT / ALL
    _ = try sc.matchKeyword("distinct");
    _ = try sc.matchKeyword("all");

    var count: usize = 0;
    while (sc.index < sc.sql.len and count < max_projections) {
        try sc.skipTrivia();
        if (try sc.matchKeyword("from")) break;
        if (sc.peek() == ';') break;

        // Skip commas between items
        if (sc.peek() == ',') {
            sc.advance();
            try sc.skipTrivia();
        }

        // If expression starts with '(' or is a function call (ident followed by '('), skip to next comma/from.
        const item_start = sc.index;
        const first = try sc.readIdentOrStar();
        if (first == null) {
            // literal / operator — skip until comma or FROM
            try skipSelectItem(&sc);
            continue;
        }

        try sc.skipTrivia();
        if (sc.peek() == '(') {
            // function call / expression — skip
            sc.index = item_start;
            try skipSelectItem(&sc);
            continue;
        }

        // first may be *, table, or column
        if (std.mem.eql(u8, first.?, "*")) {
            buf[count] = .{ .column = "*", .is_star = true };
            count += 1;
        } else if (sc.peek() == '.') {
            sc.advance();
            const second = try sc.readIdentOrStar() orelse return error.InvalidSql;
            if (std.mem.eql(u8, second, "*")) {
                buf[count] = .{ .column = "*", .qualifier = first.?, .is_star = true };
            } else {
                buf[count] = .{ .column = second, .qualifier = first.? };
            }
            count += 1;
        } else {
            buf[count] = .{ .column = first.? };
            count += 1;
        }

        // Optional AS alias — consume and ignore
        try sc.skipTrivia();
        if (try sc.matchKeyword("as")) {
            _ = try sc.readIdentOrStar();
        } else {
            // bare alias before comma/from
            const save = sc.index;
            if (!sc.startsWithKeyword("from") and sc.peek() != ',' and sc.peek() != ';') {
                if ((try sc.readIdentOrStar()) == null) sc.index = save;
            }
        }

        try sc.skipTrivia();
        if (sc.peek() == ',') {
            sc.advance();
            continue;
        }
        if (try sc.matchKeyword("from")) break;
    }

    if (count >= max_projections and sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (!sc.startsWithKeyword("from") and sc.peek() != ';') return error.TooManyProjections;
    }
    return buf[0..count];
}

fn skipSelectItem(sc: *Scanner) CheckError!void {
    var depth: i32 = 0;
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) return;
        if (depth == 0 and (sc.peek() == ',' or sc.startsWithKeyword("from") or sc.peek() == ';')) return;
        const c = sc.peek() orelse return;
        if (c == '(') {
            depth += 1;
            sc.advance();
        } else if (c == ')') {
            depth -= 1;
            sc.advance();
        } else if ((try sc.readIdentOrStar()) == null) {
            sc.advance();
        }
    }
}

fn isWhereTerminator(sc: Scanner) bool {
    return sc.startsWithKeyword("group") or
        sc.startsWithKeyword("order") or
        sc.startsWithKeyword("limit") or
        sc.startsWithKeyword("offset") or
        sc.startsWithKeyword("having") or
        sc.startsWithKeyword("union") or
        sc.startsWithKeyword("intersect") or
        sc.startsWithKeyword("except") or
        sc.startsWithKeyword("returning") or
        sc.startsWithKeyword("window") or
        sc.startsWithKeyword("for") or
        (sc.peek() == ';');
}

/// Keywords / pseudo-columns that appear in WHERE but are not schema columns.
fn isSqlNoiseIdent(name: []const u8) bool {
    const keywords = [_][]const u8{
        "and",       "or",        "not",       "in",        "is",        "null",
        "true",      "false",     "unknown",   "between",   "like",      "ilike",
        "similar",   "escape",    "exists",    "case",      "when",      "then",
        "else",      "end",       "any",       "all",       "some",      "distinct",
        "cast",      "as",        "on",        "using",     "join",      "inner",
        "left",      "right",     "full",      "cross",     "outer",     "select",
        "from",      "where",     "group",     "order",     "by",        "limit",
        "offset",    "having",    "union",     "intersect", "except",    "returning",
        "window",    "over",      "partition", "asc",       "desc",      "nulls",
        "first",     "last",      "current",   "row",       "rows",      "unbounded",
        "preceding", "following", "filter",    "collate",   "symmetric", "asymmetric",
        "interval",  "date",      "time",      "timestamp", "at",        "zone",
        "both",      "leading",   "trailing",  "trim",      "extract",   "substring",
        "position",  "overlay",   "placing",   "values",    "default",   "new",
        "old",       "array",     "row",       "only",
    };
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(name, kw)) return true;
    }
    return false;
}

fn skipBindMarker(sc: *Scanner) CheckError!bool {
    try sc.skipTrivia();
    const c = sc.peek() orelse return false;
    if (c != ':' and c != '@' and c != '$') return false;
    // Postgres `::` cast is not a bind marker.
    if (c == ':' and sc.index + 1 < sc.sql.len and sc.sql[sc.index + 1] == ':') return false;
    sc.advance();
    // $1 / :name / @name
    if (sc.index < sc.sql.len and std.ascii.isDigit(sc.sql[sc.index])) {
        while (sc.index < sc.sql.len and std.ascii.isDigit(sc.sql[sc.index])) : (sc.index += 1) {}
        return true;
    }
    _ = try sc.readIdentOrStar();
    return true;
}

fn skipNumber(sc: *Scanner) CheckError!bool {
    try sc.skipTrivia();
    const c = sc.peek() orelse return false;
    if (!std.ascii.isDigit(c) and !(c == '.' and sc.index + 1 < sc.sql.len and std.ascii.isDigit(sc.sql[sc.index + 1])))
        return false;
    while (sc.index < sc.sql.len) {
        const ch = sc.sql[sc.index];
        if (std.ascii.isDigit(ch) or ch == '.' or ch == 'e' or ch == 'E' or ch == '+' or ch == '-') {
            sc.advance();
        } else break;
    }
    return true;
}

fn skipParenGroup(sc: *Scanner) CheckError!void {
    try sc.skipTrivia();
    if (sc.peek() != '(') return;
    sc.advance();
    var depth: i32 = 1;
    while (sc.index < sc.sql.len and depth > 0) {
        try sc.skipTrivia();
        const c = sc.peek() orelse break;
        if (c == '(') {
            depth += 1;
            sc.advance();
        } else if (c == ')') {
            depth -= 1;
            sc.advance();
        } else if ((try sc.readIdentOrStar()) == null) {
            sc.advance();
        }
    }
}

/// Collect bare/qualified column references from a simple WHERE clause.
/// Returns empty when no WHERE is present. Best-effort; not a full SQL parser.
fn parseWhereColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    // Find first top-level WHERE (after SELECT … FROM …).
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) break;
        if (try sc.matchKeyword("where")) break;
        if ((try sc.readIdentOrStar()) == null and sc.index < sc.sql.len) sc.advance();
    } else return buf[0..0];

    var count: usize = 0;
    while (sc.index < sc.sql.len and count < max_projections) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) break;
        if (isWhereTerminator(sc)) break;

        if (try skipBindMarker(&sc)) continue;
        if (try skipNumber(&sc)) continue;

        // Postgres / SQL type cast `::typename`
        if (sc.peek() == ':' and sc.index + 1 < sc.sql.len and sc.sql[sc.index + 1] == ':') {
            sc.advance();
            sc.advance();
            _ = try sc.readIdentOrStar();
            // optional (precision) after cast type
            try sc.skipTrivia();
            if (sc.peek() == '(') try skipParenGroup(&sc);
            continue;
        }

        const first = try sc.readIdentOrStar();
        if (first == null) {
            // Operator / punctuation
            if (sc.index < sc.sql.len) sc.advance();
            continue;
        }
        if (std.mem.eql(u8, first.?, "*")) continue;
        if (isSqlNoiseIdent(first.?)) continue;

        try sc.skipTrivia();
        // Function call: skip name + argument list (do not treat args as columns
        // for this best-effort pass — keeps false positives low).
        if (sc.peek() == '(') {
            try skipParenGroup(&sc);
            continue;
        }

        if (sc.peek() == '.') {
            sc.advance();
            const second = try sc.readIdentOrStar() orelse return error.InvalidSql;
            if (std.mem.eql(u8, second, "*") or isSqlNoiseIdent(second)) continue;
            // qualified function: schema.func(
            try sc.skipTrivia();
            if (sc.peek() == '(') {
                try skipParenGroup(&sc);
                continue;
            }
            buf[count] = .{ .column = second, .qualifier = first.? };
            count += 1;
        } else {
            buf[count] = .{ .column = first.? };
            count += 1;
        }
    }
    return buf[0..count];
}

/// Build a checked-query type from options. Prefer this for stable embed sites:
///
/// ```zig
/// const q = zsql.checkedQuery(.{
///     .sql = "select id from users where id = :id",
///     .args = &.{.{ .name = "id" }},
///     .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
///     .from_table = "users",
/// });
/// try q.validate(schema);
/// ```
///
/// Call `validate()` at comptime or runtime against a schema artifact. This is
/// the ergonomic surface toward the target API shape; it does not invent ORM
/// behavior — only offline validation of placeholders and row/arg shapes.
pub fn checkedQuery(comptime options: anytype) type {
    const sql_value: []const u8 = options.sql;
    const from_table_value: ?[]const u8 = if (@hasField(@TypeOf(options), "from_table")) options.from_table else null;
    const check_projections_value: bool = if (@hasField(@TypeOf(options), "check_projections")) options.check_projections else false;
    const check_where_value: bool = if (@hasField(@TypeOf(options), "check_where")) options.check_where else false;

    const args_value: []const ArgSpec = comptime blk: {
        if (!@hasField(@TypeOf(options), "args")) break :blk &.{};
        const raw = options.args;
        var out: [raw.len]ArgSpec = undefined;
        for (raw, 0..) |item, i| {
            out[i] = .{ .name = item.name };
        }
        const frozen = out;
        break :blk &frozen;
    };

    const row_value: []const FieldSpec = comptime blk: {
        if (!@hasField(@TypeOf(options), "row")) break :blk &.{};
        const raw = options.row;
        var out: [raw.len]FieldSpec = undefined;
        for (raw, 0..) |item, i| {
            out[i] = .{
                .name = item.name,
                .type_name = if (@hasField(@TypeOf(item), "type_name")) item.type_name else null,
                .nullable = if (@hasField(@TypeOf(item), "nullable")) item.nullable else false,
            };
        }
        const frozen = out;
        break :blk &frozen;
    };

    const from_tables_value: []const []const u8 = comptime blk: {
        if (!@hasField(@TypeOf(options), "from_tables")) break :blk &.{};
        const raw = options.from_tables;
        var out: [raw.len][]const u8 = undefined;
        for (raw, 0..) |item, i| {
            out[i] = item;
        }
        const frozen = out;
        break :blk &frozen;
    };

    return struct {
        pub const sql = sql_value;
        pub const args = args_value;
        pub const row = row_value;
        pub const from_table = from_table_value;
        pub const from_tables = from_tables_value;
        pub const check_projections = check_projections_value;
        pub const check_where = check_where_value;

        pub fn validate(schema: inspect.Schema) CheckError!void {
            try checkQuery(.{
                .sql = sql,
                .schema = schema,
                .args = args,
                .row = row,
                .from_table = from_table,
                .from_tables = from_tables,
                .check_projections = check_projections,
                .check_where = check_where,
            });
        }
    };
}

test "checkQuery validates named params and columns" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                    .{ .name = "bio", .type_name = "TEXT", .nullable = true },
                },
            },
        },
    };

    try checkQuery(.{
        .sql = "select id, email from users where id = :id",
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
        },
        .from_table = "users",
    });

    try std.testing.expectError(error.UnknownNamedParameter, checkQuery(.{
        .sql = "select id from users where id = :id",
        .schema = schema,
        .args = &.{.{ .name = "nope" }},
        .from_table = "users",
        .row = &.{.{ .name = "id" }},
    }));

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "missing" }},
    }));

    try std.testing.expectError(error.NullabilityMismatch, checkQuery(.{
        .sql = "select bio from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "bio", .nullable = false }},
    }));
}

test "typesCompatible accepts common cross-driver aliases" {
    try std.testing.expect(typesCompatible("INTEGER", "int4"));
    try std.testing.expect(typesCompatible("bigint", "INTEGER"));
    try std.testing.expect(typesCompatible("TEXT", "varchar"));
    try std.testing.expect(typesCompatible("BOOLEAN", "bool"));
    try std.testing.expect(typesCompatible("BLOB", "bytea"));
    try std.testing.expect(!typesCompatible("TEXT", "INTEGER"));
}

test "checkQuery accepts integer alias against int8 column" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "int8", .nullable = false, .primary_key = true },
                },
            },
        },
    };
    try checkQuery(.{
        .sql = "select id from users",
        .schema = schema,
        .from_table = "users",
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    });
}

test "checkedQuery type validates against schema" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    const get_user = checkedQuery(.{
        .sql = "select id, email from users where id = :id",
        .args = &.{.{ .name = "id" }},
        .row = &.{
            .{ .name = "id", .type_name = "INTEGER" },
            .{ .name = "email", .type_name = "TEXT" },
        },
        .from_table = "users",
    });
    try get_user.validate(schema);
    try std.testing.expectEqualStrings("select id, email from users where id = :id", get_user.sql);
}

test "checkQuery join scope with from_tables and qualified columns" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    try checkQuery(.{
        .sql =
        \\select users.email, posts.title
        \\from users
        \\join posts on posts.user_id = users.id
        \\where users.id = :id
        ,
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .from_tables = &.{ "users", "posts" },
        .row = &.{
            .{ .name = "users.email", .type_name = "TEXT" },
            .{ .name = "posts.title", .type_name = "TEXT" },
        },
    });

    // Unqualified `id` is ambiguous across users/posts.
    try std.testing.expectError(error.AmbiguousColumn, checkQuery(.{
        .sql = "select id from users join posts on posts.user_id = users.id",
        .schema = schema,
        .from_tables = &.{ "users", "posts" },
        .row = &.{.{ .name = "id" }},
    }));

    // email is unique to users — ok unqualified.
    try checkQuery(.{
        .sql = "select email from users join posts on posts.user_id = users.id",
        .schema = schema,
        .from_tables = &.{ "users", "posts" },
        .row = &.{.{ .name = "email", .type_name = "TEXT" }},
    });
}

test "checkQuery auto-extracts FROM/JOIN tables and aliases" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    // No from_table / from_tables: extract users u + posts p from SQL.
    try checkQuery(.{
        .sql =
        \\select u.email, p.title
        \\from users u
        \\inner join posts p on p.user_id = u.id
        ,
        .schema = schema,
        .row = &.{
            .{ .name = "u.email", .type_name = "TEXT" },
            .{ .name = "p.title", .type_name = "TEXT" },
        },
    });
}

test "checkQuery projections validate select list" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    try checkQuery(.{
        .sql = "select users.id, email from users",
        .schema = schema,
        .from_table = "users",
        .check_projections = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing_col from users",
        .schema = schema,
        .from_table = "users",
        .check_projections = true,
    }));

    try std.testing.expectError(error.AmbiguousColumn, checkQuery(.{
        .sql = "select id from users join posts on posts.user_id = users.id",
        .schema = schema,
        .from_tables = &.{ "users", "posts" },
        .check_projections = true,
    }));

    // Star projections are accepted when the table is known.
    try checkQuery(.{
        .sql = "select u.*, p.title from users u join posts p on p.user_id = u.id",
        .schema = schema,
        .check_projections = true,
    });

    // Function/expression projections are skipped (not a hard failure).
    try checkQuery(.{
        .sql = "select count(*), email from users",
        .schema = schema,
        .from_table = "users",
        .check_projections = true,
    });
}

test "checkedQuery supports from_tables and check_projections" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    const q = checkedQuery(.{
        .sql =
        \\select users.email, posts.title
        \\from users
        \\join posts on posts.user_id = users.id
        \\where users.id = :id
        ,
        .args = &.{.{ .name = "id" }},
        .from_tables = &.{ "users", "posts" },
        .row = &.{
            .{ .name = "users.email", .type_name = "TEXT" },
            .{ .name = "posts.title", .type_name = "TEXT" },
        },
        .check_projections = true,
    });
    try q.validate(schema);
}

test "checkQuery where column refs resolve against scope" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                    .{ .name = "active", .type_name = "INTEGER", .nullable = false },
                },
            },
            .{
                .name = "posts",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "user_id", .type_name = "INTEGER", .nullable = false },
                    .{ .name = "title", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    try checkQuery(.{
        .sql = "select id from users where email = :email and active = 1",
        .schema = schema,
        .args = &.{.{ .name = "email" }},
        .from_table = "users",
        .check_where = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select id from users where missing_col = 1",
        .schema = schema,
        .from_table = "users",
        .check_where = true,
    }));

    // Qualified WHERE across a join.
    try checkQuery(.{
        .sql =
        \\select u.email
        \\from users u
        \\join posts p on p.user_id = u.id
        \\where u.id = :id and p.title is not null
        ,
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .check_where = true,
    });

    // Unqualified `id` is ambiguous in join scope.
    try std.testing.expectError(error.AmbiguousColumn, checkQuery(.{
        .sql =
        \\select u.email
        \\from users u
        \\join posts p on p.user_id = u.id
        \\where id = 1
        ,
        .schema = schema,
        .check_where = true,
    }));

    // Casts and functions should not be treated as unknown columns.
    try checkQuery(.{
        .sql = "select id from users where id::text = :s and lower(email) = :e",
        .schema = schema,
        .args = &.{ .{ .name = "s" }, .{ .name = "e" } },
        .from_table = "users",
        .check_where = true,
    });

    // Default remains off: unknown WHERE columns are ignored without the flag.
    try checkQuery(.{
        .sql = "select id from users where totally_missing = 1",
        .schema = schema,
        .from_table = "users",
        .check_where = false,
    });
}

test "checkedQuery supports check_where" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };
    const q = checkedQuery(.{
        .sql = "select id from users where email = :email",
        .args = &.{.{ .name = "email" }},
        .from_table = "users",
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
        .check_where = true,
    });
    try q.validate(schema);
}
