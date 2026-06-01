const std = @import("std");

const Io = std.Io;

pub const Instant = Io.Timestamp;

pub fn now(io: Io) Instant {
    return Io.Timestamp.now(io, .awake);
}

pub fn elapsedMicros(start: Instant, end: Instant) u64 {
    const micros = start.durationTo(end).toMicroseconds();
    return @intCast(micros);
}
