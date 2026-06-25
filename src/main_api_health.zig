const std = @import("std");
const config_mod = @import("core/config.zig");
const ai_provider = @import("api/random_provider_client.zig");
const main_http_transport = @import("main_http_transport.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);

    const args_cfg = try config_mod.Config.fromArgs(args_list.items);
    const cfg = try args_cfg.withLlmConfig(allocator, init.io);
    var http_transport = main_http_transport.StdHttpTransport.init(init.io);
    var client = ai_provider.RandomProviderClient.init(init.io, http_transport.client(), init.environ_map, cfg.conversation_models);

    var total: usize = 0;
    total += try client.checkTextRoutes(allocator, "conversation", cfg.conversation_models);
    if (cfg.psyche_models.len > 0) {
        total += try client.checkTextRoutes(allocator, "psyche", cfg.psyche_models);
    }

    if (total == 0) return error.NoApiHealthRoutesChecked;
    std.debug.print("API_HEALTH done checked={d}\n", .{total});
}
