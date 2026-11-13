import CGtk

// GLib's macros (g_signal_connect, G_CALLBACK, the casts) don't import: these stand in.
// A Swift closure travels as the signal's user_data, retained until GLib drops it.

final class Box<F> {
    let f: F
    init(_ f: F) { self.f = f }
}

private let releaseBox: GClosureNotify = { data, _ in
    if let data { Unmanaged<AnyObject>.fromOpaque(data).release() }
}

private func connect<F>(_ instance: UnsafeMutableRawPointer, _ signal: String, _ thunk: GCallback, _ f: F) {
    g_signal_connect_data(instance, signal, thunk, Unmanaged.passRetained(Box(f) as AnyObject).toOpaque(), releaseBox, GConnectFlags(0))
}

private func unbox<F>(_ data: gpointer?) -> F {
    (Unmanaged<AnyObject>.fromOpaque(data!).takeUnretainedValue() as! Box<F>).f
}

/// A signal with no arguments of its own (`activate`, `changed`).
func onSignal(_ instance: UnsafeMutableRawPointer, _ signal: String, _ f: @escaping () -> Void) {
    let thunk: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in (unbox(data) as () -> Void)() }
    connect(instance, signal, unsafeBitCast(thunk, to: GCallback.self), f)
}

/// A signal that answers whether it was handled (`close-request`).
func onSignalHandled(_ instance: UnsafeMutableRawPointer, _ signal: String, _ f: @escaping () -> Bool) {
    let thunk: @convention(c) (gpointer?, gpointer?) -> gboolean = { _, data in (unbox(data) as () -> Bool)() ? 1 : 0 }
    connect(instance, signal, unsafeBitCast(thunk, to: GCallback.self), f)
}

/// A drag gesture's `drag-begin`, `drag-update` and `drag-end` (two doubles).
func onDrag(_ instance: UnsafeMutableRawPointer, _ signal: String, _ f: @escaping (Double, Double) -> Void) {
    let thunk: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> Void = { _, x, y, data in
        (unbox(data) as (Double, Double) -> Void)(x, y)
    }
    connect(instance, signal, unsafeBitCast(thunk, to: GCallback.self), f)
}

/// `key-pressed`: the keyval and the modifiers; true when used.
func onKey(_ instance: UnsafeMutableRawPointer, _ f: @escaping (UInt32, GdkModifierType) -> Bool) {
    let thunk: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, keyval, _, state, data in
        (unbox(data) as (UInt32, GdkModifierType) -> Bool)(keyval, state) ? 1 : 0
    }
    connect(instance, "key-pressed", unsafeBitCast(thunk, to: GCallback.self), f)
}

/// Runs on GLib's loop (the GTK thread): the Dispatch main queue isn't drained while it runs.
func onGtkThread(_ f: @escaping () -> Void) {
    let data = Unmanaged.passRetained(Box(f) as AnyObject).toOpaque()
    g_idle_add({ data in
        (Unmanaged<AnyObject>.fromOpaque(data!).takeRetainedValue() as! Box<() -> Void>).f()
        return 0 // G_SOURCE_REMOVE
    }, data)
}

/// A drawing area's draw function, with its own closure.
func setDraw(_ area: UnsafeMutableRawPointer, _ f: @escaping (OpaquePointer, Int32, Int32) -> Void) {
    let data = Unmanaged.passRetained(Box(f) as AnyObject).toOpaque()
    gtk_drawing_area_set_draw_func(area.assumingMemoryBound(to: GtkDrawingArea.self), { _, cairo, width, height, data in
        (unbox(data) as (OpaquePointer, Int32, Int32) -> Void)(cairo!, width, height)
    }, data, { data in if let data { Unmanaged<AnyObject>.fromOpaque(data).release() } })
}

/// The typed pointers GTK's functions want (its casting macros don't import).
@inline(__always) func typed<T>(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutablePointer<T> {
    pointer.assumingMemoryBound(to: T.self)
}

/// The same for GTK's opaque types (GtkLabel, GtkPicture, GtkBox…).
@inline(__always) func typed(_ pointer: UnsafeMutableRawPointer) -> OpaquePointer {
    OpaquePointer(pointer)
}
