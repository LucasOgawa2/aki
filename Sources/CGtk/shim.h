// GTK 4 for aki-mark. Xlib is CX11's alone (no gdk/x11 here: its `Display` would clash).
#include <gtk/gtk.h>

// gdk_pixbuf_save_to_buffer is variadic, which Swift can't call: JPEG at quality 70.
static inline gboolean aki_pixbuf_jpeg(GdkPixbuf *pixbuf, gchar **buffer, gsize *size, GError **error) {
    return gdk_pixbuf_save_to_buffer(pixbuf, buffer, size, "jpeg", error, "quality", "70", NULL);
}
