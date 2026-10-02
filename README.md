# FSIB: Shader Warmup for Godot 4

https://github.com/user-attachments/assets/dca3094b-c01c-408c-86a5-c0fbe96999df

Spawns every scene, mesh and material of your project in a hidden "warmup" scene, so that shaders and render pipelines are compiled **before** gameplay starts and the player doesn't get stutters the first time an effect appears.

- Loads resources **lazily and in the background** (`ResourceLoader.load_threaded_request`), the next batch is prefetched while the current one renders.
- Remembers what has already been warmed up. Resources are identified by a **SHA-256 hash** of the file and its shader-relevant dependencies, so unchanged resources are skipped on the next launch and are not even loaded.
- Cache is automatically invalidated when the GPU, driver, engine version, renderer or quality settings change.
- Neutralizes spawned instances (scripts removed, timers/animations/audio/collisions disabled) so nothing from your game logic runs during warmup.

> Designed for **Godot 4.4+ with the Forward+ renderer**. Other renderers and older 4.x versions may work, but are not the target.

## Installation

1. Copy the plugin folder to `res://addons/` (it should contain `fsib_scene.tscn` and `scripts/`).
2. No plugin activation is required, the scripts are available through their `class_name`s: `FSIB_Main` and `FSIB_Tools`.

## Quick start

The plugin ships with a ready-made warmup scene, `fsib_scene.tscn`. It only needs to be set as the first scene of your game:

1. Open **Project Settings > Application > Run > Main Scene** and select `fsib_scene.tscn`.
2. Open `fsib_scene.tscn`, select the root node and set **Next Scene** in the Inspector to the scene your game should open after warmup (for example, your main menu).
3. Run the project. The scene shows a progress bar while shaders are compiled, then switches to the next scene automatically.

On the next launches already warmed-up resources are skipped (see [How the cache works](#how-the-cache-works)), so the scene finishes almost instantly.

### Scene settings

| Property | Description |
|---|---|
| `next_scene` | Scene to open when warmup is finished. If empty, the warmup scene just stays on screen. |
| `batch_size` | How many resources are spawned and compiled at once (default `2`). Higher is faster, but uses more memory and may cause a short freeze per batch. |
| `force_warmup` | Ignore the cache and warm up everything on every launch. Useful for debugging. |

The `Nodes` group (`fsib_main`, labels, progress bar, `spawn_root`) is already wired up in the scene. You only need to touch it if you restyle the UI.

### Matching your game's rendering settings

The warmup scene renders real 3D objects under an opaque overlay, so shader variants depend on its environment:

- Keep the `WorldEnvironment` and light settings the same as in your game (SSAO, SSR, SDFGI, glow, fog, shadows).
- Viewport settings (MSAA, TAA, screen-space AA, 3D scaling) must match the game's, otherwise the wrong pipelines are compiled. They are also part of the cache signature.
- Spawned objects must stay inside the camera frustum and inside the directional light's `shadow_max_distance`, otherwise they are culled and nothing is compiled.
- Do not hide the 3D part with `visible = false` or a disabled viewport, cover it with an opaque `CanvasLayer` instead.

## API

### `FSIB_Main`

| Member | Description |
|---|---|
| `warmup(paths, spawn_root, batch_size = 8, force = false)` | Warms up the given resource paths. `force = true` ignores the cache. |
| `cancel()` | Stops after the current batch. Progress made so far is saved. |
| `reset_cache()` | Deletes the saved hash cache. |
| `signal status_updated(info)` | Human-readable status text. |
| `signal progress_updated(done, overral)` | Number of processed resources and total number to process (cached ones are not counted). |
| `signal done()` | Emitted when warmup has finished (or was cancelled). |
| `@export build_id` | Used for hashing in exported builds. Defaults to `application/config/version`. **Change it on every release.** |
| `@export frames_per_batch` | Frames to wait after spawning a batch (default `3`). Pipelines compile asynchronously. |
| `@export time_budget_ms` | Per-frame time budget for hash calculation (default `8`). |
| `@export save_every_batches` | How often the cache file is written (default `4`). |

### `FSIB_Tools`

| Function | Description |
|---|---|
| `get_all_resources(allowed_ext)` | Returns paths of all warmup-relevant resources in `res://` (scenes, `.tres`/`.res`, materials, models). `res://addons/` and `res://.godot/` are skipped. |
| `deep_search(dir, resources)` | Recursive directory scan using `ResourceLoader.list_directory`. |
| `get_all_children(node)` | Returns the node itself and all of its descendants. |

You can pass your own list of paths to `warmup()` instead of using `get_all_resources()`, for example only the content of a specific level.

## What gets spawned

| Resource | How it is warmed up |
|---|---|
| `PackedScene` | Instantiated, scripts removed, spawned in front of the camera. GPU particles are restarted. |
| `Material` (spatial) | Applied to a temporary `SphereMesh`. Non-spatial `ShaderMaterial`s are skipped. |
| `Mesh` | Spawned as a `MeshInstance3D`. |
| Everything else | Loaded and marked as processed, nothing is rendered. |

## How the cache works

- The cache file is stored at `user://fsib_cache.json`.
- A resource's hash is built from its own file **and** all of its dependencies that influence shaders (scenes, resources, shaders, models). Textures, audio and scripts are ignored on purpose.
- The file also stores an **environment signature**: engine version hash, OS, GPU vendor and name, graphics API version, renderer, MSAA, screen-space AA, TAA, 3D scaling mode and debanding. If anything changes, the whole cache is discarded.
- Skipping is only enabled if `rendering/rendering_device/pipeline_cache/enable` is `true`. Otherwise the engine would not keep compiled pipelines between launches and skipping would be wrong.
- In **exported builds** project files can't be hashed directly (they are converted and remapped). The `build_id` is used instead, so bump your project version for every release.

## Limitations and tips

- Shader variants that depend on runtime state (materials created in code, parameters assigned by scripts, objects spawned only by gameplay code) can't be discovered automatically. Add such resources to the list manually.
- Warmup removes scripts from spawned instances. Anything created in `_init()` of a script still runs during `instantiate()`.
- If the player clears the driver shader cache or the `user://` directory manually, the hash cache may become stale. Consider exposing a "Rebuild shader cache" button that calls `reset_cache()`.
- Loading the whole project can use a lot of memory. Lower `batch_size` if needed, resources are released after each batch.
- 2D content (`Control`, `CanvasItem`) is added under the 3D spawn root and rendered, but the 2D shader pipelines depend on the canvas layer it is drawn to, so make sure it is shown below your cover layer.

## Troubleshooting

| Problem | Possible cause |
|---|---|
| Stutters still happen in-game | Warmup scene environment/light/quality differs from the game, objects were outside of the frustum, or the resource is created only at runtime. |
| Everything is warmed up on every launch | `pipeline_cache/enable` is off, `user://` is not writable, or the environment signature changes between launches. |
| Changes in a material don't trigger re-warmup (exported build) | `build_id` was not changed. |
| Nothing is found for a scene's dependencies | Check the dependency format returned by `ResourceLoader.get_dependencies()` in your Godot version. |

## License

[MIT](LICENSE)
