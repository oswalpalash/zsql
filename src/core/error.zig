pub const Error = error{
    DriverUnavailable,
    DriverError,
    InvalidColumn,
    InvalidColumnType,
    InvalidBindValue,
    InvalidSql,
    UnexpectedRow,
    StatementClosed,
    ConnectionClosed,
    OutOfMemory,
};
