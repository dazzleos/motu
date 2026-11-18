//! What Motu draws with: the GPU, behind the kinds and calls Motu uses
//! of it, so that it can be built for another (the renderer, the upscaler
//! and the window's drawing use only these).
//!
//! On Dazzle: the VideoCore IV, through Dazzle's vc4 and shader modules.
//! These names stand for theirs, with nothing in between, so drawing
//! costs no more than calling them. (The previews, drawn on the CPU by
//! Dazzle's GPU simulator, use vc4 themselves: see preview.zig.)

const vc4 = @import("vc4");
const shader = @import("shader");

/// The GPU (opened by the window's host).
pub const Device = vc4.Device;
/// A buffer on the GPU, its memory mapped (`map`) for the CPU to fill.
pub const Buffer = vc4.Bo;
/// Its pixel formats.
pub const Format = vc4.Format;

/// A frame being recorded (draws go into it), where in it a draw goes
/// (and what it is cut to), what is drawn into, and a texture as a draw
/// samples it.
pub const Frame = vc4.render.Frame;
pub const Viewport = vc4.render.Viewport;
pub const Target = vc4.render.Target;
pub const Texture = vc4.render.Texture;

/// Textures: their layouts (with mipmaps) and how they are sampled.
pub const texture = vc4.texture;

/// A shader program (as Dazzle's compiler made it), and a pipeline: the
/// program with the vertex layout and render state it is drawn with.
pub const Program = shader.Program;
pub const Pipeline = shader.Pipeline;
pub const pipeline = shader.pipeline;
