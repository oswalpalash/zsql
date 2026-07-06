pub const Error = error{
    DriverUnavailable,
    InvalidColumn,
    InvalidColumnType,
    InvalidBindValue,
    InvalidSql,
    StatementClosed,
    ConnectionClosed,
    OutOfMemory,
};
