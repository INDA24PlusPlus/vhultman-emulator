const std = @import("std");

export fn _start() i32 {
    const ptr = alloc(100)[0..100];
    for (ptr, 0..) |*b, i| {
        b.* = @intCast(i);
        write("loop iter\n");
    }

    var sum: i32 = 0;
    for (ptr) |b| {
        sum += @intCast(b);
    }

    write("Hello, World!\n");
    return sum;
}

fn alloc(number_of_bytes: u64) [*]u8 {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> [*]u8),
        : [number] "{a7}" (2),
          [number_of_bytes] "{a0}" (number_of_bytes),
        : "a1", "a7", "a0"
    );
}

fn write(data: []const u8) void {
    return asm volatile ("ecall"
        :
        : [number] "{a7}" (1),
          [bytes] "{a0}" (data.ptr),
          [len] "{a1}" (data.len),
        : ""
    );
}
