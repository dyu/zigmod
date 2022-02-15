const zfetch = @import("zfetch");

pub const commands_to_bootstrap = struct {
    pub const version = @import("./cmd/version.zig");
    pub const fetch = @import("./cmd/fetch.zig");
    pub const ci = @import("./cmd/ci.zig");
};

pub const commands_core = struct {
    pub const init = @import("./cmd/init.zig");
    pub const sum = @import("./cmd/sum.zig");
    pub const license = @import("./cmd/license.zig");
};

pub const commands = struct {
    usingnamespace commands_to_bootstrap;
    usingnamespace commands_core;
    pub const zpm = @import("./cmd/zpm.zig");
    pub const aq = @import("./cmd/aq.zig");
};

pub fn init() !void {
    try zfetch.init();
}

pub fn deinit() void {
    zfetch.deinit();
}

pub const DepType = @import("./util/dep_type.zig").DepType;
pub const Dep = @import("./util/dep.zig").Dep;
pub const ModFile = @import("./util/modfile.zig").ModFile;
pub const Module = @import("./util/module.zig").Module;

// util exports
pub const util = @import("./util/index.zig");
pub const common = @import("./common.zig");
