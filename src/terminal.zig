const std = @import("std");

pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

pub fn getTerminalSize() !TerminalSize {
    if (@import("builtin").os.tag != .linux) @compileError("tough luck");

    return unixGetSize();
}

pub fn getTerminalSizeEven() !TerminalSize {
    var terminal_size = try getTerminalSize();
    terminal_size.rows -= @rem(terminal_size.rows, 2);
    terminal_size.cols -= @rem(terminal_size.cols, 2);

    return terminal_size;
}

fn unixGetSize() !TerminalSize {
    const stdout = std.io.getStdOut();

    var win_size: std.posix.winsize = undefined;
    const rc = std.os.linux.ioctl(stdout.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (rc != 0) {
        return error.GetTerminalSizeFailed;
    }

    return .{ .cols = win_size.col, .rows = win_size.row };
}
