#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <memory>
#include <string>

static constexpr char kMethodChannel[] = "com.populi.doubleNaught/file_picker";
static constexpr char kMethodPickFileOrDirectory[] = "pickFileOrDirectory";

struct PickerData {
  FlMethodResponse* response;
};

// GTK file chooser response callback
static void on_file_chooser_response(GtkNativeDialog* self, gint response_id,
                                     gpointer user_data) {
  auto data = static_cast<PickerData*>(user_data);

  if (response_id == GTK_RESPONSE_ACCEPT) {
    GtkFileChooser* chooser = GTK_FILE_CHOOSER(self);
    char* path = gtk_file_chooser_get_filename(chooser);

    if (path) {
      // Determine if it's a file or directory
      GFileType file_type = G_FILE_TYPE_UNKNOWN;
      GFile* file = g_file_new_for_path(path);
      GFileInfo* info =
          g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_TYPE, G_FILE_QUERY_INFO_NONE, nullptr, nullptr);

      if (info) {
        file_type = g_file_info_get_file_type(info);
        g_object_unref(info);
      }
      g_object_unref(file);

      const char* type_str = (file_type == G_FILE_TYPE_DIRECTORY) ? "dir" : "file";

      // Build response map
      g_autoptr(FlValue) result = fl_value_new_map();
      fl_value_set_string_take(result, "type", fl_value_new_string(type_str));
      fl_value_set_string_take(result, "path", fl_value_new_string(path));

      data->response = FL_METHOD_RESPONSE(
          fl_method_success_response_new(result));

      g_free(path);
    } else {
      // Cancelled
      data->response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else {
    // Cancelled
    data->response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  gtk_native_dialog_destroy(self);
}

// Dart method handler
static void file_picker_method_handler(FlMethodChannel* channel, FlMethodCall* method_call,
                                       gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, kMethodPickFileOrDirectory) == 0) {
    GtkWidget* window = GTK_WIDGET(user_data);
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        "Select File or Folder", GTK_WINDOW(window),
        GTK_FILE_CHOOSER_ACTION_OPEN,
        "Open", "Cancel");

    // Key: enable both file and folder selection
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(chooser), FALSE);

    auto data = new PickerData();
    g_signal_connect(chooser, "response", G_CALLBACK(on_file_chooser_response), data);

    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
  }
}

void file_picker_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  GtkWidget* window = fl_plugin_registrar_get_view(registrar);

  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kMethodChannel,
      FL_METHOD_CODEC(fl_standard_method_codec_new()));

  fl_method_channel_set_method_call_handler(channel, file_picker_method_handler,
                                            window, nullptr);

  g_object_unref(channel);
}
