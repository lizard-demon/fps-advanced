# FPS Engine

A simple first-person shooter engine written in ~1200 lines of Zig, featuring brush-based geometry and BVH acceleration for collision detection.

## Features

- **First-person movement** with mouse look and WASD controls
- **Brush-based geometry** using convex polyhedra for collision and rendering
- **BVH spatial acceleration** for efficient collision queries
- **Quake-style physics** with proper acceleration, friction, and air control
- **Cross-platform graphics** via Sokol (OpenGL, Metal, WebGL, WGSL)
- **Audio system** with background music and sound effects

## Controls

- **WASD** - Move
- **Mouse** - Look around
- **Space** - Jump
- **Escape** - Toggle mouse lock

## Building

### Prerequisites

- [Zig](https://ziglang.org/) (latest)
- For web builds: [Emscripten](https://emscripten.org/)

### Native Build

```bash
zig build run
```

### Web Build

```bash
zig build -Dtarget=wasm32-emscripten
```

## Architecture

- **Physics** - Collision detection with brush expansion and BVH traversal
- **Rendering** - Mesh generation from brush plane intersections
- **Audio** - 16-voice mixer with PCM file support
- **Math** - SIMD-optimized Vec3/Mat4 operations

The world consists of 8 brushes defining platforms, slopes, and structures. Each brush is a convex polyhedron represented by plane equations, enabling both collision detection and mesh generation from the same data.

## Dependencies

- [sokol](https://github.com/floooh/sokol) - Cross-platform graphics
- [cimgui](https://github.com/cimgui/cimgui) - Immediate mode UI
- [shdc](https://github.com/floooh/sokol-tools) - Shader compiler