const ghostty = @import("ghostty");
const std = @import("std");

const log = std.log;

const cli = ghostty.cli;
const input = ghostty.input;
const internal_os = ghostty.internal_os;
const renderer = ghostty.renderer;
const terminal = ghostty.terminal;
const Renderer = renderer.Renderer;
const apprt = ghostty.apprt;
const CoreApp = ghostty.App;
const CoreSurface = ghostty.Surface;
const configpkg = ghostty.config;
const Config = configpkg.Config;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const gl = ghostty.gl;
const egl = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

const Context = struct {
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
pub const App = struct {
    app: *CoreApp,
    config: Config,
    display: *wl.Display,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,

    egl_display: ?*anyopaque,
    egl_config: *anyopaque,

    pub const Options = struct {};
    pub fn init(core_app: *CoreApp, _: Options) !App {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        var context: Context = .{
            .compositor = null,
            .wm_base = null,
        };
        registry.setListener(*Context, registryListener, &context);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = context.compositor orelse return error.NoWlCompositor;
        const wm_base = context.wm_base orelse return error.NoXdgWmBase;
        const egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);
        var egl_major: egl.EGLint = 0;

        var egl_minor: egl.EGLint = 0;
        if (egl.eglInitialize(egl_display, &egl_major, &egl_minor) == egl.EGL_TRUE) {
            log.info("EGL version: {}.{}", .{ egl_major, egl_minor });
        } else switch (egl.eglGetError()) {
            egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
            else => return error.EglFailedToinitialize,
        }
        const egl_attributes: [12:egl.EGL_NONE]egl.EGLint = .{
            egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
        };
        const egl_config = config: {
            // Rather ask for a list of possible configs, we just get the first one and
            // hope it is a good choice.
            var config: egl.EGLConfig = null;
            var num_configs: egl.EGLint = 0;
            const result = egl.eglChooseConfig(
                egl_display,
                &egl_attributes,
                &config,
                1,
                &num_configs,
            );

            if (result != egl.EGL_TRUE) {
                switch (egl.eglGetError()) {
                    egl.EGL_BAD_ATTRIBUTE => return error.InvalidEglConfigAttribute,
                    else => return error.EglConfigError,
                }
            }
            break :config config orelse return error.NoEglConfig;
        };
        if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_PARAMETER => return error.OpenGlUnsupported,
                else => return error.InvalidApi,
            }
        }

        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // If we had configuration errors, then log them.
        if (!config._diagnostics.empty()) {
            var buf = std.ArrayList(u8).init(core_app.alloc);
            defer buf.deinit();
            for (config._diagnostics.items()) |diag| {
                try diag.write(buf.writer());
                log.warn("configuration error: {s}", .{buf.items});
                buf.clearRetainingCapacity();
            }

            // If we have any CLI errors, exit.
            if (config._diagnostics.containsLocation(.cli)) {
                log.warn("CLI errors detected, exiting", .{});
                _ = core_app.mailbox.push(.{
                    .quit = {},
                }, .{ .forever = {} });
            }
        }

        // Queue a single new window that starts on launch
        // Note: above we may send a quit so this may never happen
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        return .{
            .app = core_app,
            .config = config,
            .compositor = compositor,
            .wm_base = wm_base,
            .egl_display = egl_display,
            .egl_config = egl_config,
            .display = display,
        };
    }

    pub fn terminate(self: *App) void {
        _ = self; // autofix
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !void {
        switch (action) {
            .new_window => _ = try self.newSurface(switch (target) {
                .app => null,
                .surface => |v| v,
            }),
            .reload_config => try self.reloadConfig(target, value),
            .new_tab,
            .toggle_fullscreen,
            .size_limit,
            .initial_size,
            .set_title,
            .mouse_shape,
            .mouse_visibility,
            .open_config,

            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .present_terminal,
            .close_all_windows,
            .toggle_tab_overview,
            .toggle_window_decorations,
            .toggle_quick_terminal,
            .toggle_visibility,
            .goto_tab,
            .move_tab,
            .inspector,
            .render_inspector,
            .quit_timer,
            .secure_input,
            .key_sequence,
            .desktop_notification,
            .mouse_over_link,
            .cell_size,
            .renderer_health,
            .color_change,
            .pwd,
            .config_change,
            => log.info("unimplemented action={}", .{action}),
        }
    }

    /// Reload the configuration. This should return the new configuration.
    /// The old value can be freed immediately at this point assuming a
    /// successful return.
    ///
    /// The returned pointer value is only valid for a stable self pointer.
    fn reloadConfig(
        self: *App,
        target: apprt.action.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        if (opts.soft) {
            switch (target) {
                .app => try self.app.updateConfig(self, &self.config),
                .surface => |core_surface| try core_surface.updateConfig(
                    &self.config,
                ),
            }
            return;
        }

        // Load our configuration
        var config = try Config.load(self.app.alloc);
        errdefer config.deinit();

        // Call into our app to update
        switch (target) {
            .app => try self.app.updateConfig(self, &config),
            .surface => |core_surface| try core_surface.updateConfig(&config),
        }

        // Update the existing config, be sure to clean up the old one.
        self.config.deinit();
        self.config = config;
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        @panic("This should never be called for wayland.");
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;

        // wayland doesn't support the inspector
    }

    pub fn run(self: *App) !void {
        _ = try self.app.tick(self);
        while (true) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;

            // Tick the terminal app
            const should_quit = try self.app.tick(self);
            if (should_quit or self.app.surfaces.items.len == 0) {
                for (self.app.surfaces.items) |surface| {
                    surface.close(false);
                }

                return;
            }
        }
    }

    pub fn wakeup(self: *App) void {
        _ = self;
    }

    pub fn newSurface(self: *App, parent_: ?*CoreSurface) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.app.alloc.create(Surface);
        errdefer self.app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(self);
        errdefer surface.deinit();

        // If we have a parent, inherit some properties
        if (self.config.@"window-inherit-font-size") {
            if (parent_) |parent| {
                try surface.core_surface.setFontSize(parent.font_size);
            }
        }

        return surface;
    }
};

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *Surface) void {
    switch (event) {
        .configure => |configure| {
            const size = surface.getSize() catch |err| {
                log.err("error querying window size for size callback err={}", .{err});
                return;
            };
            surface.egl_window.resize(@intCast(size.width), @intCast(size.height), 0, 0);

            // Call the primary callback.
            surface.core_surface.sizeCallback(size) catch |err| {
                log.err("error in size callback err={}", .{err});
                return;
            };
            xdg_surface.ackConfigure(configure.serial);
            surface.wl_surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, surface: *Surface) void {
    switch (event) {
        .configure => |configure| {
            surface.width = @intCast(configure.width);
            surface.height = @intCast(configure.height);
        },
        .close => surface.should_close = true,
    }
}

pub const Surface = struct {
    /// The app we're part of
    app: *App,

    /// A core surface
    core_surface: CoreSurface,

    wl_surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    egl_window: *wl.EglWindow,
    egl_surface: *anyopaque,
    egl_context: ?*anyopaque,

    title_text: ?[:0]const u8,
    should_close: bool,
    width: u32,
    height: u32,

    pub fn init(self: *Surface, app: *App) !void {
        self.egl_context = null;
        self.title_text = null;
        self.app = app;
        self.should_close = false;

        self.wl_surface = try app.compositor.createSurface();
        errdefer self.wl_surface.destroy();
        self.xdg_surface = try app.wm_base.getXdgSurface(self.wl_surface);
        errdefer self.xdg_surface.destroy();
        self.xdg_toplevel = try self.xdg_surface.getToplevel();
        errdefer self.xdg_toplevel.destroy();
        self.xdg_surface.setListener(*Surface, xdgSurfaceListener, self);
        self.xdg_toplevel.setListener(*Surface, xdgToplevelListener, self);

        self.egl_window = try wl.EglWindow.create(self.wl_surface, 500, 500);
        self.height = 500;
        self.width = 500;

        self.egl_surface = egl.eglCreatePlatformWindowSurface(
            self.app.egl_display,
            self.app.egl_config,
            @ptrCast(self.egl_window),
            null,
        ) orelse switch (egl.eglGetError()) {
            egl.EGL_BAD_MATCH => return error.MismatchedConfig,
            egl.EGL_BAD_CONFIG => return error.InvalidConfig,
            egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidWindow,
            else => return error.FailedToCreateEglSurface,
        };
        self.wl_surface.commit();
        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(self);
        errdefer app.app.deleteSurface(self);

        // Get our new surface config
        var config = try apprt.surface.newConfig(app.app, &app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        try self.core_surface.init(
            app.app.alloc,
            &config,
            app.app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();
    }
    pub fn deinit(self: *Surface) void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();

        self.xdg_toplevel.destroy();
        self.xdg_surface.destroy();
        self.wl_surface.destroy();
    }
    pub fn shouldClose(self: *Surface) bool {
        return self.should_close;
    }
    pub fn close(self: *Surface, proccess_active: bool) void {
        _ = proccess_active; // autofix
        self.should_close = true;
        self.deinit();
        self.app.app.alloc.destroy(self);
    }
    /// Set the title of the window.
    fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        if (self.title_text) |t| self.core_surface.alloc.free(t);
        self.title_text = try self.core_surface.alloc.dupeZ(u8, slice);
        // TODO: actually set title
    }

    /// Return the title of the window.
    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title_text;
    }
    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self; // autofix
        return apprt.ContentScale{ .x = 1, .y = 1 };
    }

    /// Returns the size of the window in pixels. The pixel size may
    /// not match screen coordinate size but we should be able to convert
    /// back and forth using getContentScale.
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return apprt.SurfaceSize{ .width = self.width, .height = self.height };
    }

    /// Returns the cursor position in scaled pixels relative to the
    /// upper-left of the window.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        _ = self; // autofix
        return apprt.CursorPos{
            .x = 0,
            .y = 0,
        };
    }

    /// Start an async clipboard request.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !void {
        _ = state; // autofix
        _ = clipboard_type; // autofix
        _ = self; // autofix
    }

    /// Set the clipboard.
    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        _ = confirm; // autofix
        _ = clipboard_type; // autofix
        _ = val; // autofix
        _ = self; // autofix
    }

    pub fn threadEnter(self: *Surface) !void {
        if (self.egl_context == null) {
            const context_attributes: [4:egl.EGL_NONE]egl.EGLint = .{
                egl.EGL_CONTEXT_MAJOR_VERSION, 4,
                egl.EGL_CONTEXT_MINOR_VERSION, 6,
            };
            self.egl_context = egl.eglCreateContext(
                self.app.egl_display,
                self.app.egl_config,
                egl.EGL_NO_CONTEXT,
                &context_attributes,
            ) orelse switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
                egl.EGL_BAD_CONFIG => return error.CreateContextWithBadConfig,
                egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
                else => return error.FailedToCreateContext,
            };
        }
        const result = egl.eglMakeCurrent(
            self.app.egl_display,
            self.egl_surface,
            self.egl_surface,
            self.egl_context,
        );

        if (result == egl.EGL_FALSE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }

        const version = try gl.glad.load(egl.eglGetProcAddress);
        errdefer gl.glad.unload();
        log.err("loaded OpenGL {}.{}", .{
            gl.glad.versionMajor(@intCast(version)),
            gl.glad.versionMinor(@intCast(version)),
        });
    }

    pub fn swapBuffers(self: *Surface) !void {
        if (egl.eglSwapBuffers(self.app.egl_display, self.egl_surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.PresentInvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.EGLContextLost,
                else => return error.FailedToSwapBuffers,
            }
        }
    }
    pub fn finalizeSurfaceInit(self: *Surface) !void {
        const result = egl.eglMakeCurrent(
            self.app.egl_display,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_CONTEXT,
        );

        if (result == egl.EGL_FALSE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ACCESS => return error.EglThreadError,
                egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
                egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
                egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
                egl.EGL_BAD_ALLOC => return error.OutOfMemory,
                else => return error.FailedToMakeCurrent,
            }
        }
    }

    pub fn threadExit(self: *Surface) void {
        gl.glad.unload();
        _ = egl.eglMakeCurrent(
            self.app.egl_display,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_SURFACE,
            egl.EGL_NO_CONTEXT,
        );
    }
};
