//! Where the server's tasks run.
//!
//! On zio with several executors, `std.Io`'s `concurrent` places each new
//! task on the next executor round-robin, so a connection's helper tasks (the
//! HTTP/2 writer and stream tasks) would run on other OS threads than the
//! connection itself. With these, accept loops spread one per executor, and a
//! connection and everything it spawns stay on the executor that accepted it:
//! nothing of one connection crosses threads, and its locks are uncontended.
//!
//! Elsewhere -- dusty's zio stub, a zio without placement, `std.Io.Threaded`,
//! or zio's work-stealing scheduling, where pinning a task is invalid -- this
//! is plain `concurrent`.
//!
//! It also lets one task cancel another single task of a group (`Task`),
//! which `std.Io` has no call for: groups are canceled as a whole.
const std = @import("std");
const zio = @import("zio");

/// A zio with the placement API (it arrived after 0.18).
const have_zio = !@hasDecl(zio, "is_stub") and @hasDecl(zio, "Placement") and
    @hasDecl(zio, "Runtime") and @hasDecl(zio.Runtime, "fromIo") and
    @hasDecl(zio, "Group") and @hasDecl(zio.Group, "spawnInto");

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
    // Spawning is not a cancelation point, yet under std.Io.Threaded it can
    // swallow a cancel: a Debug allocator captures a stack trace for the new
    // task, and Zig 0.17's unwinder takes a cancelable lock
    // (`std.debug.SelfInfo`'s module mutex, through `std.Options.debug_io`).
    // Threaded keeps cancel state per OS thread, whichever instance asks, so
    // when that lock is contended it acknowledges the cancel pending on the
    // spawning task and the unwinder drops the error. Every later syscall of
    // that task then runs uncancelable, and its next blocking wait (an
    // accept, an event) blocks the shutdown for good. Blocked here, the
    // cancel stays pending for that wait.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return group.concurrent(io, func, args);
}

/// How many executors accept loops can be spread over, or null when
/// placement does not apply (not zio).
/// The index of the executor the calling task runs on, the one `.executor`
/// takes: for work started elsewhere (a drain, say) that belongs on a
/// connection's executor. Null off zio, or off an executor of `io`'s runtime.
pub fn currentExecutor(io: std.Io) ?usize {
    if (comptime !have_zio or !@hasDecl(zio.Runtime, "currentExecutor")) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    return rt.currentExecutor() orelse null;
}

pub fn executorCount(io: std.Io) ?usize {
    if (comptime !have_zio) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    return rt.executors.items.len;
}

/// zio can cancel one task: the type behind the task an `AutoCancel` arms
/// against has a non-blocking `cancel`.
const have_task_cancel = !@hasDecl(zio, "is_stub") and @hasDecl(zio, "Runtime") and
    @hasDecl(zio.Runtime, "fromIo") and @hasDecl(zio, "AutoCancel") and
    @hasField(zio.AutoCancel, "task") and
    @hasDecl(@typeInfo(@typeInfo(@FieldType(zio.AutoCancel, "task")).optional.child).pointer.child, "cancel");

/// A running task that another task can cancel by itself, without its
/// group. Void where that is not possible (not zio): `currentTask` returns
/// null.
pub const Task = if (have_task_cancel) @typeInfo(@FieldType(zio.AutoCancel, "task")).optional.child else void;

/// The calling task, or null when it cannot be canceled alone. The handle
/// is valid while the task runs: whoever cancels it must know it has not
/// returned yet (in practice, under a lock the task takes before it ends).
pub fn currentTask(io: std.Io) ?Task {
    if (comptime !have_task_cancel) return null;
    if (zio.Runtime.fromIo(io) == null) return null;
    if (comptime @hasDecl(zio, "currentTask")) return zio.currentTask();
    // An older zio has no public "current task", but an armed `AutoCancel` records
    // the task it will cancel. Armed far out and cleared at once: the timer
    // never fires.
    var probe: zio.AutoCancel = .init;
    probe.set(.fromSeconds(365 * 24 * 3600));
    defer probe.clear();
    return probe.task;
}

/// Asks `task` to stop: its next cancelable wait (or the one it is in)
/// returns `error.Canceled`. Does not wait for it; safe from any thread.
pub fn cancelTask(task: Task) void {
    if (comptime have_task_cancel) task.cancel();
}
