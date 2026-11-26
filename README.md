
# Rbxlx Forge

Deep-copy a running Roblox experience into a portable `.rbxlx` file with maximum fidelity.

Rbxlx Forge walks the live DataModel, reflects every property it can reach, and serializes the entire tree into standard Roblox XML — including the parts Roblox normally hides.

## Features

- **Two-pass reference mapping** — cross-instance `Ref` properties (e.g. `Part0`, `Attachment0`, `Adornee`) resolve correctly.
- **Universal property serializer** — supports 30+ Roblox data types via `typeof` dispatch.
- **Real binary attribute encoding** — writes proper `AttributesSerialize` blobs, not fake string properties.
- **CollectionService tags** — persisted through `TagsSerialize`.
- **Script decompilation** — falls back to `getscriptbytecode` when source is stripped.
- **Terrain** — dumps `SmoothGrid` when the executor permits `CopyRegion`.
- **Chunked I/O** — 1 MB buffer, safe on large maps.
- **Iterative tree walk** — no stack overflow on deep hierarchies.

## Requirements

Rbxlx Forge requires an execution environment that exposes:

| Function | Purpose |
|---|---|
| `writefile` / `appendfile` | Disk output |
| `decompile` | Script source recovery |
| `getproperties` | Property reflection |
| `getscriptbytecode` | Bytecode fallback (optional) |

These are **not** available in vanilla Roblox Studio. You need a third-party execution environment (executor).

## Install

1. Save `src/init.lua` as a `ModuleScript` in `ReplicatedStorage`.
2. Name it `RbxlxForge`.

## Usage

```lua
local RbxlxForge = require(game.ReplicatedStorage.RbxlxForge)

local success, itemCount, elapsedSeconds, totalBytes = RbxlxForge.Run()

if success then
    print(("Dumped %d instances in %.2fs (%.1f KB)")
        :format(itemCount, elapsedSeconds, totalBytes / 1024))
end
