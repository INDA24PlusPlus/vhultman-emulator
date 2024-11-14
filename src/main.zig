const std = @import("std");

const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const config = @import("config");

const Emulator = @import("Emulator.zig");
const Assembler = @import("Assembler.zig");

const window_title = "RV64I Emulator debug interface";

var prev_registers: [32]u64 = undefined;

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHintTyped(.context_version_major, gl_major);
    glfw.windowHintTyped(.context_version_minor, gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);
    glfw.windowHintTyped(.floating, true);

    const window = try glfw.Window.create(1920, 1080, window_title, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    std.debug.print("{b}\n", .{@as(u64, @bitCast(@as(i64, -1)))});

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    const gl = zopengl.bindings;

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    zgui.init(gpa);
    defer zgui.deinit();

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    _ = zgui.io.addFontFromFile(
        "assets/Roboto-Medium.ttf",
        std.math.floor(16.0 * scale_factor),
    );

    zgui.getStyle().scaleAllSizes(scale_factor);
    zgui.io.setConfigFlags(.{
        .dock_enable = true,
    });

    const src =
        \\ addi x10, x0, 10
        \\ addi x17, x0, 1
        \\ ecall
    ;
    var code = std.ArrayListAligned(u8, std.mem.page_size).init(gpa);
    defer code.deinit();

    var assembler = Assembler.init(src);
    try assembler.run(code.writer());
    _ = try code.addManyAsSlice(1 << 20);

    var emu = Emulator.init(gpa, code.items, 0);
    defer emu.deinit();

    prev_registers = emu.registers;

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var show_demo_window = true;

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        glfw.pollEvents();
        gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0.3, 0.5, 0.3, 1.0 });

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        // dock space
        const viewport = zgui.getMainViewport();
        _ = zgui.DockSpaceOverViewport(0, viewport, .{});

        // Windows.
        drawControls(&emu);
        drawInstructionList(&emu);
        drawRegisterWindow(&emu);
        zgui.showDemoWindow(&show_demo_window);

        zgui.backend.draw();
        window.swapBuffers();
    }
}

fn drawControls(emu: *Emulator) void {
    const Static = struct {
        var running = true;
    };

    zgui.setNextWindowPos(.{ .x = 50.0, .y = 200.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("Control", .{})) {
        if (zgui.button("Tick", .{})) {
            Static.running = emu.next() catch unreachable;
        }
        zgui.labelText("PC", "{d}", .{emu.pc});
        if (!Static.running) {
            zgui.text("Program finished with exit code {d}", .{emu.registers[10]});
        }
    }
    zgui.end();
}

fn drawInstructionList(emu: *const Emulator) void {
    if (!config.log_inst) return;

    zgui.setNextWindowPos(.{ .x = 50.0, .y = 200.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("Instructions", .{})) {
        const width, _ = zgui.getWindowSize();
        if (zgui.beginListBox("##inst", .{ .w = width - 5 })) {
            for (emu.inst_log.items) |inst| {
                _ = zgui.selectable(inst, .{});
            }
        }
        zgui.endListBox();
    }
    zgui.end();
}

fn drawRegisterWindow(emu: *const Emulator) void {
    const DisplayOption = enum {
        Hexadecimal,
        Binary,
        u64,
        i64,
    };

    const Static = struct {
        var selected_display_option: DisplayOption = .Hexadecimal;
    };

    zgui.setNextWindowPos(.{ .x = 50.0, .y = 200.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("Registers", .{})) {
        if (zgui.beginCombo("Format", .{ .preview_value = @tagName(Static.selected_display_option) })) {
            for (&[_]DisplayOption{ .Hexadecimal, .Binary, .u64, .i64 }) |option| {
                const slice = @tagName(option);
                const selected = Static.selected_display_option == option;
                if (zgui.selectable(slice, .{ .selected = selected })) {
                    Static.selected_display_option = option;
                }

                if (selected) {
                    zgui.setItemDefaultFocus();
                }
            }
            zgui.endCombo();
        }

        if (zgui.beginTable("registers", .{ .column = 2 })) {
            for (0..16) |row| {
                zgui.tableNextRow(.{});
                for (0..2) |column| {
                    _ = zgui.tableSetColumnIndex(@intCast(column));
                    const index = row * 2 + column;

                    const color: [4]f32 = if (prev_registers[index] == emu.registers[index])
                        .{ 1.0, 1.0, 1.0, 1.0 }
                    else
                        .{ 1.0, 0.0, 0.0, 1.0 };

                    switch (Static.selected_display_option) {
                        .Hexadecimal => zgui.textColored(color, "x{d}: 0x{x}", .{ index, emu.registers[index] }),
                        .Binary => zgui.textColored(color, "x{d}: 0b{b}", .{ index, emu.registers[index] }),
                        .u64 => zgui.textColored(color, "x{d}: {d}", .{ index, emu.registers[index] }),
                        .i64 => zgui.textColored(color, "x{d}: {d}", .{ index, @as(u64, @bitCast(emu.registers[index])) }),
                    }
                }
            }
        }
    }
    zgui.endTable();
    zgui.end();
}

test {
    _ = Emulator;
    _ = Assembler;
}
