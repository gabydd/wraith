const ghostty = @import("ghostty");
pub const ghostty_options = struct {
    pub const Renderer = ghostty.renderer.OpenGL;
    pub const runtime = ghostty.apprt.glfw;
};
