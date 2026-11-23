#include "my_application.h"

#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

#include <string>

// Player engine (Settings → Playback, app/lib/platform/engine.dart). media_kit's video plugin links libmpv.so.2
// itself, so gerdTV's own libmpv has to be the one the whole process loads, not only the one Dart opens: two
// libmpv copies in one process crash (a handle from one, called through the other). When the engine marker
// exists, gerdTV restarts once with LD_LIBRARY_PATH pointing at lib/gerdmpv/, whose libmpv.so.2 and libmpv.so are
// links to lib/libgerdmpv.so (app/linux/CMakeLists.txt). Without the marker, or the folder, nothing changes.
// Debugging: GERDTV_ENGINE_SET=1 in /proc/<pid>/environ shows the restart happened; `ldd` with the same
// LD_LIBRARY_PATH on lib/libmedia_kit_video_plugin.so shows which libmpv it resolves.
static void use_own_libmpv(char** argv) {
  if (getenv("GERDTV_ENGINE_SET") != nullptr) return;  // restarted already
  const char* xdg = getenv("XDG_DATA_HOME");
  const char* home = getenv("HOME");
  std::string data = xdg != nullptr && *xdg ? xdg : std::string(home != nullptr ? home : "") + "/.local/share";
  // The marker sits in the app's support folder (path_provider: <data>/<application id>).
  if (access((data + "/" APPLICATION_ID "/player-engine-gerdtv").c_str(), F_OK) != 0) return;
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0) return;
  exe[n] = '\0';
  std::string dir = std::string(exe).substr(0, std::string(exe).rfind('/')) + "/lib/gerdmpv";
  if (access((dir + "/libmpv.so.2").c_str(), F_OK) != 0) return;  // not bundled: the standard engine
  const char* old = getenv("LD_LIBRARY_PATH");
  setenv("LD_LIBRARY_PATH", (old != nullptr && *old ? dir + ":" + old : dir).c_str(), 1);
  setenv("GERDTV_ENGINE_SET", "1", 1);
  execv(exe, argv);  // returns only on failure: then the standard engine it is
}

int main(int argc, char** argv) {
  use_own_libmpv(argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
