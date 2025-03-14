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

    // First, extract audio to a temporary file
    // This approach ensures audio plays regardless of ASCII processing speed
    const temp_audio = "/tmp/vid2ascii_audio.wav";
    const extract_audio_args = [_][]const u8{
        "ffmpeg",
        "-y", // Overwrite output file if it exists
        "-i",
        input_file,
        "-vn", // Disable video
        "-acodec",
        "pcm_s16le",
        "-ar",
        "44100",
        "-ac",
        "2",
        temp_audio,
    };

    var extract_audio = std.process.Child.init(&extract_audio_args, allocator);
    extract_audio.stderr_behavior = .Ignore;
    try extract_audio.spawn();
    _ = try extract_audio.wait();

    // Start playing audio in background
    const play_audio_args = [_][]const u8{
        "ffplay",
        "-nodisp", // Don't display video
        "-autoexit", // Exit when playback is done
        temp_audio,
    };

    var audio_child = std.process.Child.init(&play_audio_args, allocator);
    audio_child.stderr_behavior = .Ignore;
    try audio_child.spawn();

    const term_size = try terminal.getTerminalSizeEven();
    const width: usize = term_size.cols;
    const height: usize = term_size.rows;
    const frame_size: usize = width * height;

    // Set up ffmpeg for video processing
    const size_args = try std.fmt.allocPrint(allocator, "scale={}:{},format=gray", .{ width, height });
    defer allocator.free(size_args);
    const ffmpeg_args = [_][]const u8{
        "ffmpeg",
        "-re", // Real-time rate (important for sync)
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

    var video_child = std.process.Child.init(&ffmpeg_args, allocator);
    video_child.stdout_behavior = .Pipe;
    video_child.stderr_behavior = .Ignore;
    try video_child.spawn();
    const ffmpeg_stdout = video_child.stdout.?;

    // Initialize terminal
    try stdout.writeAll("\x1b[2J\x1b[H\x1b[?25l"); // Clear screen, move cursor to home position, hide cursor

    // Allocate frame pixel buffer (for raw grayscale data from ffmpeg)
    var frame_buffer = try allocator.alloc(u8, width * height);
    defer allocator.free(frame_buffer);

    // Double-buffering for ASCII output
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

        // Swap buffers
        std.mem.swap([]u8, &front_buffer, &back_buffer);

        // Render the front buffer
        try stdout.writeAll("\x1b[H"); // Move cursor to home position
        try stdout.writeAll(front_buffer[0..ascii_index]);
    }

    // Clean up
    _ = try video_child.wait();
    _ = audio_child.kill() catch {};
    _ = try audio_child.wait();

    // Clean up temp file
    std.fs.cwd().deleteFile(temp_audio) catch {};

    try stdout.writeAll("\x1b[?25h"); // Show cursor again
}
