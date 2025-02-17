const std = @import("std");
const terminal = @import("terminal.zig");

fn readExact(reader: anytype, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const bytes_read = try reader.read(buffer[total..]);
        if (bytes_read == 0) break; // reached EOF
        total += bytes_read;
    }
    return total;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout = std.io.getStdOut().writer();
    var args = std.process.args();
    if (!args.skip()) {
        try stdout.print("Usage: <video file>\n", .{});
        return;
    }
    const input_file = args.next().?;

    const term_size = try terminal.getTerminalSizeEven();

    const width: usize = term_size.cols;
    const height: usize = term_size.rows;
    const frame_size: usize = width * height;

    const size_args = try std.fmt.allocPrint(allocator, "scale={}:{},format=gray", .{ width, height });
    defer allocator.free(size_args);

    const ffmpeg_args = [_][]const u8{
        "ffmpeg",
        "-re",
        "-i",
        input_file,
        "-vf",
        size_args,
        "-f",
        "rawvideo",
        "-pix_fmt",
        "gray",
        "pipe:1",
    };

    var child = std.process.Child.init(&ffmpeg_args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const ffmpeg_stdout = child.stdout.?;

    try stdout.writeAll("\x1b[2J\x1b[H\x1b[?25l");

    var frame_buffer = try allocator.alloc(u8, width * height);
    defer allocator.free(frame_buffer);

    while (true) {
        const n = try readExact(ffmpeg_stdout.reader(), frame_buffer[0..]);
        if (n != frame_size) break;

        var ascii_buffer = try allocator.alloc(u8, (width + 1) * height);
        defer allocator.free(ascii_buffer);
        var ascii_index: usize = 0;
        const gradient = " .,:;i1tfLCG08@";
        const grad_len = gradient.len;
        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = frame_buffer[y * width + x];
                const idx = (pixel * (grad_len - 1)) / 255;
                ascii_buffer[ascii_index] = gradient[idx];
                ascii_index += 1;
            }
            ascii_buffer[ascii_index] = '\n';
            ascii_index += 1;
        }

        try stdout.writeAll("\x1b[H");
        try stdout.writeAll(ascii_buffer[0..ascii_index]);
    }

    // Wait for ffmpeg to exit and reset terminal
    _ = try child.wait();
    try stdout.writeAll("\x1b[?25h");
}
