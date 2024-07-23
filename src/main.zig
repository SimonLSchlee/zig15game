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
    barrierhit: ray.Sound,
    enabled: bool = true,

    fn init() Sounds {
        return .{
            .success = loadSound(@embedFile("movesuccess"), 0.5, "movesuccess.qoa"),
            .failed = loadSound(@embedFile("movefailed"), 0.5, "movefailed.qoa"),
            .winner = loadSound(@embedFile("winner"), 1.0, "winner.qoa"),
            .barrierhit = loadSound(@embedFile("barrierhit"), 1.0, "barrierhit.qoa"),
        };
    }
    fn deinit(self: *Sounds) void {
        ray.UnloadSound(self.success);
        ray.UnloadSound(self.failed);
        ray.UnloadSound(self.winner);
        ray.UnloadSound(self.barrierhit);
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

    const barrier = colora(237, 190, 21, 180);
    const barrier_hit = colora(237, 40, 21, 180);

    fn color(r: u8, g: u8, b: u8) ray.Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    fn colora(r: u8, g: u8, b: u8, a: u8) ray.Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

const Pos = @Vector(2, i32);
const PosZero: Pos = @splat(0);
const PosOne: Pos = @splat(1);
const PosTwo: Pos = @splat(2);
const PosInv: Pos = @splat(-1);

const BarrierPart = 30; // g.tile_size[0] / BarrierPart
const BarrierPos: Pos = @splat(@divTrunc(BarrierPart, 2));

fn posToVector2(pos: Pos) ray.Vector2 {
    return .{ .x = @floatFromInt(pos[0]), .y = @floatFromInt(pos[1]) };
}

const Geometry = struct {
    size: Pos,
    top_left: Pos,
    tile_size: Pos,
    center: Pos,
    top_line: Pos,
    bottom_line: Pos,

    top_spacing: i32,
    top_bar: i32,
    thirds: [2]i32,

    font_smaller_h: i32,

    font_smaller: i32,
    font_small: i32,
    font_big: i32,

    fn updateSize(g: *Geometry) void {
        const w = ray.GetScreenWidth();
        const h = ray.GetScreenHeight();
        g.size = Pos{ w, h };

        const vertical = @divFloor(h, 8);
        const horizontal = @divFloor(w, 5);
        const part = @min(vertical, horizontal);

        g.font_smaller_h = @max(20, @divTrunc(horizontal, 8) * 2);

        g.font_smaller = @max(20, @divTrunc(part, 6) * 2);
        g.font_small = @divTrunc(part, 6) * 4;
        g.font_big = @divTrunc(g.font_small * 3, 2);

        // constrain _h to not grow bigger then the normal one
        g.font_smaller_h = @min(g.font_smaller_h, g.font_smaller);

        g.tile_size = @splat(part);

        g.top_spacing = 10;
        g.top_bar = g.top_spacing * 2 + g.font_smaller;
        g.thirds[0] = @divTrunc(w, 3);
        g.thirds[1] = g.thirds[0] * 2;

        const half = g.tile_size * PosTwo;
        g.center = Pos{ @divTrunc(w, 2), @divTrunc(h, 2) };
        g.top_left = g.center - half;

        g.top_line = Pos{ g.center[0], part + @divTrunc(part, 3) };
        g.bottom_line = Pos{ g.center[0], h - part };
    }
};
var geometry: Geometry = undefined;

fn touchCoord() Pos {
    const fpos = ray.GetTouchPosition(0);
    return Pos{
        @intFromFloat(fpos.x),
        @intFromFloat(fpos.y),
    };
}

fn tapOrClickCoord() ?Pos {
    const gesture = ray.GetGestureDetected();
    const touches = ray.GetTouchPointCount();
    if (gesture == ray.GESTURE_TAP and touches == 1) return touchCoord();

    if (ray.IsMouseButtonPressed(ray.MOUSE_LEFT_BUTTON)) {
        const mpos = ray.GetMousePosition();
        return Pos{
            @intFromFloat(mpos.x),
            @intFromFloat(mpos.y),
        };
    }
    return null;
}

const tokens = [16][:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "" };
const empty_token = 15;

const Game = struct {
    const PartySequence = [_]f32{ 0, 0.1, 0.1, 0.1, 3 };

    empty: u8 = empty_token,
    cells: [16]u8,
    barriers: [24]bool = [1]bool{false} ** 24,
    hit_barrier: ?u8 = null,
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
    fn addSomeBarriers(self: *Game) void {
        var random = std.rand.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        const rand = random.random();
        for (&self.barriers) |*dest| {
            if (rand.uintLessThan(u8, 10) == 0) {
                dest.* = true;
            }
        }
    }
    fn hitBarrier(self: *Game, empty: u8, new_empty: u8) bool {
        const old = indexToCord(empty);
        const new = indexToCord(new_empty);
        const dir = old - new;
        const inverted = dir * PosInv;

        const horizontal = inverted[0] == 0;
        const delta: i32 = if (horizontal) inverted[1] else inverted[0];

        const smaller = if (delta < 0) new else old;
        const transformed = if (horizontal) smaller else Pos{ smaller[1], smaller[0] };

        const start = if (horizontal) 0 else self.barriers.len / 2;
        const offset: u8 = @intCast(if (horizontal) transformed[0] + transformed[1] * 4 else transformed[0] * 3 + transformed[1]);
        const barrier_index = start + offset;

        const res = self.barriers[barrier_index];
        self.hit_barrier = if (res) @intCast(barrier_index) else null;
        return res;
    }
    fn indexToCord(index: u8) Pos {
        return .{ index % 4, index / 4 };
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
        self.drawBarriers();

        if (solved) {
            self.won = true;
            self.partySequence();
            drawCenteredText("** You did it! **", g.top_line, g.font_big, colors.solved);
            drawCenteredText("Enter / F5: new game", g.bottom_line, g.font_small, colors.solved);
        }
    }

    fn drawBarriers(self: *Game) void {
        const g = &geometry;

        const ts = g.tile_size[0];
        const s = @divTrunc(ts, BarrierPart);

        var x: u8 = 0;
        var y: u8 = 0;
        for (self.barriers, 0..) |b, i| {
            const half = self.barriers.len / 2;
            const horizontal = i < half;

            var color = colors.barrier;
            if (self.hit_barrier != null and self.hit_barrier.? == i) color = colors.barrier_hit;
            if (b) {
                const p0 = g.top_left + Pos{ x, y } * g.tile_size;
                if (horizontal) {
                    const p1 = p0 + Pos{ 0, ts - s };
                    ray.DrawRectangle(p1[0], p1[1], ts, s * 2, color);
                } else {
                    const p1 = p0 + Pos{ ts - s, 0 };
                    ray.DrawRectangle(p1[0], p1[1], s * 2, ts, color);
                }
            }

            const mx: u8, const my: u8 = if (horizontal) .{ 4, 3 } else .{ 3, 4 };
            x += 1;
            if (x == mx) {
                x = 0;
                y += 1;
            }
            if (y == my) {
                y = 0;
            }
        }
    }

    fn drawCenteredText(text: [:0]const u8, pos: Pos, font_size: i32, tint: ray.Color) void {
        const e = getExtent(text, font_size);
        const p = pos - e / PosTwo;
        ray.DrawText(text.ptr, p[0], p[1], e[1], tint);
    }

    fn drawToken(x: u3, y: u3, i: u8) void {
        if (i != game.empty) {
            const text = tokens[game.cells[i]];
            const correct = i == game.cells[i];
            const c1 = if (correct) colors.correct else colors.normal;

            const g = &geometry;
            const p0 = g.top_left + Pos{ x, y } * g.tile_size;
            const p1 = p0;

            const margin: Pos = @divTrunc(g.tile_size, BarrierPos);
            const p2 = p1 + margin;
            const s2 = g.tile_size - margin * PosTwo;

            fixes.DrawRectangleLines(p2[0], p2[1], s2[0], s2[1], c1);

            const p_center = p1 + g.tile_size / PosTwo;
            const e = getExtent(text, g.font_small);
            const half_extent = e / PosTwo;
            const p3 = p_center - half_extent;
            ray.DrawText(text.ptr, p3[0], p3[1], e[1], c1);
        }
    }

    fn getExtent(text: [:0]const u8, font_size: i32) Pos {
        const w = ray.MeasureText(text.ptr, font_size);
        if (w < geometry.size[0]) {
            return Pos{ w, font_size };
        } else {
            return getExtent(text, @divFloor(font_size, 4) * 3);
        }
    }
};
var game = Game.init();

const Move = enum { no, up, down, left, right };
const UpdateMode = enum { internal, player };
fn updateToken(move: Move, mode: UpdateMode) void {
    const empty = game.empty;
    const new_empty = switch (move) {
        Move.up => if (empty / 4 < 3) empty + 4 else empty,
        Move.down => if (empty / 4 > 0) empty - 4 else empty,
        Move.left => if (empty % 4 < 3) empty + 1 else empty,
        Move.right => if (empty % 4 > 0) empty - 1 else empty,
        else => return,
    };

    if (empty == new_empty) {
        game.invalid = true;
        if (mode == .player) sounds.playSound(sounds.failed);
        return;
    }
    if (game.hitBarrier(empty, new_empty)) {
        game.invalid = true;
        if (mode == .player) sounds.playSound(sounds.barrierhit);
        return;
    }

    game.invalid = false;
    game.cells[empty] = game.cells[new_empty];
    game.cells[new_empty] = empty_token;
    game.empty = new_empty;
    if (mode == .player) sounds.playSound(sounds.success);
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
    const gesture = ray.GetGestureDetected();
    if (gesture != ray.GESTURE_NONE) {
        switch (gesture) {
            ray.GESTURE_SWIPE_UP => return Move.up,
            ray.GESTURE_SWIPE_DOWN => return Move.down,
            ray.GESTURE_SWIPE_LEFT => return Move.left,
            ray.GESTURE_SWIPE_RIGHT => return Move.right,
            else => {},
        }
    }

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
    var fuel: u16 = @as(u16, moves) * 10;
    while (n < moves and fuel > 0) {
        const move: Move = rand.enumValue(Move);
        updateToken(move, .internal);
        if (!game.invalid) n += 1;
        fuel -= 1;
    }
    game.invalid = false;
}

fn win() void {
    game = Game.init();
}
fn restart() void {
    game = Game.init();
    game.addSomeBarriers();
    shuffle(250);
}

fn startGestureDetected() bool {
    if (ray.IsKeyPressed(ray.KEY_ENTER)) return true;
    if (ray.IsKeyPressed(ray.KEY_S)) return true;

    if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_LEFT)) return true;
    if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_RIGHT)) return true;

    const gesture = ray.GetGestureDetected();
    if (gesture == ray.GESTURE_TAP) return true;
    if (gesture == ray.GESTURE_DOUBLETAP) return true;
    if (gesture == ray.GESTURE_HOLD) return true;

    return false;
}

const Scene = enum {
    start,
    pause,
    game,

    pub fn running(self: Scene) bool {
        return self == .game;
    }
    pub fn stopped(self: Scene) bool {
        return self != .game;
    }
};
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

    var scene: Scene = .start;
    var show_qrcode = false;
    const qrcode_data = @embedFile("qrcode");
    const qrcode = ray.LoadImageFromMemory(".png", qrcode_data.ptr, qrcode_data.len);
    defer ray.UnloadImage(qrcode);

    const qrcode_texture = ray.LoadTextureFromImage(qrcode);
    defer ray.UnloadTexture(qrcode_texture);
    ray.SetTextureFilter(qrcode_texture, ray.TEXTURE_FILTER_POINT);

    restart();

    var help = false;
    while (!ray.WindowShouldClose()) {
        if (ray.IsWindowResized()) geometry.updateSize();

        input: { // input
            if (tapOrClickCoord()) |pos| {
                if (pos[1] < geometry.top_bar) {
                    if (geometry.thirds[0] < pos[0] and pos[0] < geometry.thirds[1]) {
                        restart();
                        break :input;
                    }
                    if (pos[0] < geometry.thirds[0]) {
                        help = !help;
                        break :input;
                    }
                    if (help and geometry.thirds[1] < pos[0]) {
                        show_qrcode = !show_qrcode;
                    }
                }
            }
            if (ray.IsKeyPressed(ray.KEY_F1)) {
                help = !help;
                break :input;
            }
            if (ray.IsKeyPressed(ray.KEY_P)) sounds.toggle();
            if (ray.IsKeyPressed(ray.KEY_SPACE)) game.partyMore();

            if (!ray.IsAudioDeviceReady()) {
                // Firefox disables audio playback until user interaction
                // pause game to get user interaction
                scene = .pause;
                break :input;
            }
            if (scene.stopped()) {
                if (startGestureDetected()) {
                    scene = .game;
                } else {
                    break :input;
                }
            }

            if (!help) {
                if (ray.IsKeyPressed(ray.KEY_F3)) win();
                if (ray.IsKeyPressed(ray.KEY_F5)) restart();
                if (ray.IsKeyPressed(ray.KEY_ENTER)) restart();
                if (game.won) {
                    if (startGestureDetected()) restart();
                } else {
                    updateToken(getMove(), .player);
                }
            }
        }

        { // draw
            ray.BeginDrawing();
            defer ray.EndDrawing();

            ray.ClearBackground(colors.background);

            const ts = geometry.top_spacing;
            const vs = @divTrunc(geometry.font_smaller, 2);
            const y1 = ts + vs;
            ray.DrawText("F1: help", ts, ts, geometry.font_smaller, colors.normal);
            const p1 = Pos{ geometry.center[0], y1 };
            Game.drawCenteredText("restart", p1, geometry.font_smaller, colors.normal);

            if (help) {
                drawHelp();

                const third = geometry.thirds[0];
                const x2 = @divTrunc(third * 5, 2);
                const p2 = Pos{ x2, y1 };
                const tint = if (show_qrcode) colors.correct else colors.normal;
                Game.drawCenteredText("qrcode", p2, geometry.font_smaller, tint);

                if (show_qrcode) {
                    const spacing = Pos{ 40, geometry.top_bar * 2 };
                    const inner_size = geometry.size - spacing;
                    const min_size = @min(inner_size[0], inner_size[1]);

                    const qrcode_size = Pos{ qrcode.width, qrcode.height };
                    const max_size = @max(qrcode_size[0], qrcode_size[1]);

                    const scale = @divTrunc(min_size, max_size);
                    const qrcode_pixel_size = qrcode_size * @as(Pos, @splat(scale));

                    const p3 = geometry.center - @divTrunc(qrcode_pixel_size, PosTwo);
                    ray.DrawTextureEx(qrcode_texture, posToVector2(p3), 0, @floatFromInt(scale), ray.WHITE);
                }
            } else {
                switch (scene) {
                    .start => {
                        Game.drawCenteredText("Start Game!", geometry.top_line, geometry.font_big, colors.solved);
                        Game.drawCenteredText("Enter / Click", geometry.bottom_line, geometry.font_big, colors.solved);
                    },
                    .pause => {
                        Game.drawCenteredText("Paused", geometry.top_line, geometry.font_big, colors.solved);
                    },
                    .game => {
                        game.drawBoard();
                    },
                }
            }
        }
    }
}

fn drawHelp() void {
    const fs = geometry.font_smaller_h;

    const longest_string = "   by raylib technologies";
    const x_extent = fs * 5 + ray.MeasureText(longest_string, fs);
    const lines_y = 7 + 2 + 5 + 1 + 2;
    const y_extent = fs * lines_y;

    const extent = Pos{ x_extent, y_extent };
    const tl = geometry.center - extent / PosTwo;

    const x = tl[0];
    var y: i32 = tl[1];

    const sp = 8;

    _ = drawLines(x, y, fs, colors.normal, .{
        "w a s d:",
        "h j k l:",
        "arrow keys:",
        "F3:",
        "SPACE:",
        "F5 / Enter:",
        "P:",
    });
    y = drawLines(x + fs * sp, y, fs, colors.normal, .{
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
        "gui version:",
    });
    y += fs * 3;
    y = drawLines(x + fs * sp, y, fs, ray.WHITE, .{
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
