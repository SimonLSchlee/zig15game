const std = @import("std");
const stdout = std.io.getStdOut().writer();
const ray = @import("raylib.zig");

// This is based on https://ziggit.dev/t/15-puzzle-game/4350

const fixes = struct {
    // raylibs DrawRectangleLines currently draws crooked lines
    // but DrawRectangleLinesEx doesn't remove this if/when it has been fixed
    fn DrawRectangleLines(x: c_int, y: c_int, w: c_int, h: c_int, color: ray.Color) void {
        const rect = ray.Rectangle{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(w),
            .height = @floatFromInt(h),
        };
        ray.DrawRectangleLinesEx(rect, 1, color);
    }
};

const Sounds = struct {
    success: ray.Sound,
    failed: ray.Sound,
    winner: ray.Sound,
    enabled: bool = true,

    fn init() Sounds {
        return .{
            .success = loadSound(@embedFile("movesuccess"), 0.5, "movesuccess.qoa"),
            .failed = loadSound(@embedFile("movefailed"), 0.5, "movefailed.qoa"),
            .winner = loadSound(@embedFile("winner"), 1.0, "winner.qoa"),
        };
    }
    fn deinit(self: *Sounds) void {
        ray.UnloadSound(self.success);
        ray.UnloadSound(self.failed);
        ray.UnloadSound(self.winner);
    }
    fn loadSound(comptime data: anytype, volume: f32, export_name: [:0]const u8) ray.Sound {
        _ = export_name; // autofix
        const wave = ray.LoadWaveFromMemory(".qoa", data.ptr, data.len);
        // _ = ray.ExportWave(wave, export_name);
        defer ray.UnloadWave(wave);
        const sound = ray.LoadSoundFromWave(wave);
        ray.SetSoundVolume(sound, volume);
        return sound;
    }
    fn playSound(self: *const Sounds, sound: ray.Sound) void {
        if (self.enabled) ray.PlaySound(sound);
    }
    fn toggle(self: *Sounds) void {
        self.enabled = !self.enabled;
    }
};
var sounds: Sounds = undefined;

const colors = struct {
    const background = color(44, 72, 117);
    const normal = color(255, 173, 173);
    const correct = color(202, 255, 191);
    const solved = color(253, 255, 182);

    fn color(r: u8, g: u8, b: u8) ray.Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
};

const Pos = @Vector(2, i32);
const PosTwo: Pos = @splat(2);

const Geometry = struct {
    top_left: Pos,
    tile_size: Pos,
    center: Pos,
    top_line: Pos,
    bottom_line: Pos,
    font_smaller: i32,
    font_small: i32,
    font_big: i32,

    fn updateSize(g: *Geometry) void {
        const w = ray.GetScreenWidth();
        const h = ray.GetScreenHeight();

        const min = @min(w, h);
        const part = @divFloor(min, 8);

        g.font_smaller = @max(20, @divTrunc(part, 6) * 2);
        g.font_small = @divTrunc(part, 6) * 4;
        g.font_big = @divTrunc(g.font_small * 3, 2);

        g.tile_size = @splat(part);

        const half = g.tile_size * PosTwo;
        g.center = Pos{ @divTrunc(w, 2), @divTrunc(h, 2) };
        g.top_left = g.center - half;

        g.top_line = Pos{ g.center[0], part + @divTrunc(part, 3) };
        g.bottom_line = Pos{ g.center[0], h - part };
    }
};
var geometry: Geometry = undefined;

const tokens = [16][:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "" };
const empty_token = 15;

const Game = struct {
    const PartySequence = [_]f32{ 0, 0.1, 0.1, 0.1, 3 };

    empty: u8 = empty_token,
    cells: [16]u8,
    invalid: bool = false,
    won: bool = false,

    party: u16 = 0,
    party_partial: f32 = 0,

    fn init() Game {
        var g: Game = .{ .cells = undefined };
        var n: u8 = 0;
        while (n < 16) : (n += 1) {
            g.cells[n] = n;
        }
        return g;
    }

    fn partySequence(self: *Game) void {
        if (!self.won) return;
        if (self.party >= PartySequence.len) return;

        if (self.party_partial <= 0) {
            self.party += 1;
            if (self.party >= PartySequence.len) return;
            self.party_partial += PartySequence[self.party];
            sounds.playSound(sounds.winner);
        } else {
            self.party_partial -= ray.GetFrameTime();
        }
    }
    fn partyMore(self: *Game) void {
        if (!self.won) return;
        ray.StopSound(sounds.winner);
        self.party = 0;
        self.party_partial = 0;
    }

    fn drawBoard(self: *Game) void {
        const g = &geometry;
        const s = g.tile_size * @as(Pos, @splat(4));
        fixes.DrawRectangleLines(g.top_left[0], g.top_left[1], s[0], s[1], ray.WHITE);

        var solved = true;
        var i: u8 = 0;

        var x: u3 = 0;
        var y: u3 = 0;
        while (i < 16) : (i += 1) {
            drawToken(x, y, i);

            x += 1;
            if ((i + 1) % 4 == 0) {
                x = 0;
                y += 1;
            }
            if (i != self.cells[i]) solved = false;
        }

        if (solved) {
            self.won = true;
            self.partySequence();
            drawCenteredText("** You did it! **", g.top_line, g.font_big, colors.solved);
            drawCenteredText("Enter / F5: new game", g.bottom_line, g.font_small, colors.solved);
        }
    }

    fn drawCenteredText(text: [:0]const u8, pos: Pos, font_size: i32, tint: ray.Color) void {
        const p = pos - getExtent(text, font_size) / PosTwo;
        ray.DrawText(text.ptr, p[0], p[1], font_size, tint);
    }

    fn drawToken(x: u3, y: u3, i: u8) void {
        if (i != game.empty) {
            const text = tokens[game.cells[i]];
            const correct = i == game.cells[i];
            const c1 = if (correct) colors.correct else colors.normal;

            const g = &geometry;
            const p0 = g.top_left + Pos{ x, y } * g.tile_size;
            const p1 = p0;

            const margin: Pos = @splat(5);
            const p2 = p1 + margin;
            const s2 = g.tile_size - margin * PosTwo;

            fixes.DrawRectangleLines(p2[0], p2[1], s2[0], s2[1], c1);

            const p_center = p1 + g.tile_size / PosTwo;
            const half_extent = getExtent(text, g.font_small) / PosTwo;
            const p3 = p_center - half_extent;
            ray.DrawText(text.ptr, p3[0], p3[1], g.font_small, c1);
        }
    }

    fn getExtent(text: [:0]const u8, font_size: i32) Pos {
        return Pos{
            ray.MeasureText(text.ptr, font_size),
            font_size,
        };
    }
};
var game = Game.init();

const Move = enum { no, up, down, left, right };
const UpdateMode = enum { internal, player };
fn updateToken(move: Move, mode: UpdateMode) void {
    const empty = game.empty;
    const newEmpty = switch (move) {
        Move.up => if (empty / 4 < 3) empty + 4 else empty,
        Move.down => if (empty / 4 > 0) empty - 4 else empty,
        Move.left => if (empty % 4 < 3) empty + 1 else empty,
        Move.right => if (empty % 4 > 0) empty - 1 else empty,
        else => return,
    };

    if (empty == newEmpty) {
        game.invalid = true;
        if (mode == .player) sounds.playSound(sounds.failed);
    } else {
        game.invalid = false;
        game.cells[empty] = game.cells[newEmpty];
        game.cells[newEmpty] = empty_token;
        game.empty = newEmpty;
        if (mode == .player) sounds.playSound(sounds.success);
    }
}

const KeyMove = struct { c_int, Move };
fn directions(u: c_int, d: c_int, l: c_int, r: c_int) [4]KeyMove {
    return .{
        .{ u, Move.up },
        .{ d, Move.down },
        .{ l, Move.left },
        .{ r, Move.right },
    };
}
fn getMove() Move {
    const arrows = directions(ray.KEY_UP, ray.KEY_DOWN, ray.KEY_LEFT, ray.KEY_RIGHT);
    const wasd = directions(ray.KEY_W, ray.KEY_S, ray.KEY_A, ray.KEY_D);
    const hjkl = directions(ray.KEY_K, ray.KEY_J, ray.KEY_H, ray.KEY_L);
    const Moves = arrows ++ wasd ++ hjkl;

    inline for (Moves) |def| {
        if (ray.IsKeyPressed(def[0])) return def[1];
    }
    return Move.no;
}

fn shuffle(moves: u8) void {
    var random = std.rand.DefaultPrng.init(@intCast(std.time.microTimestamp()));
    const rand = random.random();
    var n: u8 = 0;
    while (n < moves) {
        const move: Move = rand.enumValue(Move);
        updateToken(move, .internal);
        if (!game.invalid) n += 1;
    }
    game.invalid = false;
}

fn win() void {
    game = Game.init();
}
fn restart() void {
    game = Game.init();
    shuffle(50);
}

pub fn main() !void {
    const default_size = 400;
    const width = default_size;
    const height = default_size;

    ray.SetConfigFlags(ray.FLAG_VSYNC_HINT | ray.FLAG_WINDOW_RESIZABLE);
    ray.InitWindow(width, height, "15 Game");
    defer ray.CloseWindow();

    ray.SetWindowMinSize(default_size, default_size);
    geometry.updateSize();

    ray.InitAudioDevice();
    defer ray.CloseAudioDevice();
    ray.SetMasterVolume(0.1);

    sounds = Sounds.init();
    defer sounds.deinit();

    restart();

    var help = false;
    while (!ray.WindowShouldClose()) {
        { // input
            if (ray.IsWindowResized()) geometry.updateSize();
            if (ray.IsKeyPressed(ray.KEY_F1)) help = !help;
            if (!help) {
                if (ray.IsKeyPressed(ray.KEY_F3)) win();
                if (ray.IsKeyPressed(ray.KEY_F5)) restart();
                if (ray.IsKeyPressed(ray.KEY_ENTER)) restart();
                if (!game.won) updateToken(getMove(), .player);
            }
            if (ray.IsKeyPressed(ray.KEY_P)) sounds.toggle();
            if (ray.IsKeyPressed(ray.KEY_SPACE)) game.partyMore();
        }

        { // draw
            ray.BeginDrawing();
            defer ray.EndDrawing();

            ray.ClearBackground(colors.background);
            ray.DrawText("F1: help", 10, 10, geometry.font_smaller, colors.normal);
            if (help) {
                drawHelp();
            } else {
                game.drawBoard();
            }
        }
    }
}

fn drawHelp() void {
    const fs = geometry.font_smaller;

    const longest_string = "   by raylib technologies";
    const x_extent = fs * 5 + ray.MeasureText(longest_string, fs);
    const lines_y = 7 + 2 + 5 + 1 + 2;
    const y_extent = fs * lines_y;

    const extent = Pos{ x_extent, y_extent };
    const tl = geometry.center - extent / PosTwo;

    const x = tl[0];
    var y: i32 = tl[1];

    _ = drawLines(x, y, fs, colors.normal, .{
        "w a s d:",
        "h j k l:",
        "arrow keys:",
        "F3:",
        "SPACE:",
        "F5 / Enter:",
        "P:",
    });
    y = drawLines(x + fs * 10, y, fs, colors.normal, .{
        "move",
        "move",
        "move",
        "win",
        "party more",
        "restart",
        "toggle sound",
    });

    y += fs * 2;
    _ = drawLines(x, y, fs, ray.WHITE, .{
        "Credits",
        "",
        "terminal version:",
        "",
        "raylib version:",
    });
    y += fs * 2;
    y = drawLines(x + fs * 10, y, fs, ray.WHITE, .{
        "Chris Boesch",
        "",
        "Simon L Schlee",
    });

    y += fs * 1;
    _ = drawLines(x, y, fs, ray.WHITE, .{
        "sounds:",
    });
    _ = drawLines(x + fs * 5, y, fs, ray.WHITE, .{
        "rFXGen",
        longest_string,
    });
}

fn drawLines(x: i32, y: i32, font_size: i32, tint: ray.Color, comptime lines: anytype) i32 {
    var y2 = y;
    inline for (lines) |line| {
        ray.DrawText(line, x, y2, font_size, tint);
        y2 += font_size;
    }
    return y2;
}
