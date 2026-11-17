/**
 * Self-test for Sunshine's GNOME clipboard + touchpad scrolling service (mutter_rd.cpp), run
 * against the live GNOME session. A helper (pc_app.py) plays a PC application that copies and
 * pastes; this program plays Sunshine serving a Mac client. Exit code = number of failures.
 */
#include "mutter_rd.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <future>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace {
  int failures = 0;
  std::string dir;

  void check(bool ok, const std::string &what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += !ok;
  }

  std::string write_tmp(const std::string &name, const std::string &data) {
    const auto path = dir + "/" + name;
    std::ofstream(path, std::ios::binary) << data;
    return path;
  }

  std::string run(const std::string &cmd) {
    std::string out;
    if (FILE *p = popen(cmd.c_str(), "r")) {
      char buf[1 << 16];
      size_t n;
      while ((n = fread(buf, 1, sizeof buf, p)) > 0) {
        out.append(buf, n);
      }
      pclose(p);
    }
    return out;
  }

  std::string random_bytes(std::size_t n) {
    std::mt19937_64 rng {42};
    std::string s(n, '\0');
    for (auto &c : s) {
      c = static_cast<char>(rng());
    }
    return s;
  }

  /** A PC application copies @p data; returns once it is on the clipboard (keeps serving in the background). */
  void pc_copies(const std::string &helper, const std::string &mime, const std::string &data, double seconds = 4) {
    const auto file = write_tmp("copy.bin", data);
    std::system(("timeout 20 python3 " + helper + " copy '" + mime + "' " + file + " " + std::to_string(seconds) + " &").c_str());
    std::this_thread::sleep_for(1500ms);
  }

  std::string pc_pastes(const std::string &helper, const std::string &mime) {
    return run("timeout 20 python3 " + helper + " read '" + mime + "'");
  }
}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <pc_app.py> <tmpdir>\n", argv[0]);
    return 2;
  }
  const std::string helper = argv[1];
  dir = argv[2];
  const std::string text = "Copied on the PC: héllo ✓ 🙂\nsecond line\ttab";
  const std::string png = "\x89PNG\r\n\x1a\n" + random_bytes(300'000);

  mutter_rd::start();
  std::this_thread::sleep_for(500ms);
  check(mutter_rd::available(), "remote desktop session is running");
  check(!mutter_rd::clipboard_get(), "nothing reported at stream start (old PC clipboard is not news)");

  pc_copies(helper, "text/plain;charset=utf-8", text);
  auto got = mutter_rd::clipboard_get();
  check(got && got->mime == "text/plain;charset=utf-8" && got->data == text, "PC copies text -> client receives it exactly (UTF-8)");

  // Several clients asking at once (Mutter refuses parallel reads; the service serializes them).
  std::vector<std::future<bool>> parallel;
  for (int i = 0; i < 4; ++i) {
    parallel.push_back(std::async(std::launch::async, [&text]() {
      auto c = mutter_rd::clipboard_get();
      return c && c->data == text;
    }));
  }
  bool all = true;
  for (auto &f : parallel) {
    all = all && f.get();
  }
  check(all, "4 parallel fetches all get the full text");
  std::this_thread::sleep_for(3000ms);

  pc_copies(helper, "image/png", png);
  got = mutter_rd::clipboard_get();
  check(got && got->mime == "image/png" && got->data == png, "PC copies a 300 KB PNG -> client receives it byte-identical");
  std::this_thread::sleep_for(3000ms);

  check(mutter_rd::clipboard_set("text/plain;charset=utf-8", "from the Mac ✓"), "client sets text");
  check(pc_pastes(helper, "text/plain;charset=utf-8") == "from the Mac ✓", "PC application pastes the client's text");
  check(pc_pastes(helper, "UTF8_STRING") == "from the Mac ✓", "...also as UTF8_STRING (X11 applications)");
  check(!mutter_rd::clipboard_get(), "client's own content is not echoed back");

  check(mutter_rd::clipboard_set("image/png", png), "client sets a PNG");
  check(pc_pastes(helper, "image/png") == png, "PC application pastes the PNG byte-identical");

  const auto big = random_bytes(8u << 20);
  check(mutter_rd::clipboard_set("text/plain", big), "client sets 8 MiB");
  check(pc_pastes(helper, "text/plain;charset=utf-8") == big, "PC application pastes all 8 MiB");

  check(!mutter_rd::clipboard_set("text/plain", std::string(mutter_rd::MAX_CLIPBOARD_BYTES + 1, 'x')), "over 16 MiB is refused");
  check(!mutter_rd::clipboard_set("application/x-evil", "x"), "unknown content types are refused");

  check(mutter_rd::scroll(0.0, 3.5) && mutter_rd::scroll(-1.25, 0.0), "touchpad scroll deltas are accepted");
  std::this_thread::sleep_for(200ms);  // lets the scroll-finish timer fire

  pc_copies(helper, "text/plain;charset=utf-8", "late copy", 3);
  mutter_rd::stop();
  mutter_rd::start();  // the next stream, within the linger period
  std::this_thread::sleep_for(300ms);
  check(!mutter_rd::clipboard_get(), "a new stream does not receive what was copied before it started");
  mutter_rd::stop();

  std::printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
  return failures;
}
