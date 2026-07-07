pub const Error = error{
    DriverUnavailable,
    DriverError,
    InvalidColumn,
    InvalidColumnType,
    InvalidBindValue,
    InvalidSql,
    StatementClosed,
    ConnectionClosed,
    OutOfMemory,
};
