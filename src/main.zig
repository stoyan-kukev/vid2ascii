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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    // Set up ffmpeg
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

    // Initialize terminal
    try stdout.writeAll("\x1b[2J\x1b[H\x1b[?25l"); // Clear screen, move cursor to home position, hide cursor

    // Allocate frame pixel buffer (for raw grayscale data from ffmpeg)
    var frame_buffer = try allocator.alloc(u8, width * height);
    defer allocator.free(frame_buffer);

    // Double-buffering for ASCII output
    // Instead of allocating and freeing the ASCII buffer every frame,
    // we'll pre-allocate two buffers and swap between them
    var front_buffer = try allocator.alloc(u8, (width + 1) * height);
    defer allocator.free(front_buffer);
    var back_buffer = try allocator.alloc(u8, (width + 1) * height);
    defer allocator.free(back_buffer);

    // Set the initial state of the buffers
    const gradient = " .,:;i1tfLCG08@";
    const grad_len = gradient.len;

    while (true) {
        // Read frame data
        const n = try readExact(ffmpeg_stdout.reader(), frame_buffer[0..]);
        if (n != frame_size) break;

        // Convert to ASCII in the back buffer
        var ascii_index: usize = 0;
        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = frame_buffer[y * width + x];
                const idx = (pixel * (grad_len - 1)) / 255;
                back_buffer[ascii_index] = gradient[idx];
                ascii_index += 1;
            }
            back_buffer[ascii_index] = '\n';
            ascii_index += 1;
        }

        // Swap buffers (by swapping pointers)
        // Note: In Zig, we need to actually swap the slice contents
        std.mem.swap([]u8, &front_buffer, &back_buffer);

        // Render the front buffer
        try stdout.writeAll("\x1b[H"); // Move cursor to home position
        try stdout.writeAll(front_buffer[0..ascii_index]);
    }

    // Wait for ffmpeg to exit and reset terminal
    _ = try child.wait();
    try stdout.writeAll("\x1b[?25h"); // Show cursor again
}
