const Symbol = @This();

const std = @import("std");
const macho = std.macho;
const mem = std.mem;

const Allocator = mem.Allocator;
const Dylib = @import("Dylib.zig");
const Object = @import("Object.zig");
const StringTable = @import("StringTable.zig");

pub const Type = enum {
    stab,
    regular,
    proxy,
    unresolved,
    tentative,
};

/// Symbol type.
@"type": Type,

/// Symbol name. Owned slice.
name: []const u8,

/// Alias of.
alias: ?*Symbol = null,

/// Index in GOT table for indirection.
got_index: ?u32 = null,

/// Index in stubs table for late binding.
stubs_index: ?u32 = null,

pub const Stab = struct {
    base: Symbol,

    // Symbol kind: function, etc.
    kind: Kind,

    // Size of stab.
    size: u64,

    // Base regular symbol for this stub if defined.
    symbol: ?*Symbol = null,

    // null means self-reference.
    file: ?*Object = null,

    pub const base_type: Symbol.Type = .stab;

    pub const Kind = enum {
        so,
        oso,
        function,
        global,
        static,
    };

    const Opts = struct {
        kind: Kind = .so,
        size: u64 = 0,
        symbol: ?*Symbol = null,
        file: ?*Object = null,
    };

    pub fn new(allocator: *Allocator, name: []const u8, opts: Opts) !*Symbol {
        const stab = try allocator.create(Stab);
        errdefer allocator.destroy(stab);

        stab.* = .{
            .base = .{
                .@"type" = .stab,
                .name = try allocator.dupe(u8, name),
            },
            .kind = opts.kind,
            .size = opts.size,
            .symbol = opts.symbol,
            .file = opts.file,
        };

        return &stab.base;
    }

    pub fn asNlists(stab: *Stab, allocator: *Allocator, strtab: *StringTable) ![]macho.nlist_64 {
        var out = std.ArrayList(macho.nlist_64).init(allocator);
        defer out.deinit();
        if (stab.kind == .so) {
            try out.append(.{
                .n_strx = try strtab.getOrPut(stab.base.name),
                .n_type = macho.N_SO,
                .n_sect = 0,
                .n_desc = 0,
                .n_value = 0,
            });
        } else if (stab.kind == .oso) {
            const mtime = mtime: {
                const object = stab.file orelse break :mtime 0;
                break :mtime object.mtime orelse 0;
            };
            try out.append(.{
                .n_strx = try strtab.getOrPut(stab.base.name),
                .n_type = macho.N_OSO,
                .n_sect = 0,
                .n_desc = 1,
                .n_value = mtime,
            });
        } else outer: {
            const symbol = stab.symbol orelse unreachable;
            const regular = symbol.getTopmostAlias().cast(Regular) orelse unreachable;
            const is_match = blk: {
                if (regular.file == null and stab.file == null) break :blk true;
                if (regular.file) |f1| {
                    if (stab.file) |f2| {
                        if (f1 == f2) break :blk true;
                    }
                }
                break :blk false;
            };
            if (!is_match) break :outer;

            switch (stab.kind) {
                .function => {
                    try out.ensureUnusedCapacity(4);
                    out.appendAssumeCapacity(.{
                        .n_strx = 0,
                        .n_type = macho.N_BNSYM,
                        .n_sect = regular.section,
                        .n_desc = 0,
                        .n_value = regular.address,
                    });
                    out.appendAssumeCapacity(.{
                        .n_strx = try strtab.getOrPut(stab.base.name),
                        .n_type = macho.N_FUN,
                        .n_sect = regular.section,
                        .n_desc = 0,
                        .n_value = regular.address,
                    });
                    out.appendAssumeCapacity(.{
                        .n_strx = 0,
                        .n_type = macho.N_FUN,
                        .n_sect = 0,
                        .n_desc = 0,
                        .n_value = stab.size,
                    });
                    out.appendAssumeCapacity(.{
                        .n_strx = 0,
                        .n_type = macho.N_ENSYM,
                        .n_sect = regular.section,
                        .n_desc = 0,
                        .n_value = stab.size,
                    });
                },
                .global => {
                    try out.append(.{
                        .n_strx = try strtab.getOrPut(stab.base.name),
                        .n_type = macho.N_GSYM,
                        .n_sect = 0,
                        .n_desc = 0,
                        .n_value = 0,
                    });
                },
                .static => {
                    try out.append(.{
                        .n_strx = try strtab.getOrPut(stab.base.name),
                        .n_type = macho.N_STSYM,
                        .n_sect = regular.section,
                        .n_desc = 0,
                        .n_value = regular.address,
                    });
                },
                .so, .oso => unreachable,
            }
        }

        return out.toOwnedSlice();
    }
};

pub const Regular = struct {
    base: Symbol,

    /// Linkage type.
    linkage: Linkage,

    /// Symbol address.
    address: u64,

    /// Section ID where the symbol resides.
    section: u8,

    /// Whether the symbol is a weak ref.
    weak_ref: bool = false,

    /// Object file where to locate this symbol.
    /// null means self-reference.
    file: ?*Object = null,

    /// True if symbol was already committed into the final
    /// symbol table.
    visited: bool = false,

    pub const base_type: Symbol.Type = .regular;

    pub const Linkage = enum {
        translation_unit,
        linkage_unit,
        global,
    };

    const Opts = struct {
        linkage: Linkage = .translation_unit,
        address: u64 = 0,
        section: u8 = 0,
        weak_ref: bool = false,
        file: ?*Object = null,
    };

    pub fn new(allocator: *Allocator, name: []const u8, opts: Opts) !*Symbol {
        const reg = try allocator.create(Regular);
        errdefer allocator.destroy(reg);

        reg.* = .{
            .base = .{
                .@"type" = .regular,
                .name = try allocator.dupe(u8, name),
            },
            .linkage = opts.linkage,
            .address = opts.address,
            .section = opts.section,
            .weak_ref = opts.weak_ref,
            .file = opts.file,
        };

        return &reg.base;
    }

    pub fn asNlist(regular: *Regular, strtab: *StringTable) !macho.nlist_64 {
        const n_strx = try strtab.getOrPut(regular.base.name);
        var nlist = macho.nlist_64{
            .n_strx = n_strx,
            .n_type = macho.N_SECT,
            .n_sect = regular.section,
            .n_desc = 0,
            .n_value = regular.address,
        };

        if (regular.linkage != .translation_unit) {
            nlist.n_type |= macho.N_EXT;
        }
        if (regular.linkage == .linkage_unit) {
            nlist.n_type |= macho.N_PEXT;
            nlist.n_desc |= macho.N_WEAK_DEF;
        }

        return nlist;
    }

    pub fn isTemp(regular: *Regular) bool {
        if (regular.linkage == .translation_unit) {
            return mem.startsWith(u8, regular.base.name, "l") or mem.startsWith(u8, regular.base.name, "L");
        }
        return false;
    }
};

pub const Proxy = struct {
    base: Symbol,

    /// Dynamic binding info - spots within the final
    /// executable where this proxy is referenced from.
    bind_info: std.ArrayListUnmanaged(struct {
        segment_id: u16,
        address: u64,
    }) = .{},

    /// Dylib where to locate this symbol.
    /// null means self-reference.
    file: ?*Dylib = null,

    pub const base_type: Symbol.Type = .proxy;

    const Opts = struct {
        file: ?*Dylib = null,
    };

    pub fn new(allocator: *Allocator, name: []const u8, opts: Opts) !*Symbol {
        const proxy = try allocator.create(Proxy);
        errdefer allocator.destroy(proxy);

        proxy.* = .{
            .base = .{
                .@"type" = .proxy,
                .name = try allocator.dupe(u8, name),
            },
            .file = opts.file,
        };

        return &proxy.base;
    }

    pub fn asNlist(proxy: *Proxy, strtab: *StringTable) !macho.nlist_64 {
        const n_strx = try strtab.getOrPut(proxy.base.name);
        return macho.nlist_64{
            .n_strx = n_strx,
            .n_type = macho.N_UNDF | macho.N_EXT,
            .n_sect = 0,
            .n_desc = (proxy.dylibOrdinal() * macho.N_SYMBOL_RESOLVER) | macho.REFERENCE_FLAG_UNDEFINED_NON_LAZY,
            .n_value = 0,
        };
    }

    pub fn deinit(proxy: *Proxy, allocator: *Allocator) void {
        proxy.bind_info.deinit(allocator);
    }

    pub fn dylibOrdinal(proxy: *Proxy) u16 {
        const dylib = proxy.file orelse return 0;
        return dylib.ordinal.?;
    }
};

pub const Unresolved = struct {
    base: Symbol,

    /// File where this symbol was referenced.
    /// null means synthetic, e.g., dyld_stub_binder.
    file: ?*Object = null,

    pub const base_type: Symbol.Type = .unresolved;

    const Opts = struct {
        file: ?*Object = null,
    };

    pub fn new(allocator: *Allocator, name: []const u8, opts: Opts) !*Symbol {
        const undef = try allocator.create(Unresolved);
        errdefer allocator.destroy(undef);

        undef.* = .{
            .base = .{
                .@"type" = .unresolved,
                .name = try allocator.dupe(u8, name),
            },
            .file = opts.file,
        };

        return &undef.base;
    }

    pub fn asNlist(undef: *Unresolved, strtab: *StringTable) !macho.nlist_64 {
        const n_strx = try strtab.getOrPut(undef.base.name);
        return macho.nlist_64{
            .n_strx = n_strx,
            .n_type = macho.N_UNDF,
            .n_sect = 0,
            .n_desc = 0,
            .n_value = 0,
        };
    }
};

pub const Tentative = struct {
    base: Symbol,

    /// Symbol size.
    size: u64,

    /// Symbol alignment as power of two.
    alignment: u16,

    /// File where this symbol was referenced.
    file: ?*Object = null,

    pub const base_type: Symbol.Type = .tentative;

    const Opts = struct {
        size: u64 = 0,
        alignment: u16 = 0,
        file: ?*Object = null,
    };

    pub fn new(allocator: *Allocator, name: []const u8, opts: Opts) !*Symbol {
        const tent = try allocator.create(Tentative);
        errdefer allocator.destroy(tent);

        tent.* = .{
            .base = .{
                .@"type" = .tentative,
                .name = try allocator.dupe(u8, name),
            },
            .size = opts.size,
            .alignment = opts.alignment,
            .file = opts.file,
        };

        return &tent.base;
    }

    pub fn asNlist(tent: *Tentative, strtab: *StringTable) !macho.nlist_64 {
        // TODO
        const n_strx = try strtab.getOrPut(tent.base.name);
        return macho.nlist_64{
            .n_strx = n_strx,
            .n_type = macho.N_UNDF,
            .n_sect = 0,
            .n_desc = 0,
            .n_value = 0,
        };
    }
};

pub fn deinit(base: *Symbol, allocator: *Allocator) void {
    allocator.free(base.name);

    switch (base.@"type") {
        .proxy => @fieldParentPtr(Proxy, "base", base).deinit(allocator),
        else => {},
    }
}

pub fn cast(base: *Symbol, comptime T: type) ?*T {
    if (base.@"type" != T.base_type) {
        return null;
    }
    return @fieldParentPtr(T, "base", base);
}

pub fn getTopmostAlias(base: *Symbol) *Symbol {
    if (base.alias) |alias| {
        return alias.getTopmostAlias();
    }
    return base;
}

pub fn isStab(sym: macho.nlist_64) bool {
    return (macho.N_STAB & sym.n_type) != 0;
}

pub fn isPext(sym: macho.nlist_64) bool {
    return (macho.N_PEXT & sym.n_type) != 0;
}

pub fn isExt(sym: macho.nlist_64) bool {
    return (macho.N_EXT & sym.n_type) != 0;
}

pub fn isSect(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_SECT;
}

pub fn isUndf(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_UNDF;
}

pub fn isIndr(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_INDR;
}

pub fn isAbs(sym: macho.nlist_64) bool {
    const type_ = macho.N_TYPE & sym.n_type;
    return type_ == macho.N_ABS;
}

pub fn isWeakDef(sym: macho.nlist_64) bool {
    return (sym.n_desc & macho.N_WEAK_DEF) != 0;
}

pub fn isWeakRef(sym: macho.nlist_64) bool {
    return (sym.n_desc & macho.N_WEAK_REF) != 0;
}
