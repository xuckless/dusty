//! Where the server's tasks run.
//!
//! On zio with several executors, `std.Io`'s `concurrent` places each new
//! task on the next executor round-robin, so a connection's helper tasks (the
//! HTTP/2 writer and stream tasks) would run on other OS threads than the
//! connection itself. With these, accept loops spread one per executor, and a
//! connection and everything it spawns stay on the executor that accepted it:
//! nothing of one connection crosses threads, and its locks are uncontended.
//!
//! Elsewhere -- dusty's zio stub, `std.Io.Threaded`, or zio's work-stealing
//! scheduling, where pinning a task is invalid -- this is plain `concurrent`.
const std = @import("std");
const zio = @import("zio");

const have_zio = !@hasDecl(zio, "is_stub");

pub const Where = union(enum) {
    /// The executor of the calling task.
    local,
    /// The executor with this index, modulo the executor count.
    executor: usize,
};

/// `group.concurrent(io, func, args)`, placed as `where` says when the `Io`
/// is zio's and placement applies.
pub fn concurrent(
    group: *std.Io.Group,
    io: std.Io,
    where: Where,
    func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) std.Io.ConcurrentError!void {
    if (comptime have_zio) {
        if (zio.Runtime.fromIo(io)) |rt| {
            const placement: zio.Placement = switch (where) {
                .local => .local,
                .executor => |i| .{ .executor = @intCast(i % rt.executors.items.len) },
            };
            if (zio.Group.fromStd(group).spawnInto(placement, func, args)) |_| {
                return;
            } else |err| switch (err) {
                // Work-stealing scheduling: tasks migrate, so let it pick.
                error.InvalidPlacement => {},
                else => return error.ConcurrencyUnavailable,
            }
        }
    }
    return group.concurrent(io, func, args);
}

/// How many executors accept loops can be spread over, or null when
/// placement does not apply (not zio).
pub fn executorCount(io: std.Io) ?usize {
    if (comptime !have_zio) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    return rt.executors.items.len;
}
