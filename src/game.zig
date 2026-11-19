//! The game, apart from drawing it: the world and the player in it, the
//! keys held, the blocks to hand (the hotbar) and the time of day; what
//! the pointer is over, and building with it. Saved and loaded as one
//! file.
//!
//! Controls:
//!
//! As Minecraft's, for those who know them:
//!
//!     W A S D (or the arrows up and down)   walk
//!     W twice, quickly (or Ctrl)            sprint (till W is let go)
//!     the arrows left and right             turn
//!     Space                                 jump (swimming, flying, on a
//!                                           ladder: up)
//!     Space twice, quickly                  fly, or walk
//!     Shift                                 swimming, flying, on a ladder:
//!                                           down; walking: creep
//!     the mouse                             look around
//!     click                                 take a block away
//!     right click                           place a block; on a canoe,
//!                                           get in it
//!     middle click                          take that kind of block
//!     1 to 9, or the wheel                  choose a block from the hotbar
//!     E                                     all the blocks: the arrows
//!                                           left and right choose one,
//!                                           Tab (Shift+Tab) the next
//!                                           section, Enter or Esc close
//!     F1                                    hide the hotbar (and the cross)
//!     Esc                                   the menu (the game goes on)
//!     Y, N                                  let someone join, or not
//!
//! In a canoe: W and S paddle, A and D turn, Shift gets out (see boat.zig).
//!
//! The game starts in the menu, over the title scene (no island's: see
//! title.zig): an island is chosen there and joined, and the
//! menu's Leave goes back to it. Leaving the menu on an island takes the
//! mouse (it turns the view), and Esc gives it back with the menu.
//! Where the mouse cannot be taken, dragging looks around, a click builds
//! and pressing and holding takes away.
//!
//! Every change to the world goes through `edit`, which also queues it for
//! the others when playing together (see net.zig, and `Net`).

const std = @import("std");
const kete = @import("kete");
const blocks = @import("blocks.zig");
const weather_mod = @import("weather.zig");
const world_mod = @import("world.zig");
const player_mod = @import("player.zig");
const boat_mod = @import("boat.zig");
const furniture = @import("furniture.zig");
const math = @import("math.zig");
const avatar = @import("avatar.zig");

const Block = blocks.Block;
const World = world_mod.World;
const Player = player_mod.Player;
const V3 = math.V3;

/// How far away blocks can be built on.
pub const reach: f32 = 24;
/// Seconds a day lasts.
pub const day_length: f32 = 600;
/// How long water takes to flow a block.
pub const flow_step: f32 = 0.25;
/// Radians the view turns for a pixel dragged.
const look_speed: f32 = 0.006;
/// Radians a second the arrow keys turn it.
const turn_speed: f32 = 2.2;

/// The telescope (T): the view this much narrower (magnified), turning as
/// much slower, and seeing this much further, the fog further out: as far
/// as it can at the same frame rate, its view drawing less of the world
/// at each distance. Its view is about a fifth as wide as the usual one's
/// (20° to 102° across, at 16:9), so the same ground is √5 ≈ 2.2 times as
/// far, and only the square its circle is in is drawn. On a Raspberry Pi
/// 3 A+ at 1920x1080, it drew as many triangles (114,000 to 110,000 to
/// 120,000) at the same frame rate (33 to 34 fps) seeing 2.3 times as far.
pub const telescope_zoom: f32 = 4;
pub const telescope_reach: f32 = 2.3;
/// Pixels a press can move and still be a click.
const click_slop: f32 = 8;
/// Seconds between two presses of Space that fly (or walk), or of W that
/// sprint.
const double_tap: f32 = 0.3;

/// A change to the world, as sent to the others.
pub const Edit = struct {
    cell: world_mod.Pos,
    block: Block,
};

/// A game nearby, on the network: its computer's name and where to join it.
pub const Nearby = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    addr: [4]u8,
    port: u16,

    pub fn name(n: *const Nearby) []const u8 {
        return n.name_buf[0..n.name_len];
    }

    pub fn setName(n: *Nearby, s: []const u8) void {
        n.name_len = @intCast(@min(s.len, n.name_buf.len));
        @memcpy(n.name_buf[0..n.name_len], s[0..n.name_len]);
    }
};

/// Playing together: what net.zig tells the game, and what the game (the
/// menu, the keys) asks of it.
pub const Net = struct {
    status: Status = .alone,
    /// Games nearby, for the menu.
    nearby: []const Nearby = &.{},
    /// One the menu chose to ask to join.
    join: ?Nearby = null,
    /// Leave the game joined (or stop asking).
    leave: bool = false,
    /// Someone asking to join this game (their name), and the answer.
    request: ?[]const u8 = null,
    answer: ?bool = null,
    /// Changes made here, for the others.
    outbox: std.ArrayList(Edit) = .empty,
    /// The others playing, as drawn.
    others: []const player_mod.Other = &.{},

    pub const Status = union(enum) {
        alone,
        /// Others (this many) have joined this game.
        hosting: u8,
        /// Asking the game with this name to join it.
        asking: []const u8,
        /// Playing in the game with this name (its world, not this one).
        joined: []const u8,
    };

    /// Whether changes here go to others.
    pub fn sharing(n: *const Net) bool {
        return switch (n.status) {
            .hosting => |count| count > 0,
            .joined => true,
            else => false,
        };
    }
};

pub const Game = struct {
    gpa: std.mem.Allocator,
    world: *World,
    player: Player,
    /// The canoe the player is in, being paddled.
    boat: ?boat_mod.Boat = null,
    hotbar: [9]Block = blocks.starting_hotbar,
    slot: u8 = 0,
    /// Through the day, from 0 (midnight) to 1; 0.5 is noon.
    time_of_day: f32 = 0.34,
    /// Days gone by (for the weather, which goes on from day to day).
    day: u32 = 0,
    /// Seconds since the game started (for things that move).
    clock: f32 = 0,
    /// Time since water last flowed.
    flow_wait: f32 = 0,
    /// Keys held.
    held: std.EnumSet(kete.KeyboardKey) = .empty,
    /// When Space was last pressed, if a second press now would be a
    /// double tap.
    space_at: ?f32 = null,
    /// The same, of W.
    w_at: ?f32 = null,
    /// Sprinting (W pressed twice, quickly), till W is let go.
    sprinting: bool = false,
    /// The hotbar and the cross in the middle hidden (F1).
    hud_hidden: bool = false,
    /// Looking through the telescope (T).
    telescope: bool = false,
    palette_open: bool = false,
    /// The palette's section shown (see blocks.sections): it opens at the
    /// chosen block's.
    palette_section: usize = 0,
    /// The menu: the game's options, over the game, which goes on behind
    /// it (the player standing still). The game starts in it, so the mouse
    /// is not taken before it is wanted.
    menu_open: bool = true,
    /// Before an island is joined (or after one is left): the title
    /// scene behind the menu, which stays open.
    title: bool = false,
    /// The menu's tab shown.
    menu_tab: MenuTab = .islands,
    /// The islands kept (main.zig finds them), the one played first.
    islands: Islands = .{},
    /// Asked for in the menu, for main.zig to do (it keeps the islands).
    island_action: ?IslandAction = null,
    /// The island asked to be deleted, until it is said for sure.
    delete_asked: ?u8 = null,
    /// Asked to quit (main.zig saves first).
    quit_asked: bool = false,
    /// Frames a second, each second, the oldest first (for the menu's
    /// graph).
    fps_history: [fps_seconds]f32 = @splat(0),
    fps_count: u8 = 0,
    /// How big the window is drawn, of its size across and down (the
    /// display stretches it): from half to all of it.
    quality: f32 = 1,
    /// The view's size, and the pointer in it (if it is there).
    view_size: [2]f32 = .{ 1, 1 },
    pointer: ?[2]f32 = null,
    /// The block the pointer is over.
    target: ?player_mod.Hit = null,
    /// A press in the view: where, and whether it has become a drag.
    press: ?struct { at: [2]f32, last: [2]f32, dragging: bool } = null,
    /// The mouse can be taken (the shell can lock the pointer), and is:
    /// it turns the view, and its buttons act on the block in the middle.
    can_capture: bool = false,
    captured: bool = false,
    /// For the window: take the mouse (true) or give it back (false).
    capture_wanted: ?bool = null,
    /// What happened, shown for a moment.
    message: []const u8 = "",
    message_until: f32 = 0,
    /// The world changed since it was saved.
    unsaved: bool = false,
    /// Playing together.
    net: Net = .{},
    /// How the player looks, and the name they chose ("" for the
    /// computer's), as the others see them (and the Player tab shows).
    look: avatar.Look = .{},
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, w: *World) Game {
        return .{ .gpa = gpa, .world = w, .player = .{ .pos = w.spawn, .yaw = w.spawn_yaw } };
    }

    pub fn deinit(g: *Game) void {
        g.net.outbox.deinit(g.gpa);
    }

    pub fn selected(g: *const Game) Block {
        return g.hotbar[g.slot];
    }

    pub fn camera(g: *const Game) math.Camera {
        var c = g.player.camera();
        if (g.telescope) {
            c.fov = 2 * std.math.atan(@tan(c.fov / 2) / telescope_zoom);
            c.far *= telescope_reach;
        }
        return c;
    }

    /// How much slower the view turns (through the telescope).
    fn lookScale(g: *const Game) f32 {
        return if (g.telescope) 1 / telescope_zoom else 1;
    }

    /// How far one sees, of the usual view distance.
    pub fn seeing(g: *const Game) f32 {
        return if (g.telescope) telescope_reach else 1;
    }

    pub fn say(g: *Game, text: []const u8) void {
        g.message = text;
        g.message_until = g.clock + 2;
    }

    pub fn messageShown(g: *const Game) ?[]const u8 {
        return if (g.clock < g.message_until and g.message.len > 0) g.message else null;
    }

    // --- Input -----------------------------------------------------------------------

    /// A key went down or up (where it is on the keyboard, whatever the
    /// layout: WASD are where they are).
    pub fn key(g: *Game, code: kete.KeyboardKey, pressed: bool) void {
        const was_held = g.held.contains(code);
        g.held.setPresent(code, pressed);
        // Letting go of W stops a sprint.
        if (!pressed and (code == .w or code == .up)) g.sprinting = false;
        if (!pressed or was_held) return;
        // Someone asking to join: Y lets them, N does not (in the menu
        // too).
        if (g.net.request != null and (code == .y or code == .n)) {
            g.net.answer = code == .y;
            return;
        }
        // In the menu, only Esc (back to the game) and Tab (the next tab;
        // with Shift, the one before) do anything.
        if (g.menu_open) {
            if (code == .escape and !g.title) g.closeMenu();
            if (code == .tab) {
                const n: i32 = std.enums.values(MenuTab).len;
                const dir: i32 = if (g.held.contains(.left_shift) or g.held.contains(.right_shift)) -1 else 1;
                g.showMenuTab(@intCast(@mod(@as(i32, @intFromEnum(g.menu_tab)) + dir, n)));
            }
            return;
        }
        // The palette: the arrows choose a block, Tab another section,
        // Enter (or Esc, or E) closes it.
        if (g.palette_open) switch (code) {
            .left => return g.paletteStep(-1),
            .right => return g.paletteStep(1),
            .tab => return g.paletteSection(if (g.held.contains(.left_shift) or g.held.contains(.right_shift)) -1 else 1),
            .enter, .escape, .e => return g.closePalette(),
            else => {},
        };
        switch (code) {
            .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 => g.choose(@intCast(@intFromEnum(code) - @intFromEnum(kete.KeyboardKey.digit_1))),
            .left_shift, .right_shift => g.leaveBoat(),
            .space => {
                if (g.boat != null) return;
                if (g.space_at) |at| if (g.clock - at <= double_tap) {
                    g.player.flying = !g.player.flying;
                    g.player.vel[1] = 0;
                    g.say(if (g.player.flying) "Flying" else "Walking");
                    // A third press starts again.
                    g.space_at = null;
                    return;
                };
                g.space_at = g.clock;
            },
            .w, .up => {
                if (g.w_at) |at| if (g.clock - at <= double_tap) {
                    g.sprinting = true;
                    g.w_at = null;
                    return;
                };
                g.w_at = g.clock;
            },
            .f1 => g.hud_hidden = !g.hud_hidden,
            .t => {
                g.telescope = !g.telescope;
                g.say(if (g.telescope) "Telescope" else "Telescope away");
            },
            .e => if (g.palette_open) g.closePalette() else {
                g.palette_open = true;
                g.palette_section = blocks.sectionOf(g.selected());
                // Its blocks are chosen with the pointer.
                if (g.captured) g.capture_wanted = false;
            },
            .escape => if (g.palette_open) g.closePalette() else g.openMenu(),
            else => {},
        }
    }

    /// The menu, over the game (which goes on): the mouse is given back to
    /// use the menu with.
    pub fn openMenu(g: *Game) void {
        g.menu_open = true;
        g.palette_open = false;
        g.press = null;
        if (g.captured) g.capture_wanted = false;
    }

    /// Back to the game, which takes the mouse (not from the title scene:
    /// an island is joined from the menu).
    pub fn closeMenu(g: *Game) void {
        if (g.title) return;
        g.menu_open = false;
        g.takeMouse();
    }

    pub fn closePalette(g: *Game) void {
        g.palette_open = false;
        g.takeMouse();
    }

    /// In the game, the mouse is taken if it can be.
    fn takeMouse(g: *Game) void {
        if (g.can_capture and !g.captured) g.capture_wanted = true;
    }

    /// The window took the mouse, or gave it back. Given back while
    /// playing (the shell took it): the menu, as Esc would.
    pub fn pointerLocked(g: *Game, locked: bool) void {
        g.captured = locked;
        if (!locked and !g.menu_open and !g.palette_open) g.openMenu();
    }

    // Playing together (from the menu and the request shown).

    /// Lets the player asking join (Y).
    pub fn allowJoin(g: *Game) void {
        if (g.net.request != null) g.net.answer = true;
    }

    /// Does not (N).
    pub fn denyJoin(g: *Game) void {
        if (g.net.request != null) g.net.answer = false;
    }

    /// Asks the game `n` (from the menu) to join it.
    pub fn joinNearby(g: *Game, n: Nearby) void {
        g.net.join = n;
    }

    /// Leaves the game joined, back to this island.
    pub fn leaveGame(g: *Game) void {
        g.net.leave = true;
    }

    /// Joined: plays in the host's world (`data`, as `World.encode` wrote
    /// it), standing at `pos`; back to the game, from the menu.
    pub fn joinWorld(g: *Game, data: []const u8, pos: V3, yaw: f32, time: f32, day: u32) !void {
        _ = try g.world.decode(data);
        g.player = .{ .pos = pos, .yaw = yaw };
        g.boat = null;
        g.time_of_day = @mod(time, 1);
        g.day = day;
        g.target = null;
        g.unsaved = false;
        g.title = false;
        g.islands.current = null;
        g.closeMenu();
    }

    /// Whether there are changes to save here: only in this computer's
    /// own world (alone, or hosting, with the guests' changes too), not in
    /// a game joined (its host saves that).
    pub fn wantsSave(g: *const Game) bool {
        return g.unsaved and !g.title and g.net.status != .joined;
    }

    /// A change another player made.
    pub fn editFromNetwork(g: *Game, e: Edit) void {
        if (g.world.set(e.cell[0], e.cell[1], e.cell[2], e.block)) g.unsaved = true;
    }

    // The options, set from the menu (and only there: they have no keys).

    /// The quality, from the menu's slider (0: half as big across and
    /// down, 1: as big as the window), in steps of a twentieth.
    pub fn setQuality(g: *Game, slider: f32) void {
        const steps = 10;
        const k = @round(std.math.clamp(slider, 0, 1) * steps) / steps;
        g.quality = 0.5 + 0.5 * k;
    }

    /// The quality, as the menu's slider shows it.
    pub fn qualitySlider(g: *const Game) f32 {
        return (g.quality - 0.5) / 0.5;
    }

    /// A second's frames a second, for the menu's graph.
    pub fn noteFps(g: *Game, fps: f32) void {
        std.mem.copyForwards(f32, g.fps_history[0 .. fps_seconds - 1], g.fps_history[1..]);
        g.fps_history[fps_seconds - 1] = fps;
        g.fps_count = @min(g.fps_count + 1, fps_seconds);
    }

    pub fn playerName(g: *const Game) []const u8 {
        return g.name_buf[0..g.name_len];
    }

    /// A name typed (as much of it as fits, without what cannot be sent).
    pub fn setPlayerName(g: *Game, name: []const u8) void {
        var n: u8 = 0;
        for (name) |c| {
            if (n == max_name) break;
            if (c < 0x20) continue;
            g.name_buf[n] = c;
            n += 1;
        }
        // Not ending in the middle of a character.
        while (n > 0 and !std.unicode.utf8ValidateSlice(g.name_buf[0..n])) n -= 1;
        g.name_len = n;
    }

    pub fn setSkin(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Skin, i)) |v| g.look.skin = v;
    }

    pub fn setHeadwear(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Headwear, i)) |v| g.look.headwear = v;
    }

    pub fn setTop(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Top, i)) |v| g.look.top = v;
    }

    pub fn setTopColour(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Colour, i)) |v| g.look.top_colour = v;
    }

    pub fn setBottom(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Bottom, i)) |v| g.look.bottom = v;
    }

    pub fn setBottomColour(g: *Game, i: usize) void {
        if (std.enums.fromInt(avatar.Colour, i)) |v| g.look.bottom_colour = v;
    }

    /// Typing (the name, in the Player tab): keys go to it, but Esc and
    /// Tab.
    pub fn typing(g: *const Game) bool {
        return g.menu_open and g.menu_tab == .player;
    }

    pub fn showMenuTab(g: *Game, i: usize) void {
        if (i < std.enums.values(MenuTab).len) g.menu_tab = @enumFromInt(i);
        g.delete_asked = null;
    }

    pub fn showIslands(g: *Game) void {
        g.showMenuTab(@intFromEnum(MenuTab.islands));
    }

    /// An island asked to be deleted, not now.
    pub fn hideIslands(g: *Game) void {
        g.delete_asked = null;
    }

    pub fn newIsland(g: *Game) void {
        g.island_action = .new;
    }

    pub fn openIsland(g: *Game, i: u8) void {
        g.island_action = .{ .open = i };
    }

    /// Chooses an island in the menu (to join, or delete).
    pub fn selectIsland(g: *Game, i: u8) void {
        if (i < g.islands.count) g.islands.selected = i;
        g.delete_asked = null;
    }

    /// Plays on the island chosen.
    pub fn joinIsland(g: *Game) void {
        if (g.islands.selected) |i| g.openIsland(i);
    }

    /// Back to the title scene, to choose another island (from another's
    /// game: leaves it).
    pub fn leaveIsland(g: *Game) void {
        if (g.net.status == .joined or g.net.status == .asking) return g.leaveGame();
        g.island_action = .leave;
    }

    /// The title scene behind the menu (its world, the camera and the
    /// time of day loaded already: title.zig): still.
    pub fn showTitle(g: *Game) void {
        g.title = true;
        g.player.vel = .{ 0, 0, 0 };
        g.player.flying = false;
        g.boat = null;
        g.day = 0;
        g.target = null;
        g.unsaved = false;
        g.telescope = false;
        g.palette_open = false;
        g.islands.current = null;
        g.openMenu();
        g.showIslands();
    }

    /// Asks first: the second time, deletes.
    pub fn deleteIsland(g: *Game, i: u8) void {
        if (g.delete_asked == i) {
            g.island_action = .{ .delete = i };
            g.delete_asked = null;
        } else g.delete_asked = i;
    }

    pub fn keepIsland(g: *Game) void {
        g.delete_asked = null;
    }

    pub fn quit(g: *Game) void {
        g.quit_asked = true;
    }

    pub fn choose(g: *Game, slot: u8) void {
        g.slot = slot % 9;
        g.say(g.selected().name());
    }

    /// The wheel: the next slot (or the one before).
    pub fn scroll(g: *Game, dy: f32) void {
        const n: i32 = @intCast(g.hotbar.len);
        const step: i32 = if (dy > 0) 1 else -1;
        g.choose(@intCast(@mod(@as(i32, g.slot) + step, n)));
    }

    pub fn showPaletteSection(g: *Game, i: usize) void {
        if (i < blocks.sections.len) g.palette_section = i;
    }

    /// The next section of the palette (or the one before).
    pub fn paletteSection(g: *Game, dir: i32) void {
        const n: i32 = blocks.sections.len;
        g.palette_section = @intCast(@mod(@as(i32, @intCast(g.palette_section)) + dir, n));
    }

    /// From the palette: puts `b` in the hotbar's slot chosen (the palette
    /// stays open, its name shown in it).
    pub fn pickFromPalette(g: *Game, b: Block) void {
        g.hotbar[g.slot] = b;
    }

    /// The next block in the palette's section shown (or the one before),
    /// into the hotbar's slot chosen.
    pub fn paletteStep(g: *Game, dir: i32) void {
        const shown = blocks.sections[g.palette_section].blocks;
        const n: i32 = @intCast(shown.len);
        const at: ?usize = for (shown, 0..) |b, i| {
            if (b == g.selected()) break i;
        } else null;
        const next: i32 = if (at) |i| @mod(@as(i32, @intCast(i)) + dir, n) else if (dir > 0) 0 else n - 1;
        g.pickFromPalette(shown[@intCast(next)]);
    }

    /// A block dragged from the palette onto a slot of the hotbar: put
    /// there, and that slot chosen.
    pub fn dropOnSlot(g: *Game, slot: u8, b: Block) void {
        if (slot >= g.hotbar.len or !b.isValid() or b == .air) return;
        g.hotbar[slot] = b;
        g.slot = slot;
    }

    pub fn pointerAt(g: *Game, pos: ?[2]f32) void {
        g.pointer = pos;
        const p = pos orelse return;
        if (g.press) |*pr| {
            const dx = p[0] - pr.last[0];
            const dy = p[1] - pr.last[1];
            if (!pr.dragging and @abs(p[0] - pr.at[0]) + @abs(p[1] - pr.at[1]) > click_slop) pr.dragging = true;
            if (pr.dragging) g.player.look(dx * look_speed * g.lookScale(), -dy * look_speed * g.lookScale());
            pr.last = p;
        }
    }

    pub fn pointerDown(g: *Game, pos: [2]f32) void {
        // Behind the menu, the world is only looked at.
        if (g.menu_open) return;
        g.press = .{ .at = pos, .last = pos, .dragging = false };
        g.pointer = pos;
    }

    /// The press let go: a click (not a drag) takes the mouse, if it can
    /// be; otherwise builds.
    pub fn pointerUp(g: *Game) void {
        const pr = g.press orelse return;
        g.press = null;
        if (pr.dragging) return;
        if (g.can_capture and !g.captured) {
            g.capture_wanted = true;
            return;
        }
        g.updateTarget();
        _ = g.place();
    }

    /// The mouse moved by (`dx`, `dy`) pixels while taken: the view turns.
    pub fn mouseMoved(g: *Game, dx: f32, dy: f32) void {
        g.player.look(dx * look_speed * g.lookScale(), -dy * look_speed * g.lookScale());
    }

    /// A button pressed while the mouse is taken: on the block in the
    /// middle, the left builds, the right takes away, the middle picks.
    pub fn mouseButton(g: *Game, code: kete.PointerButton, pressed: bool) void {
        if (!pressed) return;
        g.updateTarget();
        switch (code) {
            // As Minecraft's: the left button takes away, the right
            // places.
            .left => _ = g.remove(),
            .right => _ = g.place(),
            .middle => g.pickAtPointer(),
            else => {},
        }
    }

    /// Right click, or a long press.
    pub fn removeAtPointer(g: *Game) void {
        if (g.menu_open) return;
        g.press = null;
        g.updateTarget();
        _ = g.remove();
    }

    /// Middle click: the block pointed at goes in the hotbar.
    pub fn pickAtPointer(g: *Game) void {
        if (g.menu_open) return;
        g.updateTarget();
        const t = g.target orelse return;
        const b = g.world.get(t.cell[0], t.cell[1], t.cell[2]);
        // Already to hand: just choose it.
        for (g.hotbar, 0..) |h, i| if (h == b) return g.choose(@intCast(i));
        g.hotbar[g.slot] = b;
        g.say(b.name());
    }

    // --- Building -----------------------------------------------------------------------

    /// Changes a block (the one way the world changes).
    pub fn edit(g: *Game, cell: world_mod.Pos, b: Block) bool {
        if (!g.world.set(cell[0], cell[1], cell[2], b)) return false;
        g.unsaved = true;
        if (g.net.sharing()) g.net.outbox.append(g.gpa, .{ .cell = cell, .block = b }) catch {};
        return true;
    }

    /// Puts the block chosen against the face pointed at.
    pub fn place(g: *Game) bool {
        const t = g.target orelse return false;
        if (g.boat == null and g.world.get(t.cell[0], t.cell[1], t.cell[2]) == .canoe) return g.board(t.cell);
        const b = g.selected();
        if (b.isSolid() and player_mod.blocksPlayer(&g.player, t.before)) return false;
        // Plants and paving stones need ground.
        if (b.onGround()) {
            const below = g.world.get(t.before[0], t.before[1] - 1, t.before[2]);
            if (!below.isOpaque()) return false;
        }
        const there = g.world.get(t.before[0], t.before[1], t.before[2]);
        if (there != .air and there != .water) return false;
        // Seagrass grows only under water.
        if (b == .seagrass and there != .water) return false;
        return g.edit(t.before, b);
    }

    /// Gets into the canoe at `cell`: takes it out of the world, to
    /// paddle.
    pub fn board(g: *Game, cell: world_mod.Pos) bool {
        const b = boat_mod.Boat.of(g.world, cell);
        const r = furniture.canoeRow(g.world, cell);
        var k: i32 = 0;
        while (k < r.len) : (k += 1) _ = g.edit(r.cell(k), .air);
        g.boat = b;
        g.player.flying = false;
        g.player.vel = .{ 0, 0, 0 };
        g.player.pos = b.seat();
        g.say("Shift to get out");
        return true;
    }

    /// Gets out of the canoe: puts it back as blocks, standing on it.
    pub fn leaveBoat(g: *Game) void {
        const b = g.boat orelse return;
        if (!b.canLeave(g.world)) {
            g.say("No room to leave the canoe here");
            return;
        }
        const r = b.row();
        var k: i32 = 0;
        while (k < r.len) : (k += 1) _ = g.edit(r.cell(k), .canoe);
        g.boat = null;
        g.player.vel = .{ 0, 0, 0 };
        g.player.pos = .{ b.pos[0], @as(f32, @floatFromInt(r.start[1])) + 0.51, b.pos[2] };
    }

    /// Takes away the block pointed at (and a plant on top of it).
    pub fn remove(g: *Game) bool {
        const t = g.target orelse return false;
        const c = t.cell;
        // Water beside it flows in, in time (see World.flow).
        if (!g.edit(c, .air)) return false;
        const above = g.world.get(c[0], c[1] + 1, c[2]);
        // What grew on it goes too (seagrass leaving its water).
        if (above.onGround()) _ = g.edit(.{ c[0], c[1] + 1, c[2] }, if (above == .seagrass) .water else .air);
        return true;
    }

    /// What the pointer is over (with the mouse taken, what is in the
    /// middle of the view).
    pub fn updateTarget(g: *Game) void {
        const middle: [2]f32 = .{ g.view_size[0] / 2, g.view_size[1] / 2 };
        const p = (if (g.captured) middle else g.pointer) orelse {
            g.target = null;
            return;
        };
        const cam = g.camera();
        const aspect = g.view_size[0] / @max(g.view_size[1], 1);
        const x = p[0] / @max(g.view_size[0], 1) * 2 - 1;
        const y = 1 - p[1] / @max(g.view_size[1], 1) * 2;
        g.target = player_mod.pick(g.world, cam.eye, cam.ray(aspect, x, y), reach);
    }

    // --- Time ------------------------------------------------------------------------------

    pub fn controls(g: *const Game) player_mod.Controls {
        const h = &g.held;
        const on = struct {
            fn f(set: *const std.EnumSet(kete.KeyboardKey), a: kete.KeyboardKey, b: kete.KeyboardKey) bool {
                return set.contains(a) or set.contains(b);
            }
        }.f;
        var c: player_mod.Controls = .{
            .up = h.contains(.space),
            .down = on(h, .left_shift, .right_shift),
            .sprint = g.sprinting or on(h, .left_ctrl, .right_ctrl),
        };
        if (on(h, .w, .up)) c.forward += 1;
        if (on(h, .s, .down)) c.forward -= 1;
        if (h.contains(.d)) c.strafe += 1;
        if (h.contains(.a)) c.strafe -= 1;
        return c;
    }

    /// Moves everything on by `dt` seconds.
    /// The game goes on behind the menu, but the keys held do not move the
    /// player there.
    pub fn tick(g: *Game, dt: f32) void {
        g.clock += dt;
        // The title scene: the view, and the time of day, stay as they
        // are (the creatures and clouds move on).
        if (g.title) return;
        const t = g.time_of_day + dt / day_length;
        if (t >= 1) g.day +%= 1;
        g.time_of_day = @mod(t, 1);
        // Water flows a block a step (one a frame at most).
        g.flow_wait += dt;
        if (g.flow_wait >= flow_step) {
            g.flow_wait = @min(g.flow_wait - flow_step, flow_step);
            if (g.world.flowing()) g.world.flow();
        }
        var turn: f32 = 0;
        if (!g.menu_open and !g.palette_open) {
            if (g.held.contains(.left)) turn -= 1;
            if (g.held.contains(.right)) turn += 1;
        }
        if (turn != 0) g.player.look(turn * turn_speed * dt * g.lookScale(), 0);
        const c: player_mod.Controls = if (g.menu_open) .{} else g.controls();
        if (g.boat) |*b| {
            b.update(g.world, c, dt);
            g.player.pos = b.seat();
            g.player.vel = .{ 0, 0, 0 };
        } else g.player.update(g.world, c, dt);
        g.updateTarget();
    }

    // --- Saving ---------------------------------------------------------------------------

    const magic = "DZBG";
    /// 2: the day, at the end. 3: then the canoe the player is in.
    const version = 3;

    /// The world, then the player and the hotbar.
    pub fn encode(g: *const Game, out: *std.ArrayList(u8)) !void {
        try g.world.encode(out, g.gpa);
        try out.appendSlice(g.gpa, magic);
        try out.append(g.gpa, version);
        const p = g.player;
        for ([_]f32{ p.pos[0], p.pos[1], p.pos[2], p.yaw, p.pitch, g.time_of_day }) |v| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(v), .little);
            try out.appendSlice(g.gpa, &b);
        }
        try out.append(g.gpa, @intFromBool(p.flying));
        for (g.hotbar) |b| try out.append(g.gpa, @intFromEnum(b));
        try out.append(g.gpa, g.slot);
        var d: [4]u8 = undefined;
        std.mem.writeInt(u32, &d, g.day, .little);
        try out.appendSlice(g.gpa, &d);
        // The canoe: its length (0: none), where and which way.
        const b = g.boat orelse return out.append(g.gpa, 0);
        try out.append(g.gpa, b.len);
        for ([_]f32{ b.pos[0], b.pos[1], b.pos[2], b.yaw }) |v| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(v), .little);
            try out.appendSlice(g.gpa, &bytes);
        }
    }

    /// The weather now (see weather.zig).
    pub fn weather(g: *const Game) weather_mod.Weather {
        // The title scene: fair, a few clouds.
        if (g.title) return .{ .clouds = 0.3 };
        return weather_mod.Weather.at(g.world.seed, g.day, g.time_of_day);
    }

    /// Reads what `encode` wrote.
    pub fn decode(g: *Game, data: []const u8) !void {
        const at = try g.world.decode(data);
        const rest = data[at..];
        if (rest.len < 5 + 6 * 4 + 1 + 9 + 1 or !std.mem.eql(u8, rest[0..4], magic) or rest[4] < 1 or rest[4] > version) return error.Corrupt;
        if (rest[4] >= 2 and rest.len < 44) return error.Corrupt;
        g.day = if (rest[4] >= 2) std.mem.readInt(u32, rest[40..44], .little) else 0;
        var f: [6]f32 = undefined;
        for (&f, 0..) |*v, i| v.* = @bitCast(std.mem.readInt(u32, rest[5 + i * 4 ..][0..4], .little));
        for (f) |v| if (!std.math.isFinite(v)) return error.Corrupt;
        g.player = .{ .pos = .{ f[0], f[1], f[2] }, .yaw = f[3], .pitch = std.math.clamp(f[4], -1.55, 1.55), .flying = rest[29] != 0 };
        g.time_of_day = @mod(f[5], 1);
        for (&g.hotbar, rest[30..39]) |*h, b| {
            const blk: Block = @enumFromInt(b);
            h.* = if (blk.isValid() and blk != .air) blk else .volcanic_rock;
        }
        g.slot = rest[39] % 9;
        g.boat = null;
        if (rest[4] >= 3 and rest.len >= 45 and rest[44] > 0) {
            if (rest.len < 45 + 16 or rest[44] > furniture.most_canoe) return error.Corrupt;
            var bf: [4]f32 = undefined;
            for (&bf, 0..) |*v, i| {
                v.* = @bitCast(std.mem.readInt(u32, rest[45 + i * 4 ..][0..4], .little));
                if (!std.math.isFinite(v.*)) return error.Corrupt;
            }
            var b: boat_mod.Boat = .{ .pos = .{ bf[0], bf[1], bf[2] }, .yaw = bf[3], .len = rest[44] };
            b.sink = if (b.onWater(g.world)) furniture.float_depth else 0;
            g.boat = b;
            g.player.pos = b.seat();
        }
        g.unsaved = false;
    }
};

/// The menu's tabs.
pub const MenuTab = enum(u2) { islands, player, play, settings };

/// The longest name a player can have (in bytes).
pub const max_name = 24;

/// How many seconds the menu's frame rate graph shows.
pub const fps_seconds = 30;

/// The islands kept, by name (their files' names, less ".blocks").
pub const Islands = struct {
    pub const max = 16;
    names: [max][48]u8 = undefined,
    lens: [max]u8 = @splat(0),
    count: u8 = 0,
    /// The one played now (none in the title scene, or another's game).
    current: ?u8 = null,
    /// The one chosen in the menu.
    selected: ?u8 = null,

    pub fn name(i: *const Islands, k: usize) []const u8 {
        return i.names[k][0..i.lens[k]];
    }

    pub fn add(i: *Islands, n: []const u8) void {
        if (i.count == max or n.len > 48) return;
        @memcpy(i.names[i.count][0..n.len], n);
        i.lens[i.count] = @intCast(n.len);
        i.count += 1;
    }
};

pub const IslandAction = union(enum) {
    new,
    open: u8,
    delete: u8,
    /// Back to the title scene.
    leave,
};

pub fn timeName(t: f32) []const u8 {
    return if (t < 0.2) "Night" else if (t < 0.3) "Dawn" else if (t < 0.45) "Morning" else if (t < 0.55) "Noon" else if (t < 0.7) "Afternoon" else if (t < 0.8) "Dusk" else "Night";
}

const testing = std.testing;

fn testGame() !Game {
    const w = try World.create(testing.allocator);
    errdefer w.destroy();
    for (0..world_mod.size_z) |z| for (0..world_mod.size_x) |x| {
        w.blocks[World.index(@intCast(x), 30, @intCast(z))] = .grass;
    };
    try w.computeLight();
    w.spawn = .{ 64.5, 31, 64.5 };
    var g = Game.init(testing.allocator, w);
    g.view_size = .{ 800, 600 };
    // Playing, not in the menu it starts in.
    g.menu_open = false;
    return g;
}

test "clicking places the block chosen on the face pointed at; right click takes it away" {
    var g = try testGame();
    defer g.world.destroy();
    // Looking down at the ground ahead.
    g.player.pitch = -0.8;
    g.pointerDown(.{ 400, 300 });
    g.pointerUp();
    const t = g.target.?;
    try testing.expectEqual(blocks.Face.up, t.face);
    try testing.expectEqual(Block.grass, g.world.get(t.before[0], t.before[1], t.before[2]));
    try testing.expect(g.unsaved);
    // Now pointing at the new block: take it away.
    g.removeAtPointer();
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
    // A drag looks around instead.
    const yaw = g.player.yaw;
    g.pointerDown(.{ 400, 300 });
    g.pointerAt(.{ 500, 300 });
    g.pointerUp();
    try testing.expect(g.player.yaw > yaw);
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
}

test "with the mouse taken, it turns the view and builds on the middle of it" {
    var g = try testGame();
    defer g.world.destroy();
    g.player.pitch = -0.8;
    // A click asks for the mouse, and builds nothing.
    g.can_capture = true;
    g.pointerDown(.{ 10, 10 });
    g.pointerUp();
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    try testing.expect(!g.unsaved);
    // Taken: the pointer's place no longer matters, the middle does.
    g.capture_wanted = null;
    g.captured = true;
    g.pointer = .{ 10, 10 };
    g.mouseButton(.right, true);
    const t = g.target.?;
    try testing.expectEqual(Block.grass, g.world.get(t.before[0], t.before[1], t.before[2]));
    g.mouseButton(.left, true);
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
    // Moving it turns the view; Esc gives it back (and opens the menu).
    const yaw = g.player.yaw;
    g.mouseMoved(100, 0);
    try testing.expect(g.player.yaw > yaw);
    g.key(.escape, true);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
}

test "T: the telescope, magnified and seeing further, turning slower" {
    var g = try testGame();
    defer g.world.destroy();
    g.captured = true;
    const usual = g.camera();
    const yaw = g.player.yaw;
    g.mouseMoved(100, 0);
    const turned = g.player.yaw - yaw;
    g.key(.t, true);
    g.key(.t, false);
    try testing.expect(g.telescope);
    const tele = g.camera();
    try testing.expectApproxEqAbs(@tan(usual.fov / 2) / telescope_zoom, @tan(tele.fov / 2), 0.0001);
    try testing.expectApproxEqAbs(usual.far * telescope_reach, tele.far, 0.001);
    try testing.expectEqual(telescope_reach, g.seeing());
    g.player.yaw = yaw;
    g.mouseMoved(100, 0);
    try testing.expectApproxEqAbs(turned / telescope_zoom, g.player.yaw - yaw, 0.0001);
    // Again: away.
    g.key(.t, true);
    try testing.expect(!g.telescope);
    try testing.expectEqual(@as(f32, 1), g.seeing());
}

test "no block inside the player; plants only on the ground" {
    var g = try testGame();
    defer g.world.destroy();
    g.target = .{ .cell = .{ 64, 30, 64 }, .before = .{ 64, 31, 64 }, .face = .up };
    try testing.expect(!g.place());
    g.target = .{ .cell = .{ 70, 30, 64 }, .before = .{ 70, 31, 64 }, .face = .up };
    g.hotbar[0] = .red_flower;
    try testing.expect(g.place());
    // Taking the ground away takes the flower too.
    try testing.expect(g.remove());
    try testing.expectEqual(Block.air, g.world.get(70, 31, 64));
    // A flower in the air: no.
    g.target = .{ .cell = .{ 70, 29, 64 }, .before = .{ 70, 30, 64 }, .face = .up };
    try testing.expect(!g.place());
}

test "keys: walking, choosing, flying, the palette" {
    var g = try testGame();
    defer g.world.destroy();
    const z = g.player.pos[2];
    g.key(.w, true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    g.key(.w, false);
    try testing.expect(g.player.pos[2] < z - 2);
    g.key(.digit_4, true);
    try testing.expectEqual(@as(u8, 3), g.slot);
    try testing.expectEqualStrings("Palm", g.messageShown().?);
    g.scroll(1);
    try testing.expectEqual(@as(u8, 4), g.slot);
    g.slot = 8;
    g.scroll(1);
    try testing.expectEqual(@as(u8, 0), g.slot);
    // Space twice, quickly, flies.
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(!g.player.flying);
    g.tick(0.1);
    g.key(.space, true);
    try testing.expect(g.player.flying);
    // Holding it (repeat presses) does not toggle it back off.
    g.key(.space, true);
    try testing.expect(g.player.flying);
    g.key(.space, false);
    // A third press soon after is the first of the next double tap.
    g.tick(0.1);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(g.player.flying);
    // Twice, but slowly: still flying.
    g.tick(0.5);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(g.player.flying);
    // Then twice quickly: walking again.
    g.tick(0.1);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(!g.player.flying);
    g.key(.e, true);
    g.key(.e, false);
    try testing.expect(g.palette_open);
    // Clicking a block chooses it, and the palette stays open.
    g.pickFromPalette(.thatch_slab);
    try testing.expect(g.palette_open);
    try testing.expectEqual(Block.thatch_slab, g.selected());
    // The arrows: the next block in the section shown, and back.
    g.showPaletteSection(blocks.sectionOf(.thatch_slab));
    const sec = blocks.sections[g.palette_section].blocks;
    const at = std.mem.indexOfScalar(Block, sec, .thatch_slab).?;
    g.key(.right, true);
    g.key(.right, false);
    try testing.expectEqual(sec[(at + 1) % sec.len], g.selected());
    g.key(.left, true);
    g.key(.left, false);
    try testing.expectEqual(Block.thatch_slab, g.selected());
    // Held, they do not turn the view.
    const yaw = g.player.yaw;
    g.key(.left, true);
    g.tick(0.2);
    g.key(.left, false);
    try testing.expectEqual(yaw, g.player.yaw);
    // Tab: the next section; Shift+Tab, back.
    const section = g.palette_section;
    g.key(.tab, true);
    g.key(.tab, false);
    try testing.expectEqual((section + 1) % blocks.sections.len, g.palette_section);
    g.key(.left_shift, true);
    g.key(.tab, true);
    g.key(.tab, false);
    g.key(.left_shift, false);
    try testing.expectEqual(section, g.palette_section);
    // Dragged onto another slot: put there, and it chosen.
    g.dropOnSlot(6, .bamboo);
    try testing.expectEqual(@as(u8, 6), g.slot);
    try testing.expectEqual(Block.bamboo, g.selected());
    // Enter closes it.
    g.key(.enter, true);
    g.key(.enter, false);
    try testing.expect(!g.palette_open);
    // A day goes by.
    const t = g.time_of_day;
    g.tick(day_length / 4);
    try testing.expectApproxEqAbs(@mod(t + 0.25, 1), g.time_of_day, 1e-3);
}

test "the game starts in the menu; leaving it takes the mouse, and Esc gives it back with the menu" {
    var g = try testGame();
    defer g.world.destroy();
    const fresh = Game.init(testing.allocator, g.world);
    try testing.expect(fresh.menu_open);
    g.can_capture = true;
    g.menu_open = true;
    // Esc on the menu: back to the game, which takes the mouse.
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(!g.menu_open);
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    // Esc in the game: the menu, and the mouse given back.
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(g.menu_open);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(false);
    // The game goes on (time passes), but keys do nothing: the player
    // stands still, and the palette stays shut.
    const t = g.time_of_day;
    const pos = g.player.pos;
    g.key(.w, true);
    g.key(.e, true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    try testing.expect(g.time_of_day != t);
    try testing.expectApproxEqAbs(pos[0], g.player.pos[0], 1e-4);
    try testing.expectApproxEqAbs(pos[2], g.player.pos[2], 1e-4);
    try testing.expect(!g.palette_open);
    // Resume: W still held walks again.
    g.closeMenu();
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    try testing.expect(g.player.pos[2] < pos[2] - 1);
    g.key(.w, false);
    g.key(.e, false);
    // The palette gives the mouse back to pick with; Esc closes it (not
    // opening the menu) and takes the mouse again.
    g.key(.e, true);
    g.key(.e, false);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(false);
    try testing.expect(g.palette_open and !g.menu_open);
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(!g.palette_open and !g.menu_open);
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    // The mouse taken away while playing (by the shell): the menu.
    g.pointerLocked(false);
    try testing.expect(g.menu_open);
}

test "the host saves, the guests' changes too; a game joined is not saved here" {
    var g = try testGame();
    defer g.world.destroy();
    defer g.deinit();
    g.net.status = .{ .hosting = 1 };
    g.editFromNetwork(.{ .cell = .{ 10, 31, 10 }, .block = .volcanic_wall });
    try testing.expect(g.wantsSave());
    g.unsaved = false;
    _ = g.edit(.{ 11, 31, 10 }, .lamp);
    try testing.expect(g.wantsSave());
    // Joined: changes, but not this computer's world to save.
    g.net.status = .{ .joined = "host-pi" };
    _ = g.edit(.{ 12, 31, 10 }, .thatch_slab);
    try testing.expect(g.unsaved and !g.wantsSave());
}

test "saving and loading keep the world, the player and the hotbar" {
    var g = try testGame();
    defer g.world.destroy();
    _ = g.edit(.{ 10, 31, 10 }, .lamp);
    g.player.pos = .{ 20.5, 31, 40.5 };
    g.player.yaw = 1.25;
    g.player.flying = true;
    g.hotbar[2] = .cyan;
    g.slot = 2;
    g.time_of_day = 0.8;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try g.encode(&out);
    var h = try testGame();
    defer h.world.destroy();
    try h.decode(out.items);
    try testing.expectEqual(Block.lamp, h.world.get(10, 31, 10));
    try testing.expectEqual(g.player.pos, h.player.pos);
    try testing.expectEqual(@as(f32, 1.25), h.player.yaw);
    try testing.expect(h.player.flying);
    try testing.expectEqual(Block.cyan, h.selected());
    try testing.expectEqual(@as(f32, 0.8), h.time_of_day);
    try testing.expectError(error.Corrupt, h.decode(out.items[0 .. out.items.len - 3]));
}

test "keys as Minecraft's: W twice sprints till let go, Shift goes down, F1 hides the hotbar" {
    var g = try testGame();
    defer g.world.destroy();
    g.closeMenu();
    g.key(.w, true);
    g.key(.w, false);
    g.tick(0.1);
    g.key(.w, true);
    try testing.expect(g.sprinting and g.controls().sprint);
    g.key(.w, false);
    try testing.expect(!g.sprinting and !g.controls().sprint);
    // Too slowly: not a sprint.
    g.key(.w, true);
    g.key(.w, false);
    g.tick(0.5);
    g.key(.w, true);
    try testing.expect(!g.sprinting);
    g.key(.w, false);
    g.key(.left_shift, true);
    try testing.expect(g.controls().down);
    g.key(.left_shift, false);
    g.key(.f1, true);
    try testing.expect(g.hud_hidden);
}

test "a canoe: right click gets in, W paddles, it is saved with the player, Shift gets out" {
    var g = try testGame();
    defer g.world.destroy();
    for ([_]i32{ 60, 61, 62 }) |x| _ = g.world.set(x, 31, 50, .canoe);
    g.target = .{ .cell = .{ 61, 31, 50 }, .before = .{ 61, 32, 50 }, .face = .up };
    try testing.expect(g.place());
    const b = g.boat.?;
    try testing.expectEqual(@as(u8, 3), b.len);
    for ([_]i32{ 60, 61, 62 }) |x| try testing.expectEqual(Block.air, g.world.get(x, 31, 50));
    // Along x; dragged over the grass, slowly, the player with it.
    g.key(.w, true);
    for (0..60) |_| g.tick(1.0 / 30.0);
    g.key(.w, false);
    const moved = g.boat.?.pos[0] - b.pos[0];
    try testing.expect(moved > 0.5 and moved < boat_mod.land_speed * 2 + 0.01);
    try testing.expectApproxEqAbs(g.boat.?.pos[0], g.player.pos[0], 0.001);
    // Saved and read back, still in it.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try g.encode(&out);
    g.boat = null;
    try g.decode(out.items);
    try testing.expectApproxEqAbs(g.boat.?.pos[0], b.pos[0] + moved, 0.001);
    // Out: the canoe put back, where it got to.
    for (0..30) |_| g.tick(1.0 / 30.0);
    g.key(.left_shift, true);
    g.key(.left_shift, false);
    try testing.expect(g.boat == null);
    var canoes: usize = 0;
    for (58..66) |x| {
        if (g.world.get(@intCast(x), 31, 50) == .canoe) canoes += 1;
    }
    try testing.expectEqual(@as(usize, 3), canoes);
    try testing.expect(g.player.pos[1] > 31.4);
}

test "behind the menu, the pointer neither turns the view nor builds nor takes the mouse" {
    var g = try testGame();
    defer g.world.destroy();
    defer g.deinit();
    g.can_capture = true;
    g.openMenu();
    const yaw = g.player.yaw;
    const pitch = g.player.pitch;
    g.pointerDown(.{ 400, 300 });
    g.pointerAt(.{ 600, 100 });
    g.pointerUp();
    g.removeAtPointer();
    g.pickAtPointer();
    try testing.expectEqual(yaw, g.player.yaw);
    try testing.expectEqual(pitch, g.player.pitch);
    try testing.expect(g.capture_wanted == null);
    try testing.expect(!g.unsaved);
}
