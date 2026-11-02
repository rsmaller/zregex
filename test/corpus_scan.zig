const std = @import("std");

pub const Corpus = struct{
    items: []const []const u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *const @This()) void {
        for (self.items) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.items);
    } 
};


pub fn readCorpusFromFile(io: std.Io, allocator: std.mem.Allocator, filename: []const u8) !Corpus {
    var file: std.Io.File = undefined;
    if (std.fs.path.isAbsolute(filename)) {
        file = try std.Io.Dir.openFileAbsolute(io, filename, .{ .mode = .read_only, });
    } else {
        file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only, }); 
    }
    const file_len = try file.length(io);
    var reader_buf = try allocator.alloc(u8, file_len);
    defer allocator.free(reader_buf);
    @memset(reader_buf[0..], 0);
    var file_reader_internal = file.reader(io, reader_buf);
    var file_reader = &file_reader_internal.interface;
    var result_list: std.ArrayList([]const u8) = try .initCapacity(allocator, 2);
    defer result_list.deinit(allocator);
    while (true) {
        if (file_reader.takeSentinel('\n')) |_| {} 
        else |_| {
            break;
        }
        try result_list.append(allocator, try allocator.dupe(u8, reader_buf));
        @memset(reader_buf[0..], 0);
    }
    const result = try allocator.dupe([]const u8, result_list.items);
    return Corpus{ .items = result, .allocator = allocator};
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        @panic("Arg length is incorrect!");
    }
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    const corpus = try readCorpusFromFile(init.io, allocator, args[1]);
    defer corpus.deinit();
    for (corpus.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}
