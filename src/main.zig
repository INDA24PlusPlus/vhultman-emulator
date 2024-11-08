const std = @import("std");
const assert = std.debug.assert;
const Emulator = @import("Emulator.zig");
const c = @cImport({
    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");

    // translate-c can't handle the static asserts so we get rid of them.
    @cDefine("NK_STATIC_ASSERT(exp)", "");

    @cDefine("NK_INCLUDE_FONT_BAKING", "");
    @cDefine("NK_INCLUDE_DEFAULT_FONT", "");
    @cDefine("NK_INCLUDE_STANDARD_IO", "");
    @cInclude("nuklear.h");
    @cInclude("nuklear_glfw_gl3.h");
});

const window_width = 1920;
const window_height = 1080;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    _ = c.glfwSetErrorCallback(glfwErrorCallback);
    assert(c.glfwInit() == c.GLFW_TRUE);
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 4);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 5);
    c.glfwWindowHint(c.GLFW_SCALE_TO_MONITOR, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    if (@import("builtin").mode == .Debug) {
        c.glfwWindowHint(c.GLFW_OPENGL_DEBUG_CONTEXT, c.GLFW_TRUE);
    } else {
        c.glfwWindowHint(c.GLFW_CONTEXT_NO_ERROR, c.GLFW_TRUE);
    }

    const window = c.glfwCreateWindow(window_width, window_height, "Emulator", null, null) orelse {
        std.log.err("Failed to create GLFW window", .{});
        std.process.exit(1);
    };
    defer c.glfwDestroyWindow(window);
    c.glfwMakeContextCurrent(window);

    if (c.gladLoadGLLoader(@ptrCast(&c.glfwGetProcAddress)) == 0) {
        std.log.err("Failed to setup GLAD", .{});
        std.process.exit(1);
    }

    var nk_glfw = std.mem.zeroes(c.nk_glfw);
    const max_vertex_buffer = 512 * 1024;
    const max_element_buffer = 128 * 1024;
    const ctx = c.nk_glfw3_init(&nk_glfw, window, c.NK_GLFW3_INSTALL_CALLBACKS);
    defer c.nk_glfw3_shutdown(&nk_glfw);
    {
        var font: ?*c.nk_font_atlas = undefined;
        c.nk_glfw3_font_stash_begin(&nk_glfw, &font);
        defer c.nk_glfw3_font_stash_end(&nk_glfw);
    }
    var bg: c.nk_colorf = .{
        .r = 0.10,
        .g = 0.18,
        .b = 0.24,
        .a = 1.0,
    };

    var width: i32 = undefined;
    var height: i32 = undefined;
    c.glfwGetWindowSize(window, &width, &height);
    c.glViewport(0, 0, width, height);

    //if (@import("builtin").mode == .Debug) {
    //    c.glDebugMessageCallback(glDebugCallback, null);
    //    c.glEnable(c.GL_DEBUG_OUTPUT_SYNCHRONOUS);
    //}

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 3) {
        std.process.fatal("Usage: ./rv64i_emu_gui <bin_file> <emulator_memory>", .{});
    }

    const file_name = args[1];

    const binary_file = std.fs.cwd().readFileAlloc(gpa, file_name, 1_000_000) catch |err| {
        std.process.fatal("Failed to open file {s} with error: {s}", .{ file_name, @errorName(err) });
    };
    defer gpa.free(binary_file);

    const memory_ammount = std.fmt.parseUnsigned(u32, args[2], 10) catch |err| {
        std.process.fatal("Failed to parse memory ammount with error: {s}", .{@errorName(err)});
    };

    const program_memory = try std.heap.page_allocator.alignedAlloc(u8, std.mem.page_size, memory_ammount);
    defer std.heap.page_allocator.free(program_memory);

    var emu = try Emulator.init(gpa, binary_file, program_memory);
    defer emu.deinit();

    var prev_register: [32]u64 = emu.registers;

    while (c.glfwWindowShouldClose(window) != c.GLFW_TRUE) {
        c.nk_glfw3_new_frame(&nk_glfw);
        c.glfwPollEvents();

        if (c.nk_begin(ctx, "Controls", c.nk_rect(25, @floatFromInt(height - 125), 120, 100), c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE |
            c.NK_WINDOW_MINIMIZABLE | c.NK_WINDOW_TITLE) == c.nk_true)
        {
            c.nk_layout_row_dynamic(ctx, 30, 1);
            if (c.nk_button_label(ctx, "Next") == c.nk_true) {
                prev_register = emu.registers;
                if (try emu.next()) {
                    std.debug.print("Program finished\n", .{});
                }
            }
            emu.pc = @intCast(c.nk_propertyi(ctx, "PC:", 0, @intCast(emu.pc), 1000, 4, 1));
        }
        c.nk_end(ctx);

        if (@import("config").enable_verbose_instructions) {
            if (c.nk_begin(
                ctx,
                "Instructions",
                c.nk_rect(@floatFromInt(width - 200 - 25), 25, 200, @floatFromInt(height - 50)),
                c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE |
                    c.NK_WINDOW_MINIMIZABLE | c.NK_WINDOW_TITLE,
            ) == c.nk_true) {
                c.nk_layout_row_dynamic(ctx, 15, 1);
                for (emu.verbose_inst.items) |str| {
                    c.nk_text(ctx, str, @intCast(str.len), c.NK_TEXT_LEFT);
                }
            }
            c.nk_end(ctx);
        }

        if (c.nk_begin(ctx, "Registers", c.nk_rect(25, 25, 600, 650), c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE |
            c.NK_WINDOW_MINIMIZABLE | c.NK_WINDOW_TITLE) == c.nk_true)
        {
            const S = struct {
                var format: enum { u64, i64, binary, hex } = .hex;
            };

            c.nk_layout_row_static(ctx, 30, 80, 1);
            c.nk_label(ctx, "Format", c.NK_TEXT_LEFT);
            c.nk_layout_row_dynamic(ctx, 30, 4);
            if (c.nk_option_label(ctx, "u64", @intFromBool(S.format == .u64)) == c.nk_true) {
                S.format = .u64;
            }
            if (c.nk_option_label(ctx, "i64", @intFromBool(S.format == .i64)) == c.nk_true) {
                S.format = .i64;
            }
            if (c.nk_option_label(ctx, "hex", @intFromBool(S.format == .hex)) == c.nk_true) {
                S.format = .hex;
            }
            if (c.nk_option_label(ctx, "binary", @intFromBool(S.format == .binary)) == c.nk_true) {
                S.format = .binary;
            }

            c.nk_layout_row_dynamic(ctx, 30, 2);
            var fmt_buf: [524]u8 = undefined;
            for (emu.registers, prev_register, 0..) |reg, prev_reg, idx| {
                const slice: [:0]const u8 = try switch (S.format) {
                    .hex => std.fmt.bufPrintZ(&fmt_buf, "Reg {d}: {x}", .{ idx, reg }),
                    .binary => std.fmt.bufPrintZ(&fmt_buf, "Reg {d}: {b}", .{ idx, reg }),
                    .i64 => std.fmt.bufPrintZ(&fmt_buf, "Reg {d}: {d}", .{ idx, @as(i64, @bitCast(reg)) }),
                    .u64 => std.fmt.bufPrintZ(&fmt_buf, "Reg {d}: {d}", .{ idx, reg }),
                };

                if (reg != prev_reg) {
                    c.nk_text_colored(ctx, slice, @intCast(slice.len), c.NK_TEXT_LEFT, .{ .r = 255, .g = 0.0, .b = 0.0, .a = 255.0 });
                } else {
                    c.nk_text(ctx, slice, @intCast(slice.len), c.NK_TEXT_LEFT);
                }
            }
        }
        c.nk_end(ctx);

        if (c.nk_begin(ctx, "Memory", c.nk_rect(650, 25, 600, 650), c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE |
            c.NK_WINDOW_MINIMIZABLE | c.NK_WINDOW_TITLE) == c.nk_true)
        {
            const S = struct {
                var start: i32 = (1 << 21) - 64;
                var end: i32 = 1 << 21;
            };

            c.nk_layout_row_dynamic(ctx, 30, 1);
            S.start = c.nk_propertyi(ctx, "Start:", 0, S.start, S.end, 1, 8);
            S.end = c.nk_propertyi(ctx, "End:", 0, S.end, 64_000, 1, 8);

            c.nk_layout_row_dynamic(ctx, 20, 17);
            var fmt: [525]u8 = undefined;
            for (emu.program_memory[@intCast(S.start)..@intCast(S.end)], 0..) |byte, idx| {
                var slice = try std.fmt.bufPrintZ(&fmt, "{d}-{d}: ", .{ idx, idx + 16 });
                if (idx % 16 == 0) {
                    c.nk_text(ctx, slice, @intCast(slice.len), c.NK_LEFT);
                }

                slice = try std.fmt.bufPrintZ(&fmt, "{x}", .{byte});
                c.nk_text(ctx, slice, @intCast(slice.len), c.NK_LEFT);
            }
        }
        c.nk_end(ctx);

        if (c.nk_begin(ctx, "Demo", c.nk_rect(1300, 50, 230, 250), c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE |
            c.NK_WINDOW_MINIMIZABLE | c.NK_WINDOW_TITLE) == c.nk_true)
        {
            const S = struct {
                var op: bool = true;
                var property: i32 = 20;
            };
            c.nk_layout_row_static(ctx, 30, 80, 1);
            if (c.nk_button_label(ctx, "button") == c.nk_true)
                std.debug.print("Button pressed\n", .{});

            c.nk_layout_row_dynamic(ctx, 30, 2);
            if (c.nk_option_label(ctx, "easy", @intFromBool(S.op)) == c.nk_true) {
                S.op = true;
            }
            if (c.nk_option_label(ctx, "hard", @intFromBool(!S.op)) == c.nk_true) {
                S.op = false;
            }

            c.nk_layout_row_dynamic(ctx, 25, 1);
            c.nk_property_int(ctx, "Compression:", 0, &S.property, 100, 10, 1);

            c.nk_layout_row_dynamic(ctx, 20, 1);
            c.nk_label(ctx, "background:", c.NK_TEXT_LEFT);
            c.nk_layout_row_dynamic(ctx, 25, 1);
            if (c.nk_combo_begin_color(ctx, c.nk_rgb_cf(bg), c.nk_vec2(c.nk_widget_width(ctx), 400)) == c.nk_true) {
                c.nk_layout_row_dynamic(ctx, 120, 1);
                bg = c.nk_color_picker(ctx, bg, c.NK_RGBA);
                c.nk_layout_row_dynamic(ctx, 25, 1);
                bg.r = c.nk_propertyf(ctx, "#R:", 0, bg.r, 1.0, 0.01, 0.005);
                bg.g = c.nk_propertyf(ctx, "#G:", 0, bg.g, 1.0, 0.01, 0.005);
                bg.b = c.nk_propertyf(ctx, "#B:", 0, bg.b, 1.0, 0.01, 0.005);
                bg.a = c.nk_propertyf(ctx, "#A:", 0, bg.a, 1.0, 0.01, 0.005);
                c.nk_combo_end(ctx);
            }
        }
        c.nk_end(ctx);

        c.glfwGetWindowSize(window, &width, &height);
        c.glViewport(0, 0, width, height);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glClearColor(bg.r, bg.g, bg.b, bg.a);
        c.nk_glfw3_render(&nk_glfw, c.NK_ANTI_ALIASING_ON, max_vertex_buffer, max_element_buffer);
        c.glfwSwapBuffers(window);
    }
}

fn glDebugCallback(
    _: c.GLenum,
    _: c.GLenum,
    _: c.GLuint,
    _: c.GLenum,
    _: c.GLsizei,
    message: ?[*:0]const u8,
    _: ?*const anyopaque,
) callconv(.C) void {
    std.log.err("{?s}", .{message});
}

fn glfwErrorCallback(err: i32, msg: ?[*:0]const u8) callconv(.C) void {
    std.log.err("GLFW error {d}: {?s}", .{ err, msg });
}
