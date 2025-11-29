# openxr-zig

OpenXR bindings for Zig, generated from the official XML registry.

**Goal:** Take `xr.xml` → produce `xr.zig` → give you a clean, type-safe OpenXR API that feels like Zig, not C.

---

## 1. What this library is

- **OpenXR** is the standard API for VR/AR (“XR”) runtimes.
- `openxr-zig`:
  - Reads the official `xr.xml` registry from Khronos.
  - Generates a Zig source file `xr.zig`.
  - Exposes OpenXR via idiomatic Zig types, errors, and wrappers.

You do **not** edit the generated file. Regenerate it when you change `xr.xml` or update this tool.

The generator design is heavily inspired by Snektron’s [`vulkan-zig`](https://github.com/Snektron/vulkan-zig).

---

## 2. Quick start (one-off generation)

This is the simplest path, even if you’re new to Zig.

### Step 1: Get `xr.xml`

From the OpenXR SDK or the Khronos repo (for example, `OpenXR-Docs/xml/xr.xml`).  
Place it in your project:

```text
deps/openxr/xr.xml
```

### Step 2: Build the generator

Clone this repo and build:

```bash
zig build
```

This produces:

```text
zig-out/bin/openxr-zig-generator
```

### Step 3: Generate `xr.zig`

From your project root:

```bash
/path/to/openxr-zig/zig-out/bin/openxr-zig-generator     deps/openxr/xr.xml     src/xr.zig
```

Now you have `src/xr.zig` with all generated types and functions.

### Step 4: Use it in your Zig code

`src/main.zig`:

```zig
const std = @import("std");
const xr = @import("xr"); // generated file

pub fn main() !void {
    std.debug.print("OpenXR spec version: {d}.{d}.{d}
", .{
        xr.MAJOR_VERSION,
        xr.MINOR_VERSION,
        xr.PATCH_VERSION,
    });
}
```

Build and run:

```bash
zig build run
```

At this point you have OpenXR bindings in Zig. From here, you follow the usual OpenXR flow (instance, system, session, etc.), but using Zig types instead of raw C.

---

## 3. Using as a Zig dependency (build-time generation)

If you want `xr.zig` generated automatically during `zig build`:

### 3.1 `build.zig.zon`

```zig
.{
    .name = "my-xr-app",
    .version = "0.0.1",
    .dependencies = .{
        .openxr_zig = .{
            .url = "https://github.com/zigadel/openxr-zig/archive/refs/heads/main.tar.gz",
            .hash = "TODO: fill after `zig fetch`",
        },
    },
}
```

### 3.2 `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-xr-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tell openxr-zig where your registry XML is.
    const xr_dep = b.dependency("openxr_zig", .{
        .registry = "deps/openxr/xr.xml",
    });

    const xr_mod = xr_dep.module("openxr-zig");
    exe.root_module.addImport("xr", xr_mod);

    b.installArtifact(exe);
}
```

Then in your code:

```zig
const xr = @import("xr");
```

You don’t call the generator yourself; `zig build` wires it into the build graph.

---

## 4. API shape

The generator reshapes the raw C API into something Zig-friendly.

### 4.1 Naming

- Types:
  - `XrInstanceCreateInfo` → `InstanceCreateInfo`
  - `XrSwapchainKHR` → `SwapchainKHR` (author/tag suffixes like `KHR` are preserved)
- Functions:
  - `xrCreateInstance` → `createInstance` (wrapper)
  - `xrCreateInstance` function pointer → `PfnCreateInstance`
- Enum / flag values:
  - `XR_ACTION_TYPE_BOOLEAN_INPUT` → `boolean_input`
  - `XR_ANDROID_THREAD_TYPE_APPLICATION_MAIN_KHR` → `application_main_khr`
  - `XR_ENVIRONMENT_BLEND_MODE_OPAQUE` → `@"opaque"` (escaped identifier)
- Struct fields / parameters:
  - `viewConfigurationType` → `view_configuration_type`

All of this follows Zig’s standard style (snake_case, lower-case enums, `@"..."` escapes).

### 4.2 Errors and return values

C-style:

```c
XrResult xrCreateInstance(
    const XrInstanceCreateInfo* createInfo,
    XrInstance* instance
);
```

Generated Zig wrapper (shape, not exact code):

```zig
pub fn createInstance(self: Self, info: InstanceCreateInfo) !Instance { ... }
```

Rules:

- Non-const, non-optional single-item pointers are treated as **out parameters** and become return values.
- `XrResult` success vs error codes:
  - Success: function returns the value(s) you care about.
  - Error: mapped into a Zig error set (`error.OutOfMemory`, `error.InstanceLost`, etc.).
- If a command returns multiple out values, a small struct is generated to hold them.

### 4.3 Function pointers and dispatch tables

The generator emits function pointer types that exactly match the C signatures:

```zig
pub const PfnCreateInstance = fn (
    create_info: *const InstanceCreateInfo,
    instance: *Instance,
) callconv(openxr_call_conv) Result;
```

You then build small “dispatch” structs that hold only function pointers, and mix in wrappers:

```zig
const xr = @import("xr");

const BaseDispatch = struct {
    xrCreateInstance: xr.PfnCreateInstance,
    usingnamespace xr.BaseWrapper(@This());
};
```

Wrappers are grouped into:

- `BaseWrapper` – functions that don’t need an `Instance` (e.g. `xrCreateInstance`, enumeration calls).
- `InstanceWrapper` – functions that do need an `Instance`.

Each wrapper type exposes a `load` helper that uses `xrGetInstanceProcAddr` to fill the function pointer table:

```zig
const base = try BaseDispatch.load(getProcAddr); // you implement getProcAddr
const instance = try base.createInstance(create_info);
```

For `xrGetInstanceProcAddr`, you typically use `openxr_loader` and wrap it in a Zig function that returns `xr.PfnVoidFunction`.

---

## 5. Bitflags, handles, structs, pointers

### 5.1 Bitflags

Bitflags are modeled as packed structs of `bool`, with a mixin for set operations:

```zig
pub const ViewStateFlags = packed struct {
    orientation_valid_bit: bool align(@alignOf(Flags64)) = false,
    position_valid_bit: bool = false,
    orientation_tracked_bit: bool = false,
    position_tracked_bit: bool = false,
    // ...
    pub usingnamespace FlagsMixin(ViewStateFlags);
};
```

The `FlagsMixin` for each flag type provides:

- `IntType` – integer representation used at ABI boundaries (e.g. `Flags64`).
- `toInt` / `fromInt`
- `merge`, `intersect`, `subtract`, `complement`
- `contains`

On the wire, flags are passed as integers. In Zig code, you work with strongly-typed flag structs.

### 5.2 Handles

Handles are non-exhaustive enums over integers:

```zig
pub const Instance = extern enum(usize) { null_handle = 0, _ };
```

- Non-dispatchable handles typically use `u64`.
- Dispatchable handles use `usize`.

This gives you type safety without changing the ABI.

### 5.3 Struct defaults

Generated structs get sensible defaults:

- `type` → correct `StructureType` variant.
- `next` → `null`.
- Common math types (`Vector*`, `Color*`, `Quaternionf`, `Offset*`, `Extent*`, `Posef`, `Rect*`) → all fields zero-initialized.
- No other fields defaulted.

Each struct includes an `empty()` helper that sets just `type` and `next`, for “output-only” structs:

```zig
pub const InstanceCreateInfo = extern struct {
    type: StructureType = .instance_create_info,
    next: ?*const anyopaque = null,
    // ...
    pub fn empty() @This() {
        var value: @This() = undefined;
        value.type = .instance_create_info;
        value.next = null;
        return value;
    }
};
```

### 5.4 Pointer metadata

Where the registry provides it, pointer types are annotated with:

- Optional vs non-optional.
- Const vs non-const.
- Single-item / many-items / null-terminated.

The generator also corrects `next` to be treated as optional everywhere (it’s effectively optional in practice).

---

## 6. Differences from the spec

One intentional behavioral difference:

- `XR_SESSION_STATE_LOSS_PENDING` is treated as an **error** instead of a “success with special meaning”.  
  This forces you to handle it via the error union and keeps normal return types cleaner.

Other changes (naming, struct defaults, bitflag modeling, etc.) are mechanical and follow Zig conventions.

---

## 7. Compatibility and limitations

- **Zig version**  
  This repo targets a specific Zig dev snapshot or release. If you update your Zig compiler and builds start failing:
  - Update `openxr-zig` to a newer commit/tag, or
  - Pin your Zig toolchain version for this project.

- **Registry version**  
  The generator is designed for modern OpenXR 1.x `xr.xml`. If Khronos significantly changes the schema, you may need an update here.

- **Feature / extension selection**  
  Currently, bindings are generated for the **full** registry.  
  Selecting “only these features/extensions” is non-trivial (because promoted extensions are renamed in core) and is not implemented yet.

- **Regeneration**  
  When used as a dependency with build-time generation, the bindings may be regenerated whenever the build graph decides it is necessary.  
  If you want a fully static API:
  - Generate `src/xr.zig` once.
  - Commit it.
  - Stop invoking the generator from `build.zig`.

---

## 8. Who this is for

- Engine / framework authors who want a Zig-native OpenXR layer.
- Game / XR developers comfortable working on top of raw OpenXR concepts.
- Zig users (often on nightly/dev builds) who don’t want to maintain bindings by hand.

If you just need a few OpenXR calls from C/C++, the standard `openxr_loader` + `openxr.h` is usually simpler.

---

## 9. Credits

- Generator approach is inspired by [Snektron’s `vulkan-zig`](https://github.com/Snektron/vulkan-zig).
- OpenXR, `xr.xml`, and the reference loader are provided by the Khronos OpenXR working group.
