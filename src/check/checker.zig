const std = @import("std");
const inspect = @import("inspect.zig");
const params = @import("../core/params.zig");
const sql_types = @import("../core/types.zig");

pub const CheckError = error{
    PlaceholderCountMismatch,
    MixedPlaceholderStyles,
    UnknownNamedParameter,
    ExtraNamedParameter,
    DuplicateNamedParameter,
    UnknownTable,
    UnknownColumn,
    AmbiguousColumn,
    AmbiguousProjection,
    RowFieldNotProjected,
    TypeMismatch,
    NullabilityMismatch,
    InvalidSql,
    TooManyTables,
    TooManyProjections,
};

/// Progressive offline-validation policy. Existing explicit `check_*` flags
/// remain available for callers that want a narrower clause selection.
pub const CheckLevel = enum {
    none,
    syntax,
    parameters,
    result_shape,
    result_types,
};

pub const ArgSpec = struct {
    name: []const u8,
};

pub const FieldSpec = struct {
    name: []const u8,
    /// Optional: when set, must match the resolved result type (case-insensitive).
    type_name: ?[]const u8 = null,
    nullable: bool = false,
};

/// A table reference discovered in SQL or supplied by the caller.
/// `alias` is optional (FROM users u / FROM users AS u).
const TableRef = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

const UsingMerge = struct {
    column: []const u8,
    reductions: usize,
};

const ProjectionKind = enum {
    column,
    star,
    count,
    min,
    max,
};

const Projection = struct {
    /// Unqualified source column name, `*`, or a supported aggregate argument.
    column: []const u8,
    /// Optional table or alias qualifier before `.`.
    qualifier: ?[]const u8 = null,
    /// Result-column name introduced by `AS alias` or a bare alias.
    alias: ?[]const u8 = null,
    kind: ProjectionKind = .column,
};

const max_tables = 16;
const max_projections = 64;

/// Lightweight offline SQL check against a schema artifact and parameter/row specs.
///
/// Validates placeholders and maps each declared result field to a supported
/// SELECT projection: simple columns, aliases, stars, and portable aggregate
/// forms with sound cross-driver result metadata.
/// Supports multi-table / JOIN scope via `from_tables`, qualified column names
/// (`users.email` / `u.email`), optional SELECT-list projection checks
/// (`check_projections`), optional WHERE column checks (`check_where`), optional
/// JOIN ON column checks (`check_join_on`), and optional ORDER BY column checks
/// (`check_order_by`), and optional GROUP BY column checks (`check_group_by`).
///
/// Values are never required at check time. Allocation-free.
pub fn checkQuery(options: struct {
    sql: []const u8,
    schema: inspect.Schema,
    args: []const ArgSpec = &.{},
    row: []const FieldSpec = &.{},
    level: CheckLevel = .none,
    /// Single-table scope (legacy / common case).
    from_table: ?[]const u8 = null,
    /// Multi-table scope for JOIN checks. When non-empty, overrides `from_table`.
    from_tables: []const []const u8 = &.{},
    /// When true, parse a simple SELECT list and ensure each bare/qualified
    /// projection resolves against the table scope (and schema).
    check_projections: bool = false,
    /// When true, parse simple WHERE (and HAVING) column references and resolve
    /// them against the table scope. Function calls, SQL keywords, casts, and
    /// bind markers are skipped. Opt-in so complex expressions do not surprise
    /// callers.
    check_where: bool = false,
    /// When true, parse simple JOIN ON column references and validate USING
    /// columns against both sides of schema-known joins.
    check_join_on: bool = false,
    /// When true, parse simple GROUP BY column references and unique SELECT
    /// aliases. Positional ordinals are ignored.
    check_group_by: bool = false,
    /// When true, parse simple ORDER BY column references the same way as WHERE.
    /// Positional sorts (`ORDER BY 1`) and keywords (`ASC`/`DESC`) are ignored.
    check_order_by: bool = false,
}) CheckError!void {
    const level_value = @intFromEnum(options.level);
    const check_projections = options.check_projections or level_value >= @intFromEnum(CheckLevel.result_shape);
    const check_where = options.check_where or level_value >= @intFromEnum(CheckLevel.result_types);
    const check_join_on = options.check_join_on or level_value >= @intFromEnum(CheckLevel.result_types);
    const check_group_by = options.check_group_by or level_value >= @intFromEnum(CheckLevel.result_types);
    const check_order_by = options.check_order_by or level_value >= @intFromEnum(CheckLevel.result_types);
    const summary = params.summarize(options.sql) catch return error.InvalidSql;

    if (summary.named != 0 and (summary.positional != 0 or summary.indexed != 0)) {
        return error.MixedPlaceholderStyles;
    }

    if (summary.named > 0) {
        for (options.args, 0..) |arg, index| {
            for (options.args[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name, arg.name)) {
                    return error.DuplicateNamedParameter;
                }
            }
        }
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
    } else {
        if (summary.expectedBindCount() != options.args.len) return error.PlaceholderCountMismatch;
    }

    var table_buf: [max_tables]TableRef = undefined;
    const scope = try resolveTableScope(options.sql, options.schema, options.from_table, options.from_tables, &table_buf);

    const resolve_scope = if (scope.len != 0)
        scope
    else
        try schemaAsScope(options.schema, &table_buf);

    var proj_buf: [max_projections]Projection = undefined;
    const projs = if (check_projections or check_group_by or check_order_by or options.row.len != 0)
        try parseSelectProjections(options.sql, &proj_buf)
    else
        proj_buf[0..0];

    if (options.row.len != 0) {
        for (options.row) |field| {
            const resolved = try resolveProjectedField(options.schema, resolve_scope, projs, field.name);
            try checkFieldAgainstColumn(field, resolved);
        }
    }

    if (check_projections) {
        for (projs) |proj| {
            switch (proj.kind) {
                .star => {
                    if (proj.qualifier) |q| {
                        // table.* — qualifier must resolve to a known table/alias in scope.
                        _ = findTableRefSql(resolve_scope, q) orelse return error.UnknownTable;
                    }
                },
                .column, .count, .min, .max => _ = try resolveProjectionColumn(options.schema, resolve_scope, proj),
            }
        }
    }

    if (check_where) {
        var where_buf: [max_projections]Projection = undefined;
        const where_refs = try parseWhereColumnRefs(options.sql, &where_buf);
        try resolveProjectionRefs(options.schema, resolve_scope, where_refs);

        var having_buf: [max_projections]Projection = undefined;
        const having_refs = try parseHavingColumnRefs(options.sql, &having_buf);
        try resolveProjectionRefs(options.schema, resolve_scope, having_refs);
    }

    if (check_join_on) {
        var on_buf: [max_projections]Projection = undefined;
        const refs = try parseJoinOnColumnRefs(options.sql, &on_buf);
        try resolveProjectionRefs(options.schema, resolve_scope, refs);

        var using_table_buf: [max_tables]TableRef = undefined;
        _ = try parseFromJoinTables(options.sql, options.schema, &using_table_buf, true);
    }

    if (check_group_by) {
        var group_buf: [max_projections]Projection = undefined;
        const refs = try parseGroupByColumnRefs(options.sql, &group_buf);
        try resolveOutputRefs(options.schema, resolve_scope, refs, projs);
    }

    if (check_order_by) {
        var order_buf: [max_projections]Projection = undefined;
        const refs = try parseOrderByColumnRefs(options.sql, &order_buf);
        try resolveOutputRefs(options.schema, resolve_scope, refs, projs);
    }
}

fn resolveOutputRefs(
    schema: inspect.Schema,
    scope: []const TableRef,
    refs: []const Projection,
    projections: []const Projection,
) CheckError!void {
    for (refs) |ref| {
        if (ref.qualifier == null) {
            var alias_matches: usize = 0;
            var alias_projection: ?Projection = null;
            for (projections) |projection| {
                if (projection.alias) |alias| {
                    if (sqlIdentsEql(alias, ref.column)) {
                        alias_matches += 1;
                        alias_projection = projection;
                    }
                }
            }
            if (alias_matches > 1) return error.AmbiguousProjection;
            if (alias_projection) |projection| {
                _ = try resolveProjectionColumn(schema, scope, projection);
                continue;
            }
        }
        if (ref.qualifier) |qualifier| {
            _ = try resolveQualifiedSql(schema, scope, qualifier, ref.column);
        } else {
            _ = try resolveUnqualifiedSql(schema, scope, ref.column);
        }
    }
}

fn resolveProjectedField(
    schema: inspect.Schema,
    scope: []const TableRef,
    projections: []const Projection,
    field_name: []const u8,
) CheckError!inspect.Column {
    var match: ?inspect.Column = null;
    for (projections) |projection| {
        if (projection.kind == .star) continue;
        if (!projectionMatchesField(projection, field_name)) continue;
        const column = try resolveProjectionColumn(schema, scope, projection);
        try addProjectionMatch(&match, column);
    }

    const dot = std.mem.indexOfScalar(u8, field_name, '.');
    const field_qualifier = if (dot) |index| field_name[0..index] else null;
    const column_name = if (dot) |index| field_name[index + 1 ..] else field_name;
    for (projections) |projection| {
        if (projection.kind != .star) continue;
        if (projection.qualifier) |star_qualifier| {
            const table_ref = findTableRefSql(scope, star_qualifier) orelse return error.UnknownTable;
            if (field_qualifier) |qualifier| {
                const field_ref = findTableRef(scope, qualifier) orelse return error.RowFieldNotProjected;
                if (!std.mem.eql(u8, field_ref.name, table_ref.name)) continue;
            }
            const table = findTable(schema, table_ref.name) orelse return error.UnknownTable;
            const column = findColumn(table, column_name) orelse continue;
            try addProjectionMatch(&match, column);
        } else {
            for (scope) |table_ref| {
                if (field_qualifier) |qualifier| {
                    const field_ref = findTableRef(scope, qualifier) orelse return error.RowFieldNotProjected;
                    if (!std.mem.eql(u8, field_ref.name, table_ref.name)) continue;
                }
                const table = findTable(schema, table_ref.name) orelse continue;
                const column = findColumn(table, column_name) orelse continue;
                try addProjectionMatch(&match, column);
            }
        }
    }
    return match orelse error.RowFieldNotProjected;
}

fn resolveProjectionColumn(schema: inspect.Schema, scope: []const TableRef, projection: Projection) CheckError!inspect.Column {
    return switch (projection.kind) {
        .column => if (projection.qualifier) |qualifier|
            (try resolveQualifiedSql(schema, scope, qualifier, projection.column)).col
        else
            (try resolveUnqualifiedSql(schema, scope, projection.column)).col,
        .count, .min, .max => try resolveAggregateProjection(schema, scope, projection),
        .star => unreachable,
    };
}

fn resolveAggregateProjection(schema: inspect.Schema, scope: []const TableRef, projection: Projection) CheckError!inspect.Column {
    const source = if (sqlIdentEql(projection.column, "*"))
        null
    else if (projection.qualifier) |qualifier|
        try resolveQualifiedSql(schema, scope, qualifier, projection.column)
    else
        try resolveUnqualifiedSql(schema, scope, projection.column);

    return switch (projection.kind) {
        .count => .{
            .name = "count",
            .type_name = "INT8",
            .nullable = false,
        },
        .min, .max => .{
            .name = if (projection.kind == .min) "min" else "max",
            .type_name = source.?.col.type_name,
            // Empty input, or an all-null nullable input, produces SQL NULL.
            .nullable = true,
        },
        .column, .star => unreachable,
    };
}

fn addProjectionMatch(match: *?inspect.Column, candidate: inspect.Column) CheckError!void {
    if (match.* != null) return error.AmbiguousProjection;
    match.* = candidate;
}

fn projectionMatchesField(projection: Projection, field_name: []const u8) bool {
    switch (projection.kind) {
        .count, .min, .max => {
            const alias = projection.alias orelse return false;
            return sqlIdentEql(alias, field_name);
        },
        .column, .star => {},
    }
    if (projection.alias) |alias| return sqlIdentEql(alias, field_name);
    if (std.mem.indexOfScalar(u8, field_name, '.')) |dot| {
        const qualifier = projection.qualifier orelse return false;
        return sqlIdentEql(qualifier, field_name[0..dot]) and
            sqlIdentEql(projection.column, field_name[dot + 1 ..]);
    }
    return sqlIdentEql(projection.column, field_name);
}

fn resolveProjectionRefs(schema: inspect.Schema, scope: []const TableRef, refs: []const Projection) CheckError!void {
    for (refs) |ref| {
        if (ref.qualifier) |q| {
            _ = try resolveQualifiedSql(schema, scope, q, ref.column);
        } else {
            _ = try resolveUnqualifiedSql(schema, scope, ref.column);
        }
    }
}

fn schemaAsScope(schema: inspect.Schema, buf: *[max_tables]TableRef) CheckError![]const TableRef {
    if (schema.tables.len > max_tables) return error.TooManyTables;
    for (schema.tables, 0..) |t, i| {
        buf[i] = .{ .name = t.name };
    }
    return buf[0..schema.tables.len];
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
    return parseFromJoinTables(sql, schema, buf, false);
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

fn resolveQualifiedSql(
    schema: inspect.Schema,
    scope: []const TableRef,
    qualifier: []const u8,
    column: []const u8,
) CheckError!ResolvedColumn {
    const ref = findTableRefSql(scope, qualifier) orelse {
        if (findTableSql(schema, qualifier)) |table| {
            const col = findColumnSql(table, column) orelse return error.UnknownColumn;
            return .{ .table = table, .col = col };
        }
        return error.UnknownTable;
    };
    const table = findTable(schema, ref.name) orelse return error.UnknownTable;
    const col = findColumnSql(table, column) orelse return error.UnknownColumn;
    return .{ .table = table, .col = col };
}

fn resolveUnqualifiedSql(schema: inspect.Schema, scope: []const TableRef, column: []const u8) CheckError!ResolvedColumn {
    var found: ?ResolvedColumn = null;
    for (scope) |ref| {
        const table = findTable(schema, ref.name) orelse continue;
        if (findColumnSql(table, column)) |col| {
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
            if (sqlIdentEql(a, qual)) return ref;
        }
    }
    return null;
}

fn findTableRefSql(scope: []const TableRef, qualifier: []const u8) ?TableRef {
    for (scope) |ref| {
        if (sqlIdentEql(qualifier, ref.name)) return ref;
        if (ref.alias) |alias| {
            if (sqlIdentsEql(alias, qualifier)) return ref;
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

fn findTableSql(schema: inspect.Schema, name: []const u8) ?inspect.Table {
    for (schema.tables) |table| {
        if (sqlIdentEql(name, table.name)) return table;
    }
    return null;
}

fn findColumn(table: inspect.Table, name: []const u8) ?inspect.Column {
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

fn findColumnSql(table: inspect.Table, name: []const u8) ?inspect.Column {
    for (table.columns) |col| {
        if (sqlIdentEql(name, col.name)) return col;
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
    // PostgreSQL inspection emits authoritative int2/int4/int8 and
    // float4/float8 names. Reject narrowing there. Generic SQL aliases come
    // from SQLite affinity declarations, whose width is not authoritative.
    if (isIntegerType(a) and isIntegerType(b)) {
        const want_bits = fixedIntegerBits(a);
        const have_bits = fixedIntegerBits(b);
        if (want_bits != null and have_bits != null) return want_bits.? >= have_bits.?;
        return true;
    }
    // Text family
    if (isTextType(a) and isTextType(b)) return true;
    // Binary float family; decimal/numeric is text-backed and separate.
    if (isFloatType(a) and isFloatType(b)) {
        const want_bits = fixedFloatBits(a);
        const have_bits = fixedFloatBits(b);
        if (want_bits != null and have_bits != null) return want_bits.? >= have_bits.?;
        return true;
    }
    if (isNumericType(a) and isNumericType(b)) return true;
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

fn fixedIntegerBits(name: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(name, "int2")) return 16;
    if (std.ascii.eqlIgnoreCase(name, "int4")) return 32;
    if (std.ascii.eqlIgnoreCase(name, "int8")) return 64;
    return null;
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
        std.ascii.eqlIgnoreCase(name, "double");
}

fn fixedFloatBits(name: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(name, "float4")) return 32;
    if (std.ascii.eqlIgnoreCase(name, "float8")) return 64;
    return null;
}

fn isNumericType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "numeric") or
        std.ascii.eqlIgnoreCase(name, "decimal");
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
                try self.skipBlockComment();
                continue;
            }
            if (c == '\'') {
                try self.skipQuoted('\'', self.isPostgresEscapeString(self.index));
                continue;
            }
            if (c == '$' and try self.skipDollarQuoted()) {
                continue;
            }
            break;
        }
    }

    fn isPostgresEscapeString(self: Scanner, quote_start: usize) bool {
        if (quote_start == 0) return false;
        const prefix = self.sql[quote_start - 1];
        if (prefix != 'E' and prefix != 'e') return false;
        return quote_start == 1 or !isIdentContinue(self.sql[quote_start - 2]);
    }

    fn skipQuoted(self: *Scanner, quote: u8, backslash_escapes: bool) CheckError!void {
        self.index += 1;
        while (self.index < self.sql.len) {
            if (backslash_escapes and self.sql[self.index] == '\\') {
                if (self.index + 1 >= self.sql.len) return error.InvalidSql;
                self.index += 2;
                continue;
            }
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

    fn skipDollarQuoted(self: *Scanner) CheckError!bool {
        const start = self.index;
        var tag_end = start + 1;
        if (tag_end < self.sql.len and self.sql[tag_end] != '$') {
            if (!isIdentStart(self.sql[tag_end])) return false;
            tag_end += 1;
            while (tag_end < self.sql.len and isIdentContinue(self.sql[tag_end])) : (tag_end += 1) {}
        }
        if (tag_end >= self.sql.len or self.sql[tag_end] != '$') return false;

        const delimiter = self.sql[start .. tag_end + 1];
        const close_start = std.mem.indexOfPos(u8, self.sql, tag_end + 1, delimiter) orelse
            return error.InvalidSql;
        self.index = close_start + delimiter.len;
        return true;
    }

    fn skipBlockComment(self: *Scanner) CheckError!void {
        self.index += 2;
        var depth: usize = 1;
        while (self.index + 1 < self.sql.len) {
            if (self.sql[self.index] == '/' and self.sql[self.index + 1] == '*') {
                depth += 1;
                self.index += 2;
            } else if (self.sql[self.index] == '*' and self.sql[self.index + 1] == '/') {
                depth -= 1;
                self.index += 2;
                if (depth == 0) return;
            } else {
                self.index += 1;
            }
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
            const start = self.index;
            self.index += 1;
            while (self.index < self.sql.len) {
                if (self.sql[self.index] != close) {
                    self.index += 1;
                    continue;
                }
                if (self.index + 1 < self.sql.len and self.sql[self.index + 1] == close) {
                    self.index += 2;
                    continue;
                }
                self.index += 1;
                return self.sql[start..self.index];
            }
            return error.InvalidSql;
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

fn sqlIdentClose(raw: []const u8) ?u8 {
    if (raw.len < 2) return null;
    const close: u8 = switch (raw[0]) {
        '"' => '"',
        '`' => '`',
        '[' => ']',
        else => return null,
    };
    return if (raw[raw.len - 1] == close) close else null;
}

const SqlIdentIterator = struct {
    raw: []const u8,
    index: usize,
    end: usize,
    close: ?u8,

    fn init(raw: []const u8) SqlIdentIterator {
        const close = sqlIdentClose(raw);
        return .{
            .raw = raw,
            .index = if (close != null) 1 else 0,
            .end = if (close != null) raw.len - 1 else raw.len,
            .close = close,
        };
    }

    fn next(self: *SqlIdentIterator) ?u8 {
        if (self.index >= self.end) return null;
        const byte = self.raw[self.index];
        self.index += 1;
        if (self.close != null and byte == self.close.? and
            self.index < self.end and self.raw[self.index] == self.close.?)
        {
            self.index += 1;
        }
        return byte;
    }
};

fn sqlIdentEql(encoded: []const u8, decoded: []const u8) bool {
    var it = SqlIdentIterator.init(encoded);
    var index: usize = 0;
    while (it.next()) |byte| {
        if (index >= decoded.len or decoded[index] != byte) return false;
        index += 1;
    }
    return index == decoded.len;
}

fn sqlIdentsEql(a: []const u8, b: []const u8) bool {
    var a_it = SqlIdentIterator.init(a);
    var b_it = SqlIdentIterator.init(b);
    while (true) {
        const a_byte = a_it.next();
        const b_byte = b_it.next();
        if (a_byte != b_byte) return false;
        if (a_byte == null) return true;
    }
}

fn sqlIdentKeywordEql(encoded: []const u8, keyword: []const u8) bool {
    return sqlIdentClose(encoded) == null and std.ascii.eqlIgnoreCase(encoded, keyword);
}

/// Advance to a keyword at statement parenthesis depth zero. Quoted strings,
/// dollar-quoted bodies, identifiers, and comments are handled by Scanner.
fn seekTopLevelKeyword(sc: *Scanner, keyword: []const u8) CheckError!bool {
    var depth: usize = 0;
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) return false;
        const c = sc.peek() orelse return false;
        if (c == '(') {
            depth += 1;
            sc.advance();
            continue;
        }
        if (c == ')') {
            if (depth == 0) return error.InvalidSql;
            depth -= 1;
            sc.advance();
            continue;
        }
        if (depth == 0 and try sc.matchKeyword(keyword)) return true;
        if ((try sc.readIdentOrStar()) == null) sc.advance();
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

/// Parse table refs after FROM / JOIN. Returns empty slice if none found.
fn parseFromJoinTables(
    sql: []const u8,
    schema: inspect.Schema,
    buf: *[max_tables]TableRef,
    validate_using: bool,
) CheckError![]const TableRef {
    var sc = Scanner.init(sql);
    var count: usize = 0;
    var merge_buf: [max_projections]UsingMerge = undefined;
    var merge_count: usize = 0;

    if (!try seekTopLevelKeyword(&sc, "from")) return buf[0..0];

    // After FROM: table [alias] [, table [alias]]* [JOIN table [alias] ...]*
    while (sc.index < sc.sql.len) {
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
        // ON / USING clauses belong to the most recently appended right table.
        if (try sc.matchKeyword("using")) {
            if (validate_using) {
                try validateUsingClause(
                    &sc,
                    schema,
                    buf[0..count],
                    &merge_buf,
                    &merge_count,
                );
            } else {
                try skipJoinConstraint(&sc);
            }
            continue;
        }
        if (try sc.matchKeyword("on")) {
            try skipJoinConstraint(&sc);
            continue;
        }

        const table_name = (try sc.readIdentOrStar()) orelse {
            if (sc.peek() == '(') return error.UnknownTable;
            break;
        };
        if (sqlIdentEql(table_name, "*")) return error.InvalidSql;

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

        // CTE/subquery-derived relation shapes are opaque. Reject them rather
        // than falling back to unrelated schema tables and claiming success.
        if (findTableSql(schema, table_name)) |table| {
            if (count >= max_tables) return error.TooManyTables;
            buf[count] = .{ .name = table.name, .alias = alias };
            count += 1;
        } else return error.UnknownTable;
    }

    return buf[0..count];
}

fn skipJoinConstraint(sc: *Scanner) CheckError!void {
    // Skip until the next JOIN keyword or clause terminator. Parentheses keep
    // commas inside expressions / USING lists from ending the constraint.
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
        } else if ((try sc.readIdentOrStar()) == null) {
            sc.advance();
        }
    }
}

fn validateUsingClause(
    sc: *Scanner,
    schema: inspect.Schema,
    tables: []const TableRef,
    merges: *[max_projections]UsingMerge,
    merge_count: *usize,
) CheckError!void {
    if (tables.len < 2) return error.InvalidSql;
    const right = findTable(schema, tables[tables.len - 1].name) orelse return error.UnknownTable;

    try sc.skipTrivia();
    if (sc.peek() != '(') return error.InvalidSql;
    sc.advance();

    var clause_columns: [max_projections][]const u8 = undefined;
    var clause_count: usize = 0;
    while (true) {
        try sc.skipTrivia();
        const column = try sc.readIdentOrStar() orelse return error.InvalidSql;
        if (sqlIdentEql(column, "*")) return error.InvalidSql;
        if (clause_count >= max_projections) return error.TooManyProjections;
        for (clause_columns[0..clause_count]) |previous| {
            if (sqlIdentsEql(previous, column)) return error.InvalidSql;
        }
        clause_columns[clause_count] = column;
        clause_count += 1;

        const left_exposures = usingLeftExposureCount(schema, tables[0 .. tables.len - 1], merges[0..merge_count.*], column);
        if (left_exposures == 0 or findColumnSql(right, column) == null) return error.UnknownColumn;
        if (left_exposures > 1) return error.AmbiguousColumn;
        try recordUsingMerge(merges, merge_count, column);

        try sc.skipTrivia();
        if (sc.peek() == ',') {
            sc.advance();
            continue;
        }
        if (sc.peek() != ')') return error.InvalidSql;
        sc.advance();
        return;
    }
}

fn usingLeftExposureCount(
    schema: inspect.Schema,
    left: []const TableRef,
    merges: []const UsingMerge,
    column: []const u8,
) usize {
    var physical_count: usize = 0;
    for (left) |ref| {
        const table = findTable(schema, ref.name) orelse continue;
        if (findColumnSql(table, column) != null) physical_count += 1;
    }
    for (merges) |merge| {
        if (sqlIdentsEql(merge.column, column)) {
            return physical_count -| merge.reductions;
        }
    }
    return physical_count;
}

fn recordUsingMerge(
    merges: *[max_projections]UsingMerge,
    merge_count: *usize,
    column: []const u8,
) CheckError!void {
    for (merges[0..merge_count.*]) |*merge| {
        if (sqlIdentsEql(merge.column, column)) {
            merge.reductions += 1;
            return;
        }
    }
    if (merge_count.* >= max_projections) return error.TooManyProjections;
    merges[merge_count.*] = .{ .column = column, .reductions = 1 };
    merge_count.* += 1;
}

/// Parse simple SELECT projections up to FROM. Portable COUNT/MIN/MAX
/// projections are recognized; other expressions with `(` are skipped.
fn parseSelectProjections(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    if (!try seekTopLevelKeyword(&sc, "select")) return error.InvalidSql;

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

        // Parenthesized expressions and unsupported function calls are skipped.
        // Recognize only aggregate forms with portable result rules rather
        // than inferring arbitrary expressions.
        const item_start = sc.index;
        const function_name_is_quoted = switch (sc.sql[item_start]) {
            '"', '`', '[' => true,
            else => false,
        };
        const first = try sc.readIdentOrStar();
        if (first == null) {
            // literal / operator — skip until comma or FROM
            try skipSelectItem(&sc);
            continue;
        }

        try sc.skipTrivia();
        if (sc.peek() == '(') {
            const function_kind = if (function_name_is_quoted) null else projectionFunctionKind(first.?);
            if (function_kind) |kind| {
                var candidate = sc;
                if (try parseAggregateProjection(&candidate, kind)) |projection| {
                    buf[count] = projection;
                    count += 1;
                    sc = candidate;
                } else {
                    sc.index = item_start;
                    try skipSelectItem(&sc);
                    continue;
                }
            } else {
                sc.index = item_start;
                try skipSelectItem(&sc);
                continue;
            }
        } else {
            // first may be *, table, or column
            const projection_index = count;
            if (sqlIdentEql(first.?, "*")) {
                buf[count] = .{ .column = "*", .kind = .star };
                count += 1;
            } else if (sc.peek() == '.') {
                sc.advance();
                const second = try sc.readIdentOrStar() orelse return error.InvalidSql;
                if (sqlIdentEql(second, "*")) {
                    buf[count] = .{ .column = "*", .qualifier = first.?, .kind = .star };
                } else {
                    buf[count] = .{ .column = second, .qualifier = first.? };
                }
                count += 1;
            } else {
                buf[count] = .{ .column = first.? };
                count += 1;
            }

            try parseProjectionAlias(&sc, &buf[projection_index]);
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

fn projectionFunctionKind(name: []const u8) ?ProjectionKind {
    if (sqlIdentKeywordEql(name, "count")) return .count;
    if (sqlIdentKeywordEql(name, "min")) return .min;
    if (sqlIdentKeywordEql(name, "max")) return .max;
    return null;
}

fn parseAggregateProjection(sc: *Scanner, kind: ProjectionKind) CheckError!?Projection {
    if (sc.peek() != '(') return null;
    sc.advance();
    try sc.skipTrivia();
    const distinct = try sc.matchKeyword("distinct");
    if (distinct and kind != .count) return null;
    const first = try sc.readIdentOrStar() orelse return null;

    var projection = Projection{ .column = first, .kind = kind };
    if (sqlIdentEql(first, "*")) {
        if (kind != .count or distinct) return null;
    } else {
        try sc.skipTrivia();
        if (sc.peek() == '.') {
            sc.advance();
            const second = try sc.readIdentOrStar() orelse return null;
            if (sqlIdentEql(second, "*")) return null;
            projection.qualifier = first;
            projection.column = second;
        }
    }

    try sc.skipTrivia();
    if (sc.peek() != ')') return null;
    sc.advance();
    try sc.skipTrivia();
    if (sc.startsWithKeyword("filter") or sc.startsWithKeyword("over")) return null;
    try parseProjectionAlias(sc, &projection);
    try sc.skipTrivia();
    if (sc.index < sc.sql.len and
        sc.peek() != ',' and
        sc.peek() != ';' and
        !sc.startsWithKeyword("from")) return null;
    return projection;
}

fn parseProjectionAlias(sc: *Scanner, projection: *Projection) CheckError!void {
    try sc.skipTrivia();
    if (try sc.matchKeyword("as")) {
        const alias = try sc.readIdentOrStar() orelse return error.InvalidSql;
        if (sqlIdentEql(alias, "*")) return error.InvalidSql;
        projection.alias = alias;
        return;
    }

    // Bare alias before comma/from.
    const save = sc.index;
    if (!sc.startsWithKeyword("from") and sc.peek() != ',' and sc.peek() != ';') {
        if (try sc.readIdentOrStar()) |alias| {
            if (sqlIdentEql(alias, "*")) return error.InvalidSql;
            projection.alias = alias;
        } else {
            sc.index = save;
        }
    }
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

fn isClauseTerminator(sc: Scanner) bool {
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

fn isWhereTerminator(sc: Scanner) bool {
    return isClauseTerminator(sc);
}

fn isJoinOnTerminator(sc: Scanner) bool {
    return sc.startsWithKeyword("inner") or
        sc.startsWithKeyword("left") or
        sc.startsWithKeyword("right") or
        sc.startsWithKeyword("full") or
        sc.startsWithKeyword("cross") or
        sc.startsWithKeyword("join") or
        sc.startsWithKeyword("where") or
        sc.startsWithKeyword("on") or
        isClauseTerminator(sc) or
        (sc.peek() == ',');
}

fn isGroupByTerminator(sc: Scanner) bool {
    return sc.startsWithKeyword("having") or
        sc.startsWithKeyword("order") or
        sc.startsWithKeyword("limit") or
        sc.startsWithKeyword("offset") or
        sc.startsWithKeyword("fetch") or
        sc.startsWithKeyword("union") or
        sc.startsWithKeyword("intersect") or
        sc.startsWithKeyword("except") or
        sc.startsWithKeyword("returning") or
        sc.startsWithKeyword("window") or
        sc.startsWithKeyword("for") or
        (sc.peek() == ';');
}

fn isOrderByTerminator(sc: Scanner) bool {
    // Do not treat "order" as a terminator (we are already inside ORDER BY).
    return sc.startsWithKeyword("limit") or
        sc.startsWithKeyword("offset") or
        sc.startsWithKeyword("fetch") or
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
        "and",          "or",        "not",       "in",        "is",         "null",
        "true",         "false",     "unknown",   "between",   "like",       "ilike",
        "similar",      "escape",    "exists",    "case",      "when",       "then",
        "else",         "end",       "any",       "all",       "some",       "distinct",
        "cast",         "as",        "on",        "using",     "join",       "inner",
        "left",         "right",     "full",      "cross",     "outer",      "select",
        "from",         "where",     "group",     "order",     "by",         "limit",
        "offset",       "having",    "union",     "intersect", "except",     "returning",
        "window",       "over",      "partition", "asc",       "desc",       "nulls",
        "first",        "last",      "current",   "row",       "rows",       "unbounded",
        "preceding",    "following", "filter",    "collate",   "symmetric",  "asymmetric",
        "interval",     "date",      "time",      "timestamp", "at",         "zone",
        "both",         "leading",   "trailing",  "trim",      "extract",    "substring",
        "position",     "overlay",   "placing",   "values",    "default",    "new",
        "old",          "array",     "only",
        // EXTRACT field names / common type names (avoid false UnknownColumn)
             "year",      "month",      "day",
        "hour",         "minute",    "second",    "epoch",     "dow",        "doy",
        "week",         "quarter",   "decade",    "century",   "millennium", "microseconds",
        "milliseconds", "timezone",  "integer",   "int",       "int2",       "int4",
        "int8",         "bigint",    "smallint",  "text",      "varchar",    "char",
        "character",    "boolean",   "bool",      "real",      "float",      "float4",
        "float8",       "double",    "numeric",   "decimal",   "blob",       "bytea",
        "json",         "jsonb",     "uuid",      "serial",    "bigserial",  "money",
        "xml",
    };
    for (keywords) |kw| {
        if (sqlIdentKeywordEql(name, kw)) return true;
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

const TerminatorFn = *const fn (Scanner) bool;

fn isCloseParen(sc: Scanner) bool {
    return sc.peek() == ')';
}

/// Consume a `(…)` group and collect column refs inside it (including nested calls).
fn collectParenExpr(sc: *Scanner, buf: *[max_projections]Projection, start_count: usize) CheckError!usize {
    try sc.skipTrivia();
    if (sc.peek() != '(') return start_count;
    sc.advance();
    const count = try collectColumnRefs(sc, buf, start_count, isCloseParen);
    try sc.skipTrivia();
    if (sc.peek() == ')') sc.advance();
    return count;
}

/// Collect bare/qualified column refs from the current scanner position until
/// `is_terminator` returns true. Best-effort; not a full SQL expression parser.
///
/// Function calls and grouping parens recurse so argument columns are checked
/// (e.g. `lower(email)`, `coalesce(u.name, p.title)`).
fn collectColumnRefs(sc: *Scanner, buf: *[max_projections]Projection, start_count: usize, is_terminator: TerminatorFn) CheckError!usize {
    var count = start_count;
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) break;
        if (is_terminator(sc.*)) break;

        if (try skipBindMarker(sc)) continue;
        if (try skipNumber(sc)) continue;

        // Postgres / SQL type cast `::typename`
        if (sc.peek() == ':' and sc.index + 1 < sc.sql.len and sc.sql[sc.index + 1] == ':') {
            sc.advance();
            sc.advance();
            _ = try sc.readIdentOrStar();
            try sc.skipTrivia();
            if (sc.peek() == '(') _ = try collectParenExpr(sc, buf, count);
            continue;
        }

        // Grouping / nested expression
        if (sc.peek() == '(') {
            count = try collectParenExpr(sc, buf, count);
            continue;
        }

        const first = try sc.readIdentOrStar();
        if (first == null) {
            if (sc.index < sc.sql.len) sc.advance();
            continue;
        }
        if (sqlIdentEql(first.?, "*")) continue;

        try sc.skipTrivia();

        // CAST(x AS type) / AS type-name: skip the type token after AS.
        if (sqlIdentKeywordEql(first.?, "as")) {
            _ = try sc.readIdentOrStar();
            try sc.skipTrivia();
            if (sc.peek() == '(') try skipParenGroup(sc); // varchar(255)
            continue;
        }

        // Qualified name: qual.col or schema.func(...)
        if (sc.peek() == '.') {
            sc.advance();
            const second = try sc.readIdentOrStar() orelse return error.InvalidSql;
            try sc.skipTrivia();
            if (sc.peek() == '(') {
                // schema.func(...) — do not treat func as a column; scan args.
                count = try collectParenExpr(sc, buf, count);
                continue;
            }
            if (sqlIdentEql(second, "*") or isSqlNoiseIdent(second)) continue;
            if (isSqlNoiseIdent(first.?)) continue;
            if (count >= max_projections) return error.TooManyProjections;
            buf[count] = .{ .column = second, .qualifier = first.? };
            count += 1;
            continue;
        }

        // Function call: do not treat the function name as a column; scan args.
        if (sc.peek() == '(') {
            count = try collectParenExpr(sc, buf, count);
            continue;
        }

        if (isSqlNoiseIdent(first.?)) continue;
        if (count >= max_projections) return error.TooManyProjections;
        buf[count] = .{ .column = first.? };
        count += 1;
    }
    return count;
}

/// Collect bare/qualified column references from a simple WHERE clause.
/// Returns empty when no WHERE is present. Best-effort; not a full SQL parser.
fn parseWhereColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    if (!try seekTopLevelKeyword(&sc, "where")) return buf[0..0];

    const count = try collectColumnRefs(&sc, buf, 0, isWhereTerminator);
    return buf[0..count];
}

/// Collect column references from every JOIN ON clause. USING lists are
/// validated separately against both relation sides. Best-effort.
fn parseJoinOnColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    if (!try seekTopLevelKeyword(&sc, "from")) return buf[0..0];
    var count: usize = 0;
    var depth: usize = 0;
    while (sc.index < sc.sql.len) {
        try sc.skipTrivia();
        if (sc.index >= sc.sql.len) break;
        const c = sc.peek() orelse break;
        if (c == '(') {
            depth += 1;
            sc.advance();
            continue;
        }
        if (c == ')') {
            if (depth == 0) return error.InvalidSql;
            depth -= 1;
            sc.advance();
            continue;
        }
        if (depth == 0 and try sc.matchKeyword("on")) {
            count = try collectColumnRefs(&sc, buf, count, isJoinOnTerminator);
            continue;
        }
        if ((try sc.readIdentOrStar()) == null and sc.index < sc.sql.len) sc.advance();
    }
    return buf[0..count];
}

/// Collect bare/qualified column references from a HAVING clause.
/// Returns empty when no HAVING is present. Best-effort.
fn parseHavingColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    if (!try seekTopLevelKeyword(&sc, "having")) return buf[0..0];

    // HAVING uses the same terminators as WHERE (ORDER/LIMIT/…).
    const count = try collectColumnRefs(&sc, buf, 0, isWhereTerminator);
    return buf[0..count];
}

/// Collect bare/qualified column references from GROUP BY.
/// Returns empty when no GROUP BY is present. Best-effort.
fn parseGroupByColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    var found = false;
    while (try seekTopLevelKeyword(&sc, "group")) {
        try sc.skipTrivia();
        if (try sc.matchKeyword("by")) {
            found = true;
            break;
        }
    }
    if (!found) return buf[0..0];

    const count = try collectColumnRefs(&sc, buf, 0, isGroupByTerminator);
    return buf[0..count];
}

/// Collect bare/qualified column references from ORDER BY.
/// Returns empty when no ORDER BY is present. Best-effort.
fn parseOrderByColumnRefs(sql: []const u8, buf: *[max_projections]Projection) CheckError![]const Projection {
    var sc = Scanner.init(sql);
    var found = false;
    while (try seekTopLevelKeyword(&sc, "order")) {
        try sc.skipTrivia();
        if (try sc.matchKeyword("by")) {
            found = true;
            break;
        }
    }
    if (!found) return buf[0..0];

    const count = try collectColumnRefs(&sc, buf, 0, isOrderByTerminator);
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
    const check_join_on_value: bool = if (@hasField(@TypeOf(options), "check_join_on")) options.check_join_on else false;
    const check_group_by_value: bool = if (@hasField(@TypeOf(options), "check_group_by")) options.check_group_by else false;
    const check_order_by_value: bool = if (@hasField(@TypeOf(options), "check_order_by")) options.check_order_by else false;
    const level_value: CheckLevel = if (@hasField(@TypeOf(options), "level")) options.level else .none;

    const args_value: []const ArgSpec = comptime blk: {
        if (!@hasField(@TypeOf(options), "args")) break :blk &.{};
        const raw = options.args;
        if (@typeInfo(@TypeOf(raw)) == .@"struct" and !@typeInfo(@TypeOf(raw)).@"struct".is_tuple) {
            const fields = @typeInfo(@TypeOf(raw)).@"struct".fields;
            var out: [fields.len]ArgSpec = undefined;
            for (fields, 0..) |field, i| out[i] = .{ .name = field.name };
            const frozen = out;
            break :blk &frozen;
        }
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
        if (@TypeOf(raw) == type) {
            const fields = @typeInfo(raw).@"struct".fields;
            var out: [fields.len]FieldSpec = undefined;
            for (fields, 0..) |field, i| {
                out[i] = .{
                    .name = field.name,
                    .type_name = checkedZigTypeName(field.name, field.type),
                    .nullable = zigTypeNullable(field.type),
                };
            }
            const frozen = out;
            break :blk &frozen;
        }
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
        pub const check_join_on = check_join_on_value;
        pub const check_group_by = check_group_by_value;
        pub const check_order_by = check_order_by_value;
        pub const level = level_value;

        pub fn validate(schema: inspect.Schema) CheckError!void {
            try checkQuery(.{
                .sql = sql,
                .schema = schema,
                .args = args,
                .row = row,
                .from_table = from_table,
                .from_tables = from_tables,
                .level = level,
                .check_projections = check_projections,
                .check_where = check_where,
                .check_join_on = check_join_on,
                .check_group_by = check_group_by,
                .check_order_by = check_order_by,
            });
        }
    };
}

fn zigTypeNullable(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn zigTypeName(comptime T: type) ?[]const u8 {
    const base = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    if (base == bool) return "BOOLEAN";
    // SQL has no portable 8-bit integer; INT2 is the narrowest common carrier.
    if (base == i8 or base == u8 or base == i16 or base == u16) return "INT2";
    if (base == i32 or base == u32) return "INT4";
    if (base == i64 or base == u64 or base == isize or base == usize) return "INT8";
    if (base == f32) return "FLOAT4";
    if (base == f64) return "FLOAT8";
    if (base == []const u8 or base == sql_types.Text) return "TEXT";
    if (base == sql_types.Blob) return "BLOB";
    if (base == sql_types.Numeric) return "NUMERIC";
    if (base == sql_types.Uuid) return "UUID";
    if (@typeInfo(base) == .@"enum") return "TEXT";
    return null;
}

fn checkedZigTypeName(comptime field_name: []const u8, comptime T: type) []const u8 {
    return zigTypeName(T) orelse @compileError(
        "checkedQuery row field `" ++ field_name ++ "` uses unsupported type `" ++ @typeName(T) ++ "`",
    );
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

test "checkQuery enforces exact placeholder contracts" {
    const schema: inspect.Schema = .{ .tables = &.{} };

    try std.testing.expectError(error.PlaceholderCountMismatch, checkQuery(.{
        .sql = "select ?",
        .schema = schema,
    }));

    try checkQuery(.{
        .sql = "select $1, $1, $3",
        .schema = schema,
        .args = &.{ .{ .name = "one" }, .{ .name = "two" }, .{ .name = "three" } },
    });
    try std.testing.expectError(error.PlaceholderCountMismatch, checkQuery(.{
        .sql = "select ?3, ?",
        .schema = schema,
        .args = &.{ .{ .name = "one" }, .{ .name = "two" }, .{ .name = "three" } },
    }));
    try checkQuery(.{
        .sql = "select ?3, ?",
        .schema = schema,
        .args = &.{ .{ .name = "one" }, .{ .name = "two" }, .{ .name = "three" }, .{ .name = "four" } },
    });

    try std.testing.expectError(error.MixedPlaceholderStyles, checkQuery(.{
        .sql = "select :id, ?",
        .schema = schema,
        .args = &.{.{ .name = "id" }},
    }));
    try std.testing.expectError(error.DuplicateNamedParameter, checkQuery(.{
        .sql = "select :id",
        .schema = schema,
        .args = &.{ .{ .name = "id" }, .{ .name = "id" } },
    }));
}

test "typesCompatible accepts common cross-driver aliases" {
    try std.testing.expect(typesCompatible("INTEGER", "int4"));
    try std.testing.expect(typesCompatible("bigint", "INTEGER"));
    try std.testing.expect(typesCompatible("INT8", "int4"));
    try std.testing.expect(!typesCompatible("INT4", "int8"));
    try std.testing.expect(typesCompatible("TEXT", "varchar"));
    try std.testing.expect(typesCompatible("BOOLEAN", "bool"));
    try std.testing.expect(typesCompatible("BLOB", "bytea"));
    try std.testing.expect(typesCompatible("FLOAT8", "float4"));
    try std.testing.expect(!typesCompatible("FLOAT4", "float8"));
    try std.testing.expect(typesCompatible("NUMERIC", "decimal"));
    try std.testing.expect(!typesCompatible("FLOAT8", "numeric"));
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

test "checkedQuery accepts typed argument and row structs" {
    const schema = inspect.Schema{ .tables = &.{.{ .name = "users", .columns = &.{
        .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
        .{ .name = "email", .type_name = "TEXT", .nullable = false },
        .{ .name = "bio", .type_name = "TEXT", .nullable = true },
    } }} };
    const q = checkedQuery(.{
        .sql = "select id, email, bio from users where id = :id",
        .args = .{ .id = i64 },
        .row = struct { id: i64, email: []const u8, bio: ?[]const u8 },
        .from_table = "users",
    });
    try q.validate(schema);
}

test "typed checkedQuery validates zsql domain wrappers" {
    const schema = inspect.Schema{ .tables = &.{.{ .name = "documents", .columns = &.{
        .{ .name = "body", .type_name = "text", .nullable = false },
        .{ .name = "payload", .type_name = "bytea", .nullable = true },
        .{ .name = "amount", .type_name = "numeric", .nullable = false },
        .{ .name = "external_id", .type_name = "uuid", .nullable = false },
    } }} };
    const q = checkedQuery(.{
        .sql = "select body, payload, amount, external_id from documents",
        .row = struct {
            body: sql_types.Text,
            payload: ?sql_types.Blob,
            amount: sql_types.Numeric,
            external_id: sql_types.Uuid,
        },
        .from_table = "documents",
    });
    try q.validate(schema);
}

test "typed checkedQuery rejects authoritative numeric narrowing" {
    const schema = inspect.Schema{ .tables = &.{.{ .name = "metrics", .columns = &.{
        .{ .name = "wide_int", .type_name = "int8", .nullable = false },
        .{ .name = "narrow_int", .type_name = "int4", .nullable = false },
        .{ .name = "wide_float", .type_name = "float8", .nullable = false },
        .{ .name = "amount", .type_name = "numeric", .nullable = false },
    } }} };

    const narrow_int = checkedQuery(.{
        .sql = "select wide_int from metrics",
        .row = struct { wide_int: i32 },
        .from_table = "metrics",
    });
    try std.testing.expectError(error.TypeMismatch, narrow_int.validate(schema));

    const widened_int = checkedQuery(.{
        .sql = "select narrow_int from metrics",
        .row = struct { narrow_int: i64 },
        .from_table = "metrics",
    });
    try widened_int.validate(schema);

    const narrow_float = checkedQuery(.{
        .sql = "select wide_float from metrics",
        .row = struct { wide_float: f32 },
        .from_table = "metrics",
    });
    try std.testing.expectError(error.TypeMismatch, narrow_float.validate(schema));

    const decimal_as_float = checkedQuery(.{
        .sql = "select amount from metrics",
        .row = struct { amount: f64 },
        .from_table = "metrics",
    });
    try std.testing.expectError(error.TypeMismatch, decimal_as_float.validate(schema));
}

test "typed checkedQuery maps 8-bit integers to INT2" {
    try std.testing.expectEqualStrings("INT2", zigTypeName(i8).?);
    try std.testing.expectEqualStrings("INT2", zigTypeName(?u8).?);
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

test "checkQuery rejects oversized implicit schema scope" {
    const column = [_]inspect.Column{.{ .name = "id", .type_name = "INTEGER", .nullable = false }};
    var tables: [max_tables + 1]inspect.Table = undefined;
    for (&tables) |*table| {
        table.* = .{ .name = "table", .columns = &column };
    }

    try std.testing.expectError(error.TooManyTables, checkQuery(.{
        .sql = "select id",
        .schema = .{ .tables = &tables },
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    }));

    try std.testing.expectError(error.TooManyTables, checkQuery(.{
        .sql =
        \\select t1.id from table t1
        \\join table t2 on true join table t3 on true join table t4 on true
        \\join table t5 on true join table t6 on true join table t7 on true
        \\join table t8 on true join table t9 on true join table t10 on true
        \\join table t11 on true join table t12 on true join table t13 on true
        \\join table t14 on true join table t15 on true join table t16 on true
        \\join table t17 on true
        ,
        .schema = .{ .tables = tables[0..1] },
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    }));
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

test "checkQuery anchors projection scope and clauses outside CTE bodies" {
    const schema = inspect.Schema{ .tables = &.{
        .{ .name = "users", .columns = &.{
            .{ .name = "id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "email", .type_name = "TEXT", .nullable = false },
        } },
        .{ .name = "posts", .columns = &.{.{ .name = "user_id", .type_name = "INTEGER", .nullable = false }} },
        .{ .name = "audits", .columns = &.{.{ .name = "audit_only", .type_name = "TEXT", .nullable = false }} },
    } };

    try checkQuery(.{
        .sql =
        \\with audit_rows as (
        \\    select a.audit_only
        \\    from audits a join audits b on b.audit_only = a.audit_only
        \\    where a.audit_only is not null
        \\    group by a.audit_only
        \\    having count(*) > 0
        \\    order by a.audit_only
        \\)
        \\select u.email as address
        \\from users u join posts p on p.user_id = u.id
        \\where u.id > 0
        \\group by address
        \\having count(*) > 0
        \\order by address
        ,
        .schema = schema,
        .row = &.{.{ .name = "address", .type_name = "TEXT" }},
        .check_projections = true,
        .check_where = true,
        .check_join_on = true,
        .check_group_by = true,
        .check_order_by = true,
    });

    try checkQuery(.{
        .sql =
        \\with outer_cte as (
        \\    with inner_cte as (
        \\        select audit_only,
        \\               'select from where group order' as note,
        \\               $tag$( select from where group order )$tag$ as body
        \\        from audits
        \\    )
        \\    select audit_only from inner_cte
        \\)
        \\/* select ignored from audits */
        \\select id from users -- from audits
        \\where id > 0
        ,
        .schema = schema,
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
        .check_where = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql =
        \\with audit_rows as (select audit_only from audits)
        \\select missing from users
        ,
        .schema = schema,
        .check_projections = true,
    }));
    try std.testing.expectError(error.UnknownTable, checkQuery(.{
        .sql =
        \\with user_ids as (select id from users)
        \\select id from user_ids
        ,
        .schema = schema,
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    }));
    try std.testing.expectError(error.UnknownTable, checkQuery(.{
        .sql = "select id from (select id from users) nested",
        .schema = schema,
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
    }));
}

test "checkQuery resolves quoted table aliases and columns" {
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

    try checkQuery(.{
        .sql = "select \"u\".\"email\" from \"users\" as \"u\" where \"u\".\"id\" = :id",
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .row = &.{.{ .name = "u.email", .type_name = "TEXT" }},
        .check_projections = true,
        .check_where = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select \"u\".\"missing\" from \"users\" as \"u\"",
        .schema = schema,
        .check_projections = true,
    }));
}

test "checkQuery decodes doubled quoted identifier delimiters" {
    const schema = inspect.Schema{ .tables = &.{
        .{ .name = "weird\"table", .columns = &.{
            .{ .name = "say\"hi", .type_name = "TEXT", .nullable = false },
            .{ .name = "from", .type_name = "TEXT", .nullable = false },
        } },
        .{ .name = "tick`table", .columns = &.{.{ .name = "value`name", .type_name = "TEXT", .nullable = false }} },
        .{ .name = "left_table", .columns = &.{.{ .name = "shared\"id", .type_name = "INTEGER", .nullable = false }} },
        .{ .name = "right_table", .columns = &.{.{ .name = "shared\"id", .type_name = "INTEGER", .nullable = false }} },
    } };

    try checkQuery(.{
        .sql =
        \\select "a""b"."say""hi" as "out""name"
        \\from "weird""table" as "a""b"
        \\where "a""b"."say""hi" is not null
        \\group by "out""name"
        \\order by "out""name"
        ,
        .schema = schema,
        .row = &.{.{ .name = "out\"name", .type_name = "TEXT" }},
        .check_projections = true,
        .check_where = true,
        .check_group_by = true,
        .check_order_by = true,
    });
    try checkQuery(.{
        .sql = "select `t``a`.`value``name` as `result``name` from `tick``table` `t``a`",
        .schema = schema,
        .row = &.{.{ .name = "result`name", .type_name = "TEXT" }},
    });
    try checkQuery(.{
        .sql = "select \"where\".\"from\" as \"order\" from \"weird\"\"table\" as \"where\" group by \"order\"",
        .schema = schema,
        .row = &.{.{ .name = "order", .type_name = "TEXT" }},
        .check_group_by = true,
    });
    try checkQuery(.{
        .sql = "select l.\"shared\"\"id\" from left_table l join right_table r using (\"shared\"\"id\")",
        .schema = schema,
        .row = &.{.{ .name = "l.shared\"id", .type_name = "INTEGER" }},
        .check_join_on = true,
    });

    try std.testing.expectError(error.AmbiguousProjection, checkQuery(.{
        .sql = "select \"say\"\"hi\" as same, \"from\" as \"same\" from \"weird\"\"table\" group by same",
        .schema = schema,
        .check_group_by = true,
    }));
    try std.testing.expectError(error.InvalidSql, checkQuery(.{
        .sql = "select \"say\"\"hi from \"weird\"\"table\"",
        .schema = schema,
        .check_projections = true,
    }));

    try std.testing.expect(sqlIdentEql("[bracket]]name]", "bracket]name"));
    try std.testing.expect(sqlIdentsEql("[bracket]]name]", "\"bracket]name\""));
}

test "checkQuery ignores postgres literals and nested comments in WHERE" {
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

    try checkQuery(.{
        .sql =
        \\select id from users
        \\where id = :id
        \\  and email <> $tag$ :not_a_bind and missing_column $tag$
        \\  /* outer :ignored /* inner missing_column */ */
        ,
        .schema = schema,
        .args = &.{.{ .name = "id" }},
        .check_where = true,
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

test "checked row fields must be returned projections" {
    const schema = inspect.Schema{ .tables = &.{
        .{ .name = "users", .columns = &.{
            .{ .name = "id", .type_name = "int8", .nullable = false },
            .{ .name = "email", .type_name = "text", .nullable = false },
        } },
        .{ .name = "posts", .columns = &.{
            .{ .name = "id", .type_name = "int8", .nullable = false },
            .{ .name = "title", .type_name = "text", .nullable = false },
        } },
    } };

    try std.testing.expectError(error.RowFieldNotProjected, checkQuery(.{
        .sql = "select id from users",
        .schema = schema,
        .row = &.{ .{ .name = "id", .type_name = "INT8" }, .{ .name = "email", .type_name = "TEXT" } },
    }));

    const aliased = checkedQuery(.{
        .sql = "select email as address from users",
        .row = struct { address: []const u8 },
    });
    try aliased.validate(schema);
    try std.testing.expectError(error.RowFieldNotProjected, checkQuery(.{
        .sql = "select email as address from users",
        .schema = schema,
        .row = &.{.{ .name = "email", .type_name = "TEXT" }},
    }));

    try checkQuery(.{
        .sql = "select u.* from users u join posts p on true",
        .schema = schema,
        .row = &.{.{ .name = "email", .type_name = "TEXT" }},
    });
    try std.testing.expectError(error.RowFieldNotProjected, checkQuery(.{
        .sql = "select u.* from users u join posts p on true",
        .schema = schema,
        .row = &.{.{ .name = "title", .type_name = "TEXT" }},
    }));

    try std.testing.expectError(error.AmbiguousProjection, checkQuery(.{
        .sql = "select u.email as value, p.title as value from users u join posts p on true",
        .schema = schema,
        .row = &.{.{ .name = "value", .type_name = "TEXT" }},
    }));
    try std.testing.expectError(error.AmbiguousProjection, checkQuery(.{
        .sql = "select * from users u join posts p on true",
        .schema = schema,
        .row = &.{.{ .name = "id", .type_name = "INT8" }},
    }));
}

test "checked rows support bounded aggregate projection aliases" {
    const schema = inspect.Schema{ .tables = &.{.{
        .name = "users",
        .columns = &.{
            .{ .name = "id", .type_name = "int8", .nullable = false },
            .{ .name = "email", .type_name = "text", .nullable = true },
        },
    }} };

    const count_all = checkedQuery(.{
        .sql = "select count(*) as total from users",
        .row = struct { total: i64 },
    });
    try count_all.validate(schema);
    try checkQuery(.{
        .sql = "select count(*) as total",
        .schema = .{ .tables = &.{} },
        .row = &.{.{ .name = "total", .type_name = "INT8" }},
    });

    try checkQuery(.{
        .sql = "select count(distinct u.email) addresses from users u",
        .schema = schema,
        .row = &.{.{ .name = "addresses", .type_name = "INT8", .nullable = false }},
        .check_projections = true,
    });

    const extrema = checkedQuery(.{
        .sql = "select min(id) as first_id, max(email) as last_email from users",
        .row = struct { first_id: ?i64, last_email: ?[]const u8 },
    });
    try extrema.validate(schema);
    try std.testing.expectError(error.NullabilityMismatch, checkQuery(.{
        .sql = "select min(id) as first_id from users",
        .schema = schema,
        .row = &.{.{ .name = "first_id", .type_name = "INT8", .nullable = false }},
    }));
    try std.testing.expectError(error.TypeMismatch, checkQuery(.{
        .sql = "select max(id) as last_id from users",
        .schema = schema,
        .row = &.{.{ .name = "last_id", .type_name = "TEXT", .nullable = true }},
    }));
    try std.testing.expectError(error.TypeMismatch, checkQuery(.{
        .sql = "select count(*) as total from users",
        .schema = schema,
        .row = &.{.{ .name = "total", .type_name = "INT4" }},
    }));
    try std.testing.expectError(error.AmbiguousProjection, checkQuery(.{
        .sql = "select count(*) as total, id as total from users",
        .schema = schema,
        .row = &.{.{ .name = "total", .type_name = "INT8" }},
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select count(u.missing) as total from users u",
        .schema = schema,
        .row = &.{.{ .name = "total", .type_name = "INT8" }},
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select count(u.missing) from users u",
        .schema = schema,
        .check_projections = true,
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select min(u.missing) as first_id from users u",
        .schema = schema,
        .row = &.{.{ .name = "first_id", .type_name = "INT8", .nullable = true }},
    }));
    try std.testing.expectError(error.RowFieldNotProjected, checkQuery(.{
        .sql = "select count(*) from users",
        .schema = schema,
        .row = &.{.{ .name = "total", .type_name = "INT8" }},
    }));

    // Dialect-sensitive and context-sensitive expressions remain outside the
    // bounded inference contract, even when they expose an alias.
    for ([_][]const u8{
        "select sum(id) as total from users",
        "select count(id + 1) as total from users",
        "select count(*) filter (where id > 0) as total from users",
        "select count(*) over () as total from users",
        "select count(*)::bigint as total from users",
        "select \"count\"(id) as total from users",
        "select min(*) as total from users",
        "select min(distinct id) as total from users",
        "select max(id + 1) as total from users",
    }) |sql| {
        try std.testing.expectError(error.RowFieldNotProjected, checkQuery(.{
            .sql = sql,
            .schema = schema,
            .row = &.{.{ .name = "total", .type_name = "INT8" }},
        }));
    }
}

test "check level enables result-shape validation" {
    const schema = inspect.Schema{ .tables = &.{.{ .name = "users", .columns = &.{
        .{ .name = "id", .type_name = "INTEGER", .nullable = false },
    } }} };
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing from users",
        .schema = schema,
        .level = .result_shape,
    }));

    const checked = checkedQuery(.{
        .sql = "select missing from users",
        .level = .result_shape,
    });
    try std.testing.expectError(error.UnknownColumn, checked.validate(schema));

    try checkQuery(.{
        .sql = "select id from users group by missing",
        .schema = schema,
        .level = .result_shape,
    });
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select id from users group by missing",
        .schema = schema,
        .level = .result_types,
    }));
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

    // Casts should not be treated as unknown columns; function *names* are not columns.
    try checkQuery(.{
        .sql = "select id from users where id::text = :s and lower(email) = :e",
        .schema = schema,
        .args = &.{ .{ .name = "s" }, .{ .name = "e" } },
        .from_table = "users",
        .check_where = true,
    });

    // Function *arguments* are checked (email is valid).
    try checkQuery(.{
        .sql = "select id from users where lower(email) = :e and coalesce(active, 0) = 1",
        .schema = schema,
        .args = &.{.{ .name = "e" }},
        .from_table = "users",
        .check_where = true,
    });

    // Unknown column inside a function argument is rejected.
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select id from users where lower(missing_col) = :e",
        .schema = schema,
        .args = &.{.{ .name = "e" }},
        .from_table = "users",
        .check_where = true,
    }));

    // Nested / multi-arg functions and CAST … AS type.
    try checkQuery(.{
        .sql = "select id from users where cast(id as integer) > 0 and coalesce(lower(email), '') <> ''",
        .schema = schema,
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

test "checkQuery where flag also validates HAVING columns" {
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
        },
    };

    try checkQuery(.{
        .sql =
        \\select active, count(*) as n
        \\from users
        \\group by active
        \\having active = 1 and count(*) > 0
        ,
        .schema = schema,
        .from_table = "users",
        .check_where = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql =
        \\select active, count(*) as n
        \\from users
        \\group by active
        \\having missing_col = 1
        ,
        .schema = schema,
        .from_table = "users",
        .check_where = true,
    }));
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

test "checkQuery join ON column refs resolve against scope" {
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
        \\select u.email, p.title
        \\from users u
        \\join posts p on p.user_id = u.id
        ,
        .schema = schema,
        .check_join_on = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql =
        \\select u.email
        \\from users u
        \\join posts p on p.missing = u.id
        ,
        .schema = schema,
        .check_join_on = true,
    }));

    // Default off: bad ON columns ignored without the flag.
    try checkQuery(.{
        .sql =
        \\select u.email
        \\from users u
        \\join posts p on p.missing = u.id
        ,
        .schema = schema,
        .check_join_on = false,
    });
}

test "checkQuery join USING validates both relation sides" {
    const schema = inspect.Schema{ .tables = &.{
        .{ .name = "a", .columns = &.{
            .{ .name = "id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "tenant_id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "a_only", .type_name = "TEXT", .nullable = false },
        } },
        .{ .name = "b", .columns = &.{
            .{ .name = "id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "tenant_id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "b_only", .type_name = "TEXT", .nullable = false },
        } },
        .{ .name = "c", .columns = &.{.{ .name = "id", .type_name = "INTEGER", .nullable = false }} },
        .{ .name = "d", .columns = &.{.{ .name = "id", .type_name = "INTEGER", .nullable = false }} },
    } };

    try checkQuery(.{
        .sql = "select x.id from a x join b y using (id, tenant_id)",
        .schema = schema,
        .check_join_on = true,
    });
    // A prior USING merge exposes one logical id on the accumulated left side.
    try checkQuery(.{
        .sql = "select a.id from a join b using (id) join c using (id)",
        .schema = schema,
        .check_join_on = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select a.id from a join b using (a_only)",
        .schema = schema,
        .check_join_on = true,
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select a.id from a join b using (b_only)",
        .schema = schema,
        .check_join_on = true,
    }));
    try std.testing.expectError(error.AmbiguousColumn, checkQuery(.{
        .sql = "select a.id from a join b on true join c using (id)",
        .schema = schema,
        .check_join_on = true,
    }));
    try std.testing.expectError(error.AmbiguousColumn, checkQuery(.{
        .sql = "select a.id from a join b using (id) join c on true join d using (id)",
        .schema = schema,
        .check_join_on = true,
    }));
    try std.testing.expectError(error.InvalidSql, checkQuery(.{
        .sql = "select a.id from a join b using (id, id)",
        .schema = schema,
        .check_join_on = true,
    }));

    // Default off preserves the explicit bounded-check contract.
    try checkQuery(.{
        .sql = "select a.id from a join b using (missing)",
        .schema = schema,
    });
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select a.id from a join b using (missing)",
        .schema = schema,
        .level = .result_types,
    }));

    const joined = checkedQuery(.{
        .sql = "select a.id from a join b using (id)",
        .check_join_on = true,
    });
    try joined.validate(schema);
}

test "checkQuery join USING rejects capacity overflow" {
    var name_storage: [max_projections + 1][8]u8 = undefined;
    var left_columns: [max_projections + 1]inspect.Column = undefined;
    var right_columns: [max_projections + 1]inspect.Column = undefined;
    var sql_storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&sql_storage);
    try writer.writeAll("select l.c0 from left_table l join right_table r using (");
    for (0..max_projections + 1) |index| {
        const name = try std.fmt.bufPrint(name_storage[index][0..], "c{d}", .{index});
        left_columns[index] = .{ .name = name, .type_name = "INTEGER", .nullable = false };
        right_columns[index] = .{ .name = name, .type_name = "INTEGER", .nullable = false };
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(name);
    }
    try writer.writeAll(")");

    const schema = inspect.Schema{ .tables = &.{
        .{ .name = "left_table", .columns = &left_columns },
        .{ .name = "right_table", .columns = &right_columns },
    } };
    try std.testing.expectError(error.TooManyProjections, checkQuery(.{
        .sql = writer.buffered(),
        .schema = schema,
        .check_join_on = true,
    }));
}

test "checkQuery group by refs resolve columns and projection aliases" {
    const schema = inspect.Schema{ .tables = &.{.{
        .name = "users",
        .columns = &.{
            .{ .name = "id", .type_name = "INTEGER", .nullable = false },
            .{ .name = "email", .type_name = "TEXT", .nullable = false },
            .{ .name = "active", .type_name = "INTEGER", .nullable = false },
        },
    }} };

    try checkQuery(.{
        .sql = "select active, count(*) as total from users group by active, lower(email), 1",
        .schema = schema,
        .check_group_by = true,
    });
    try checkQuery(.{
        .sql = "select active as state, count(*) as total from users group by state",
        .schema = schema,
        .check_group_by = true,
    });
    try std.testing.expectError(error.AmbiguousProjection, checkQuery(.{
        .sql = "select active as key, email as key from users group by key",
        .schema = schema,
        .check_group_by = true,
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing as key from users group by key",
        .schema = schema,
        .check_group_by = true,
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select min(missing) as first_value from users group by first_value",
        .schema = schema,
        .check_group_by = true,
    }));
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select active from users group by missing",
        .schema = schema,
        .check_group_by = true,
    }));

    // GROUP BY scanning stops before HAVING; that clause remains controlled by
    // check_where / result_types.
    try checkQuery(.{
        .sql = "select active from users group by active having missing > 0",
        .schema = schema,
        .check_group_by = true,
    });
    // Default off keeps the existing bounded opt-in behavior.
    try checkQuery(.{
        .sql = "select active from users group by missing",
        .schema = schema,
    });

    const grouped = checkedQuery(.{
        .sql = "select active as state from users group by state",
        .check_group_by = true,
    });
    try grouped.validate(schema);
}

test "clause reference collection rejects capacity overflow" {
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    for (0..max_projections + 1) |_| try writer.writeAll("column ");

    var sc = Scanner.init(writer.buffered());
    var refs: [max_projections]Projection = undefined;
    try std.testing.expectError(
        error.TooManyProjections,
        collectColumnRefs(&sc, &refs, 0, isGroupByTerminator),
    );
}

test "checkQuery order by column refs resolve against scope" {
    const schema = inspect.Schema{
        .tables = &.{
            .{
                .name = "users",
                .columns = &.{
                    .{ .name = "id", .type_name = "INTEGER", .nullable = false, .primary_key = true },
                    .{ .name = "email", .type_name = "TEXT", .nullable = false },
                    .{ .name = "created_at", .type_name = "TEXT", .nullable = false },
                },
            },
        },
    };

    try checkQuery(.{
        .sql = "select id, email from users order by email asc, created_at desc nulls last",
        .schema = schema,
        .from_table = "users",
        .check_order_by = true,
    });

    try checkQuery(.{
        .sql = "select email as address from users order by address",
        .schema = schema,
        .row = &.{.{ .name = "address", .type_name = "TEXT" }},
        .check_order_by = true,
    });
    try checkQuery(.{
        .sql = "select email as address from users order by address",
        .schema = schema,
        .check_order_by = true,
    });
    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select missing as value from users order by value",
        .schema = schema,
        .check_order_by = true,
    }));
    try checkQuery(.{
        .sql = "select count(*) as total from users order by total",
        .schema = schema,
        .row = &.{.{ .name = "total", .type_name = "INT8" }},
        .check_order_by = true,
    });

    // Positional ORDER BY and keywords should not fail.
    try checkQuery(.{
        .sql = "select id, email from users order by 1, 2 desc",
        .schema = schema,
        .from_table = "users",
        .check_order_by = true,
    });

    try std.testing.expectError(error.UnknownColumn, checkQuery(.{
        .sql = "select id from users order by missing_col",
        .schema = schema,
        .from_table = "users",
        .check_order_by = true,
    }));

    // Default off.
    try checkQuery(.{
        .sql = "select id from users order by missing_col",
        .schema = schema,
        .from_table = "users",
        .check_order_by = false,
    });

    const q = checkedQuery(.{
        .sql = "select id from users order by email",
        .from_table = "users",
        .row = &.{.{ .name = "id", .type_name = "INTEGER" }},
        .check_order_by = true,
    });
    try q.validate(schema);
}
