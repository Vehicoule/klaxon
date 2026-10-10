// ios_io.zig — std.Io minimal pour la cible iOS (Phase 3e, fix compile).
//
// Bug Zig 0.17: std.debug.print / @panic passent par std.Options.debug_io,
// qui vaut par défaut std.Io.Threaded.global_single_threaded.io(). Le chemin
// spawn Darwin de Threaded lit NullFile.fd (std/Io/Threaded.zig:15486) —
// NullFile est un struct VIDE sur .ios/.tvos/.watchos (pas de champ fd), donc
// toute référence atteignable à std.debug.print / @panic (37 sites dans 10
// fichiers) casse la compile aarch64-ios.
//
// Fix: la racine du graphe iOS (main_ios.zig) déclare
//   pub const std_options_debug_io: std.Io = ios_io.io;
// std.zig (pub const debug_io) consulte cette déclaration à la racine et ne
// référence alors plus Threaded — le bug std n'est plus analysé. Les builds
// natifs n'ont pas la déclaration: ils gardent le Threaded par défaut.
//
// Cette Io n'utilise ni thread ni descripteur: les écritures stderr
// (std.debug.print, messages et stack traces de @panic, std.log) sont routées
// vers SDL_Log (stderr / OSLog — visible dans la console Xcode). Tout le reste
// est un stub std "failing*" (erreur) ou un no-op: le debug_io n'est jamais
// utilisé pour du vrai I/O applicatif.
//
// Contrat stderr calqué sur std.Io.Threaded: lockStderr retourne un
// LockedStderr adossé à un File.Writer statique; unlockStderr FLUSH le writer
// (c'est lui qui pousse la queue de Writer.print — print ne flush pas de
// lui-même) puis remet end=0 / buffer vide. Sans ce flush, la queue d'un print
// resterait dans le buffer stack de l'appelant (use-after-return au lock
// suivant).
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Terminal = Io.Terminal;

comptime {
    if (builtin.os.tag != .ios and !(builtin.os.tag == .linux and builtin.abi == .android))
        @compileError("ios_io.zig is mobile-only (aarch64-ios / aarch64-linux-android)");
}

/// Instance unique. userdata = null: l'état (writer stderr, protection
/// d'annulation, PRNG) est en globales — le code Zig de l'app iOS est
/// single-threaded (callbacks SDL sur le main thread). Pas de mutex stderr.
pub const io: Io = .{ .userdata = null, .vtable = &vtable };

// --- stderr → SDL_Log ------------------------------------------------------

/// File.Writer statique derrière LockedStderr. Le champ `file` est un dummy
/// (fd -1): il n'est jamais déréférencé — le drain n'utilise que l'interface
/// Io.Writer, jamais file/io.
var stderr_file_writer: File.Writer = .{
    .io = io,
    .file = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    .interface = .{ .vtable = &writer_vtable, .buffer = &.{} },
};

const writer_vtable: Io.Writer.VTable = .{ .drain = drain };

/// drain (contrat std.Io.Writer.VTable.drain): consomme d'abord le buffer
/// interne w.buffer[0..w.end], puis chaque slice de `data` — le dernier
/// répété `splat` fois au total (countSplat: sum(others) + last.len * splat).
/// Retourne les octets de `data` consommés (hors buffer). On consomme toujours
/// tout et on ne renvoie jamais error.WriteFailed (un log perdu vaut mieux
/// qu'un panic dans le panic handler).
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    if (w.end > 0) {
        sdlLog(w.buffer[0..w.end]);
        w.end = 0;
    }
    var consumed: usize = 0;
    for (data, 0..) |slice, i| {
        const times: usize = if (i + 1 == data.len) splat else 1;
        for (0..times) |_| {
            sdlLog(slice);
            consumed += slice.len;
        }
    }
    return consumed;
}

/// Un morceau de log vers SDL_Log, découpé sur une pile de 1 KiB. SDL_Log est
/// varargs: le message passe en ARGUMENT de "%s" (les '%' du message sont
/// sûrs — ce n'est pas le format), comme host.zig log().
fn sdlLog(bytes: []const u8) void {
    if (bytes.len == 0) return;
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < bytes.len) {
        const chunk = bytes[i..@min(i + buf.len - 1, bytes.len)];
        @memcpy(buf[0..chunk.len], chunk);
        buf[chunk.len] = 0;
        sdl.c.SDL_Log("%s", buf[0..chunk.len :0].ptr);
        i += chunk.len;
    }
}

// --- lock stderr (chemin std.debug.print / @panic / std.log) ---------------

fn lockStderr(userdata: ?*anyopaque, terminal_mode: ?Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    _ = userdata;
    _ = terminal_mode; // pas de détection tty: toujours .no_color (OSLog sans couleurs)
    return .{ .file_writer = &stderr_file_writer, .terminal_mode = .no_color };
}

fn tryLockStderr(userdata: ?*anyopaque, terminal_mode: ?Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    return try lockStderr(userdata, terminal_mode);
}

fn unlockStderr(userdata: ?*anyopaque) void {
    _ = userdata;
    // Même contrat que Threaded.unlockStderr: flush de la queue (pousse la
    // fin du dernier print), puis reset — sinon le prochain lockStderr
    // drainerait l'ancien buffer stack de l'appelant (use-after-return).
    stderr_file_writer.interface.flush() catch {};
    stderr_file_writer.interface.end = 0;
    stderr_file_writer.interface.buffer = &.{};
}

// --- crash / annulation / futex --------------------------------------------

fn noCrashHandler(userdata: ?*anyopaque) void {
    _ = userdata; // pas de handler SIGSEGV: le panic imprime via SDL_Log puis abort()
}

var cancel_protection: u1 = @intFromEnum(Io.CancelProtection.unblocked);

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    const old: u1 = @atomicRmw(u1, &cancel_protection, .Xchg, @intFromEnum(new), .seq_cst);
    return @enumFromInt(old);
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata; // aucune requête d'annulation n'existe sur ce Io
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    _ = ptr;
    _ = expected;
    _ = timeout; // réveil immédiat (spurious wakeup autorisé par le contrat)
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    _ = ptr;
    _ = expected;
    // Chemin "attendre la fin d'un autre panic" (std/debug.zig): parked sans
    // brûler le CPU. Inatteignable en single-threaded.
    while (true) sdl.c.SDL_Delay(60_000);
}

// --- concurrence (jamais utilisée sur debug_io) -----------------------------

fn noAwait(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
}

fn noCancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
}

fn noGroupAsync(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) void) void {
    _ = userdata;
    _ = group;
    _ = context;
    _ = context_alignment;
    _ = start;
}

fn noGroupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    _ = userdata;
    _ = group;
    _ = token;
}

fn noGroupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = token;
}

fn noRecancel(userdata: ?*anyopaque) void {
    _ = userdata;
}

fn failingBatchAwaitAsync(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
    _ = userdata;
    _ = b;
    return error.Canceled;
}

fn failingBatchAwaitConcurrent(userdata: ?*anyopaque, b: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    _ = userdata;
    _ = b;
    _ = timeout;
    return error.ConcurrencyUnavailable;
}

fn noBatchCancel(userdata: ?*anyopaque, b: *Io.Batch) void {
    _ = userdata;
    _ = b;
}

// --- fichiers / dossiers ----------------------------------------------------
// std.Io fournit les helpers failing*/unreachable* pour la quasi-totalité des
// champs — on n'implémente que les 5 champs sans helper std, plus les champs
// tty/ANSI (atteignables en théorie par une détection de terminal).

fn noDirClose(userdata: ?*anyopaque, dirs: []const Dir) void {
    _ = userdata;
    _ = dirs;
}

fn noFileClose(userdata: ?*anyopaque, files: []const File) void {
    _ = userdata;
    _ = files;
}

fn failingDirRead(userdata: ?*anyopaque, reader: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize {
    _ = userdata;
    _ = reader;
    _ = entries;
    return error.SystemResources;
}

fn failingDirSetTimestamps(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.AccessDenied;
}

fn failingFileSetTimestamps(userdata: ?*anyopaque, file: File, options: File.SetTimestampsOptions) File.SetTimestampsError!void {
    _ = userdata;
    _ = file;
    _ = options;
    return error.AccessDenied;
}

fn fileIsTty(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    _ = userdata;
    _ = file;
    return false; // stderr émulé par SDL_Log: jamais un tty
}

fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: File) File.EnableAnsiEscapeCodesError!void {
    _ = userdata;
    _ = file;
}

fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    _ = userdata;
    _ = file;
    return false;
}

fn failingFileWriteFileStreaming(userdata: ?*anyopaque, file: File, header: []const u8, file_reader: *File.Reader, limit: Io.Limit) File.Writer.WriteFileError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = file_reader;
    _ = limit;
    return error.InputOutput;
}

fn failingFileWriteFilePositional(userdata: ?*anyopaque, file: File, header: []const u8, file_reader: *File.Reader, limit: Io.Limit, offset: u64) File.WritePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = file_reader;
    _ = limit;
    _ = offset;
    return error.InputOutput;
}

// --- horloges / sommeil / hasard -------------------------------------------

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;
    // Darwin: UPTIME_RAW (.awake) / MONOTONIC_RAW (.boot). Android/Linux:
    // MONOTONIC for both (UPTIME_RAW / MONOTONIC_RAW are Darwin-only).
    const clock_id: std.posix.clockid_t = switch (clock) {
        .real => std.posix.CLOCK.REALTIME,
        .awake => if (builtin.os.tag == .ios) std.posix.CLOCK.UPTIME_RAW else std.posix.CLOCK.MONOTONIC,
        .boot => if (builtin.os.tag == .ios) std.posix.CLOCK.MONOTONIC_RAW else std.posix.CLOCK.MONOTONIC,
        .cpu_process => std.posix.CLOCK.PROCESS_CPUTIME_ID,
        .cpu_thread => std.posix.CLOCK.THREAD_CPUTIME_ID,
    };
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(clock_id, &ts))) {
        .SUCCESS => return .{ .nanoseconds = @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec) },
        else => return .zero,
    }
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    if (timeout == .none) {
        // "Dormir pour toujours": SDL_Delay en boucle (jamais atteint sur le
        // chemin debug_io).
        while (true) sdl.c.SDL_Delay(60_000);
    }
    const ns: i96 = switch (timeout) {
        .none => unreachable,
        .duration => |d| d.raw.nanoseconds,
        .deadline => |d| d.raw.nanoseconds - now(null, d.clock).nanoseconds,
    };
    if (ns <= 0) return;
    const ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));
    sdl.c.SDL_Delay(@intCast(@min(ms, std.math.maxInt(u32))));
}

/// xorshift64* — le debug_io n'est pas une source d'aléa applicative (rien
/// dans std ne lit debug_io.random); un PRNG déterministe suffit.
var rng_state: u64 = 1;

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    if (rng_state == 1) {
        // amorçage paresseux (ms depuis SDL_Init — SDL_GetTicks, pas
        // SDL_GetTicks64: renommé en SDL_GetTicks dans SDL3)
        rng_state = sdl.c.SDL_GetTicks() ^ 0x9E3779B97F4A7C15;
        if (rng_state == 0) rng_state = 0x853C49E6748FEA9B;
    }
    for (buffer) |*b| {
        rng_state ^= rng_state >> 12;
        rng_state ^= rng_state << 25;
        rng_state ^= rng_state >> 27;
        b.* = @truncate(rng_state *% 0x2545F4914F6CDD1D);
    }
}

// --- vtable ----------------------------------------------------------------

const vtable: Io.VTable = .{
    .crashHandler = noCrashHandler,
    .async = Io.noAsync, // exécution eager, future null
    .concurrent = Io.failingConcurrent,
    .await = noAwait, // jamais appelé: noAsync retourne null
    .cancel = noCancel,
    .groupAsync = noGroupAsync,
    .groupConcurrent = Io.failingGroupConcurrent,
    .groupAwait = noGroupAwait,
    .groupCancel = noGroupCancel,
    .recancel = noRecancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,
    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = Io.noFutexWake,
    .operate = Io.failingOperate,
    .batchAwaitAsync = failingBatchAwaitAsync,
    .batchAwaitConcurrent = failingBatchAwaitConcurrent,
    .batchCancel = noBatchCancel,

    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = Io.failingDirStatFile,
    .dirAccess = Io.failingDirAccess,
    .dirCreateFile = Io.failingDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = Io.failingDirOpenFile,
    .dirClose = noDirClose,
    .dirRead = failingDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = Io.failingDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = Io.failingDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = failingDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    .fileStat = Io.failingFileStat,
    .fileLength = Io.failingFileLength,
    .fileClose = noFileClose,
    .fileWritePositional = Io.failingFileWritePositional,
    .fileWriteFileStreaming = failingFileWriteFileStreaming,
    .fileWriteFilePositional = failingFileWriteFilePositional,
    .fileReadPositional = Io.failingFileReadPositional,
    .fileSeekBy = Io.failingFileSeekBy,
    .fileSeekTo = Io.failingFileSeekTo,
    .fileSync = Io.failingFileSync,
    .fileIsTty = fileIsTty,
    .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes,
    .fileSetLength = Io.failingFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = failingFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = Io.failingFileRealPath,
    .fileHardLink = Io.failingFileHardLink,
    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = lockStderr,
    .tryLockStderr = tryLockStderr,
    .unlockStderr = unlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processSpawn = Io.failingProcessSpawn,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,

    .progressParentFile = Io.failingProgressParentFile,
    .inheritParentDir = Io.failingInheritParentDir,
    .inheritParentFile = Io.failingInheritParentFile,

    .now = now,
    .clockResolution = Io.failingClockResolution,
    .sleep = sleep,

    .random = random,
    .randomSecure = Io.failingRandomSecure,

    .netListenIp = Io.failingNetListenIp,
    .netAccept = Io.failingNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = Io.failingNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = Io.unreachableNetClose,
    .netShutdown = Io.failingNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};
