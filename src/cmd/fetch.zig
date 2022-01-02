const std = @import("std");
const string = []const u8;
const gpa = std.heap.c_allocator;

const zigmod = @import("../lib.zig");
const u = @import("./../util/index.zig");
const common = @import("./../common.zig");

const ansi = @import("ansi");

const root = @import("root");
const build_options = if (@hasDecl(root, "build_options")) root.build_options else struct {};
const bootstrap = if (@hasDecl(build_options, "bootstrap")) build_options.bootstrap else false;

//
//

pub fn execute(args: [][]u8) !void {
    //
    const cachepath = try std.fs.path.join(gpa, &.{ ".zigmod", "deps" });
    const dir = std.fs.cwd();
    const should_update = !(args.len >= 1 and std.mem.eql(u8, args[0], "--no-update"));

    var options = common.CollectOptions{
        .log = should_update,
        .update = should_update,
        .alloc = gpa,
    };
    const top_module = try common.collect_deps_deep(cachepath, dir, &options);

    var list = std.ArrayList(zigmod.Module).init(gpa);
    try common.collect_pkgs(top_module, &list);

    try create_depszig(cachepath, dir, top_module, &list);

    if (bootstrap) return;

    try create_lockfile(&list, cachepath, dir);

    try diff_lockfile();
}

pub fn create_depszig(cachepath: string, dir: std.fs.Dir, top_module: zigmod.Module, list: *std.ArrayList(zigmod.Module)) !void {
    var notdone = std.ArrayList(zigmod.Module).init(gpa);
    defer notdone.deinit();
    
    var done = std.ArrayList(zigmod.Module).init(gpa);
    defer done.deinit();
    
    var c_lib_modules = std.ArrayList(zigmod.Module).init(gpa);
    defer c_lib_modules.deinit();
    
    var c_lib_count: usize = 0;
    var link_lib_c_count: usize = 0;
    var vcpkg_count: usize = 0;
    for (list.items) |mod| {
        c_lib_count += mod.c_libs.len;
        link_lib_c_count += mod.c_include_dirs.len;
        link_lib_c_count += mod.c_source_files.len;
        if (mod.has_syslib_deps()) link_lib_c_count += 1;
        if (mod.has_vcpkg_deps()) {
            link_lib_c_count += 1;
            vcpkg_count += 1;
        }
        if (!mod.is_sys_lib) try notdone.append(mod);
    }
    link_lib_c_count += c_lib_count;
    
    const f = try dir.createFile("deps.zig", .{});
    defer f.close();

    const w = f.writer();
    try w.writeAll(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const Pkg = std.build.Pkg;
        \\const string = []const u8;
        \\
        \\pub const cache = ".zigmod/deps";
        \\
        \\pub fn addAllTo(
        \\    exe: *std.build.LibExeObjStep,
        \\    b: *std.build.Builder,
        \\    target: std.zig.CrossTarget,
        \\    mode: std.builtin.Mode,
        \\) *std.build.LibExeObjStep {
        \\    @setEvalBranchQuota(1_000_000);
        \\
        \\    exe.setTarget(target);
        \\    exe.setBuildMode(mode);
    );
    if (c_lib_count == 0) try w.writeAll(
        \\
        \\    _ = b;
    ) else try w.writeAll(
        \\
        \\
        \\    // lazy
        \\    if (c_libs[0] == null) resolveCLibs(b, target, mode);
        \\    for (c_libs) |c_lib| exe.linkLibrary(c_lib.?);
    );
    try w.writeAll(
        \\
        \\
        \\    for (packages) |pkg| {
        \\        exe.addPackage(pkg.pkg.?);
        \\    }
        \\    inline for (std.meta.declarations(package_data)) |decl| {
        \\        const pkg = @as(Package, @field(package_data, decl.name));
        \\        inline for (pkg.system_libs) |item| {
        \\            exe.linkSystemLibrary(item);
        \\        }
        \\        inline for (pkg.c_include_dirs) |item| {
        \\            exe.addIncludeDir(@field(dirs, decl.name) ++ "/" ++ item);
        \\        }
        \\        inline for (pkg.c_source_files) |item| {
        \\            exe.addCSourceFile(@field(dirs, decl.name) ++ "/" ++ item, pkg.c_source_flags);
        \\        }
        \\    }
    );
    if (link_lib_c_count != 0) try w.writeAll(
        \\
        \\
        \\    exe.linkLibC();
    );
    if (vcpkg_count != 0) try w.writeAll(
        \\
        \\
        \\    if (builtin.os.tag == .windows and target.getOsTag() == .windows) {
        \\        exe.addVcpkgPaths(.static) catch |err| @panic(@errorName(err));
        \\    }
    );
    try w.writeAll(
        \\
        \\
        \\    return exe;
        \\}
        \\
        \\pub const CLib = struct {
        \\    name: string,
        \\    idx: usize,
        \\    pub fn getStep(self: *CLib) ?*std.build.LibExeObjStep {
        \\        return c_libs[self.idx];
        \\    }
        \\};
        \\
        \\pub const Package = struct {
        \\    directory: string,
        \\    pkg: ?Pkg = null,
        \\    c_include_dirs: []const string = &.{},
        \\    c_libs: []const CLib = &.{},
        \\    c_source_files: []const string = &.{},
        \\    c_source_flags: []const string = &.{},
        \\    system_libs: []const string = &.{},
        \\    vcpkg: bool = false,
        \\};
        \\
        \\
    );
    try w.writeAll("pub const dirs = struct {\n");
    const no_deps_count = try print_dirs(w, list.items);
    try w.writeAll("};\n\n");
    
    if (c_lib_count != 0) try print_dep_dirs(w, list.items, no_deps_count);
    
    try w.writeAll("pub const package_data = struct {\n");
    try print_pkg_data_to(w, &notdone, &done, &c_lib_modules);
    try w.writeAll("};\n\n");

    try w.writeAll("pub const packages = ");
    const import_count = try print_deps(w, top_module);
    try w.writeAll(";\n\n");

    if (import_count != 0) try print_imports(w, top_module, cachepath);

    try w.writeAll("pub const pkgs = ");
    try print_pkgs(w, top_module);
    try w.writeAll(";\n\n");

    if (c_lib_count == 0) return;
    
    try w.writeAll(
        \\
        \\// lazy
        \\
    );
    try w.print(
        "var c_libs: [{}]?*std.build.LibExeObjStep = undefined;\n",
        .{ c_lib_modules.items.len },
    );
    try w.writeAll(
        \\
        \\fn resolveCLibs(
        \\    b: *std.build.Builder,
        \\    target: std.zig.CrossTarget,
        \\    mode: std.builtin.Mode,
        \\) void {
        \\
    );
    
    const path_escaped = std.zig.fmtEscapes(cachepath);
    var offset: usize = undefined;
    for (c_lib_modules.items) |mod, j| {
        offset =
            if (j == 0 or !std.mem.eql(u8, mod.id, c_lib_modules.items[j - 1].id))
                0
            else
                offset + 1;
        const c_lib = mod.c_libs[offset];
        const clean_path_escaped = std.zig.fmtEscapes(mod.clean_path);
        try w.print(
            "    c_libs[{}] = @import(\"{}/{}/{s}_lib.zig\").configure(\n",
            .{ j, path_escaped, clean_path_escaped, c_lib },
        );
        try w.print(
            "        dirs._{s},\n",
            .{ mod.id[0..12] },
        );
        try w.print(
            "        dep_dirs._{s},\n",
            .{ mod.id[0..12] },
        );
        try w.writeAll(
            "        b.allocator,\n"
        );
        try w.print(
            "        b.addStaticLibrary(\"{s}\", null),\n",
            .{ c_lib },
        );
        try w.writeAll(
            \\        target, mode,
            \\    );
            \\
        );
    }
    
    try w.writeAll("}\n\n");
}

fn create_lockfile(list: *std.ArrayList(zigmod.Module), path: string, dir: std.fs.Dir) !void {
    const fl = try dir.createFile("zigmod.lock", .{});
    defer fl.close();

    const wl = fl.writer();
    try wl.writeAll("2\n");
    for (list.items) |m| {
        if (m.dep) |md| {
            if (md.type == .local) {
                continue;
            }
            if (md.type == .system_lib) continue;
            const mpath = try std.fs.path.join(gpa, &.{ path, m.clean_path });
            const version = try md.exact_version(mpath);
            try wl.print("{s} {s} {s}\n", .{ @tagName(md.type), md.path, version });
        }
    }
}

const DiffChange = struct {
    from: string,
    to: string,
};

fn diff_lockfile() !void {
    const max = std.math.maxInt(usize);

    if (try u.does_folder_exist(".git")) {
        const result = try u.run_cmd_raw(gpa, null, &.{ "git", "diff", "zigmod.lock" });
        const r = std.io.fixedBufferStream(result.stdout).reader();
        while (try r.readUntilDelimiterOrEofAlloc(gpa, '\n', max)) |line| {
            if (std.mem.startsWith(u8, line, "@@")) break;
        }

        var rems = std.ArrayList(string).init(gpa);
        var adds = std.ArrayList(string).init(gpa);
        while (try r.readUntilDelimiterOrEofAlloc(gpa, '\n', max)) |line| {
            if (line[0] == ' ') continue;
            if (line[0] == '-') try rems.append(line[1..]);
            if (line[0] == '+') if (line[1] == '2') continue else try adds.append(line[1..]);
        }

        var changes = std.StringHashMap(DiffChange).init(gpa);

        var didbreak = false;
        var i: usize = 0;
        while (i < rems.items.len) {
            const it = rems.items[i];
            const sni = u.indexOfN(it, ' ', 2).?;

            var j: usize = 0;
            while (j < adds.items.len) {
                const jt = adds.items[j];
                const snj = u.indexOfN(jt, ' ', 2).?;

                if (std.mem.eql(u8, it[0..sni], jt[0..snj])) {
                    try changes.put(it[0..sni], .{
                        .from = it[u.indexOfAfter(it, '-', sni).? + 1 .. it.len],
                        .to = jt[u.indexOfAfter(jt, '-', snj).? + 1 .. jt.len],
                    });
                    _ = rems.orderedRemove(i);
                    _ = adds.orderedRemove(j);
                    didbreak = true;
                    break;
                }
                if (!didbreak) j += 1;
            }
            if (!didbreak) i += 1;
            if (didbreak) didbreak = false;
        }

        if (adds.items.len > 0) {
            std.debug.print(comptime ansi.color.Faint("Newly added packages:\n"), .{});
            defer std.debug.print("\n", .{});

            for (adds.items) |it| {
                std.debug.print("- {s}\n", .{it});
            }
        }

        if (rems.items.len > 0) {
            std.debug.print(comptime ansi.color.Faint("Removed packages:\n"), .{});
            defer std.debug.print("\n", .{});

            for (rems.items) |it| {
                std.debug.print("- {s}\n", .{it});
            }
        }

        if (changes.unmanaged.size > 0) std.debug.print(comptime ansi.color.Faint("Updated packages:\n"), .{});
        var iter = changes.iterator();
        while (iter.next()) |it| {
            if (diff_printchange("git https://github.com", "- {s}/compare/{s}...{s}\n", it)) continue;
            if (diff_printchange("git https://gitlab.com", "- {s}/-/compare/{s}...{s}\n", it)) continue;
            if (diff_printchange("git https://gitea.com", "- {s}/compare/{s}...{s}\n", it)) continue;

            std.debug.print("- {s}\n", .{it.key_ptr.*});
            std.debug.print("  - {s} ... {s}\n", .{ it.value_ptr.from, it.value_ptr.to });
        }
    }
}

fn diff_printchange(comptime testt: string, comptime replacement: string, item: std.StringHashMap(DiffChange).Entry) bool {
    if (std.mem.startsWith(u8, item.key_ptr.*, testt)) {
        std.debug.print(replacement, .{ item.key_ptr.*[4..], item.value_ptr.from, item.value_ptr.to });
        return true;
    }
    return false;
}

fn print_dirs(w: std.fs.File.Writer, list: []const zigmod.Module) !usize {
    var no_deps_count: usize = 0;
    for (list) |mod| {
        if (mod.is_sys_lib) continue;
        if (std.mem.eql(u8, mod.id, "root")) {
            try w.print("    pub const _root = \"\";\n", .{});
            continue;
        }
        try w.print("    pub const _{s} = cache ++ \"/{}\";\n", .{ mod.short_id(), std.zig.fmtEscapes(mod.clean_path) });
        if (mod.deps.len == 0) no_deps_count += 1;
    }
    return no_deps_count;
}

fn print_dep_dirs(
    w: std.fs.File.Writer,
    list: []const zigmod.Module,
    no_deps_count: usize,
) !void {
    if (no_deps_count != 0) try w.writeAll(
        "const zero_deps_map = std.ComptimeStringMap(string, .{ .{ \"\", \"\" } });\n\n",
    );
    try w.writeAll("pub const dep_dirs = struct {\n");
    for (list) |mod| {
        if (mod.is_sys_lib or std.mem.eql(u8, mod.id, "root")) continue;
        if (mod.deps.len == 0) {
            try w.print(
                "    pub const _{s} = zero_deps_map;\n",
                .{ mod.id[0..12] },
            );
            continue;
        }
        try w.print(
            "    pub const _{s} = std.ComptimeStringMap(string, .{{\n",
            .{ mod.id[0..12] },
        );
        for (mod.deps) |dep| {
            try w.print(
                "        .{{ \"{s}\", dirs._{s} }},\n",
                .{ dep.name, dep.id[0..12] },
            );
        }
        try w.writeAll("    });\n");
    }
    try w.writeAll("};\n\n");
}

fn print_deps(w: std.fs.File.Writer, m: zigmod.Module) !usize {
    var import_count: usize = 0;
    try w.writeAll("&[_]Package{\n");
    for (m.deps) |d| {
        if (d.main.len == 0) {
            continue;
        }
        if (d.for_build) {
            import_count += 1;
            continue;
        }
        try w.print("    package_data._{s},\n", .{d.id[0..12]});
    }
    try w.writeAll("}");
    return import_count;
}

fn print_pkg_data_to(
    w: std.fs.File.Writer,
    notdone: *std.ArrayList(zigmod.Module),
    done: *std.ArrayList(zigmod.Module),
    c_lib_modules: *std.ArrayList(zigmod.Module),
) !void {
    var len: usize = notdone.items.len;
    while (notdone.items.len > 0) {
        for (notdone.items) |mod, i| {
            if (contains_all(mod.deps, done.items)) {
                try w.print(
                    \\    pub const _{s} = Package{{
                    \\        .directory = dirs._{s},
                    \\
                , .{
                    mod.short_id(),
                    mod.short_id(),
                });
                if (mod.main.len > 0 and !std.mem.eql(u8, mod.id, "root")) {
                    try w.print(
                        \\        .pkg = Pkg{{ .name = "{s}", .path = .{{ .path = dirs._{s} ++ "/{s}" }}, .dependencies =
                    , .{
                        mod.name,
                        mod.short_id(),
                        mod.main,
                    });
                    if (mod.has_no_zig_deps()) {
                        try w.writeAll(" null },\n");
                    } else {
                        try w.writeAll(" &.{");
                        for (mod.deps) |moddep, j| {
                            if (moddep.main.len == 0) continue;
                            try w.print(" _{s}.pkg.?", .{moddep.id[0..12]});
                            if (j != mod.deps.len - 1) try w.writeAll(",");
                        }
                        try w.writeAll(" } },\n");
                    }
                }
                if (mod.c_include_dirs.len > 0) {
                    try w.writeAll("        .c_include_dirs = &.{");
                    for (mod.c_include_dirs) |item, j| {
                        try w.print(" \"{}\"", .{std.zig.fmtEscapes(item)});
                        if (j != mod.c_include_dirs.len - 1) try w.writeAll(",");
                    }
                    try w.writeAll(" },\n");
                }
                if (mod.c_libs.len > 0) {
                    try w.writeAll("        .c_libs = &.{\n");
                    for (mod.c_libs) |item| {
                        try w.writeAll("            .{ .name = ");
                        try w.print("\"{}\", .idx = {}", .{ std.zig.fmtEscapes(item), c_lib_modules.items.len });
                        try w.writeAll(" },\n");
                        try c_lib_modules.append(mod);
                    }
                    try w.writeAll("        },\n");
                }
                if (mod.c_source_files.len > 0) {
                    try w.writeAll("        .c_source_files = &.{");
                    for (mod.c_source_files) |item, j| {
                        try w.print(" \"{}\"", .{std.zig.fmtEscapes(item)});
                        if (j != mod.c_source_files.len - 1) try w.writeAll(",");
                    }
                    try w.writeAll(" },\n");
                }
                if (mod.c_source_flags.len > 0) {
                    try w.writeAll("        .c_source_flags = &.{");
                    for (mod.c_source_flags) |item, j| {
                        try w.print(" \"{}\"", .{std.zig.fmtEscapes(item)});
                        if (j != mod.c_source_flags.len - 1) try w.writeAll(",");
                    }
                    try w.writeAll(" },\n");
                }
                if (mod.has_syslib_deps()) {
                    try w.writeAll("        .system_libs = &.{");
                    for (mod.deps) |item, j| {
                        if (!item.is_sys_lib) continue;
                        try w.print(" \"{}\"", .{std.zig.fmtEscapes(item.name)});
                        if (j != mod.deps.len - 1) try w.writeAll(",");
                    }
                    try w.writeAll(" },\n");
                }
                if (mod.has_vcpkg_deps()) {
                    try w.writeAll("        .vcpkg = true,\n");
                }
                try w.writeAll("    };\n");

                try done.append(mod);
                _ = notdone.orderedRemove(i);
                break;
            }
        }
        if (notdone.items.len == len) {
            u.fail("notdone still has {d} items", .{len});
        }
        len = notdone.items.len;
    }
}

/// returns if all of the zig modules in needles are in haystack
fn contains_all(needles: []zigmod.Module, haystack: []const zigmod.Module) bool {
    for (needles) |item| {
        if (item.main.len > 0 and !u.list_contains_gen(zigmod.Module, haystack, item)) {
            return false;
        }
    }
    return true;
}

fn print_pkgs(w: std.fs.File.Writer, m: zigmod.Module) !void {
    try w.writeAll("struct {\n");
    for (m.deps) |d| {
        if (d.main.len == 0) {
            continue;
        }
        if (d.for_build) {
            continue;
        }
        const ident = try zig_name_from_pkg_name(d.name);
        try w.print("    pub const {s} = package_data._{s};\n", .{ ident, d.id[0..12] });
    }
    try w.writeAll("}");
}

fn print_imports(w: std.fs.File.Writer, m: zigmod.Module, path: string) !void {
    const path_escaped = std.zig.fmtEscapes(path);
    try w.writeAll("pub const imports = struct {\n");
    for (m.deps) |d| {
        if (d.main.len == 0 or !d.for_build) continue;
        
        const ident = try zig_name_from_pkg_name(d.name); 
        const clean_path_escaped = std.zig.fmtEscapes(d.clean_path);
        try w.print(
            "    pub const {s} = @import(\"{}/{}/{s}\");\n",
            .{ ident, path_escaped, clean_path_escaped, d.main }
        );
    }
    try w.writeAll("};\n\n");
}

fn zig_name_from_pkg_name(name: string) !string {
    var legal = name;
    legal = try std.mem.replaceOwned(u8, gpa, legal, "-", "_");
    legal = try std.mem.replaceOwned(u8, gpa, legal, "/", "_");
    legal = try std.mem.replaceOwned(u8, gpa, legal, ".", "_");
    return legal;
}
