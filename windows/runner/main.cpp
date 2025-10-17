#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <fstream>
#include <cstdlib>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Persist arguments to APPDATA\\PortrAI\\args.txt for Dart to read (older Flutter versions
  // may not expose entrypoint arguments to Dart API)
  {
    // Resolve %APPDATA% path safely using Windows API
    wchar_t* appdata_w = nullptr;
    size_t len = 0;
    std::string dir_path;
    if (_wdupenv_s(&appdata_w, &len, L"APPDATA") == 0 && appdata_w != nullptr) {
      int size_needed = WideCharToMultiByte(CP_UTF8, 0, appdata_w, -1, NULL, 0, NULL, NULL);
      std::string base_dir(size_needed > 0 ? size_needed - 1 : 0, '\0');
      WideCharToMultiByte(CP_UTF8, 0, appdata_w, -1, base_dir.data(), size_needed, NULL, NULL);
      free(appdata_w);
      dir_path = base_dir + "\\PortrAI";
    } else {
      dir_path = std::string(".\\PortrAI");
    }

    // Create directory if missing (ignore errors)
    CreateDirectoryA(dir_path.c_str(), NULL);

    // Re-fetch args since we moved earlier
    std::vector<std::string> args_for_file = GetCommandLineArguments();
    std::ofstream ofs(dir_path + "\\args.txt", std::ios::trunc);
    if (ofs.is_open()) {
      for (const auto& s : args_for_file) {
        ofs << s << "\n";
      }
      ofs.close();
    }
  }

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"portrai_flutter_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
