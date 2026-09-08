// opener.c — 方案A「装完自动打开新版」的 root 守护进程。
// 由 Kline 在触发 TrollStore 安装前以 root spawn，独立于 App 生命周期存活
// （安装会终止 Kline，opener 不受影响）。职责：
//   1) 记下传入的"当前版本" argv[1]；
//   2) 每 1s 轮询已安装的 Kline bundle 的 CFBundleVersion；
//   3) 一旦发现版本高于当前（=新版已装好）→ 以 root posix_spawn 新版 Kline 可执行；
//   4) 拉起成功立刻退出；超时(maxWait, 默认90s)仍无更新则自退，绝非常驻。
#include <CoreFoundation/CoreFoundation.h>
#include <spawn.h>
#include <glob.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

extern char **environ;

static long parseVersion(CFStringRef v) {
    char s[32] = {0};
    if (!CFStringGetCString(v, s, sizeof s, kCFStringEncodingUTF8)) return 0;
    return strtol(s, NULL, 10);
}

int main(int argc, char **argv) {
    long cur = (argc > 1) ? strtol(argv[1], NULL, 10) : 0;
    int maxWait = (argc > 2) ? atoi(argv[2]) : 90;
    const char *PATTERN = "/private/var/containers/Bundle/Application/*/Kline.app/Info.plist";

    int waited = 0;
    for (;;) {
        glob_t g;
        memset(&g, 0, sizeof g);
        if (glob(PATTERN, 0, NULL, &g) == 0) {
            for (size_t i = 0; i < g.gl_pathc; i++) {
                const char *p = g.gl_pathv[i];
                const char *bundlePath = "<none>";
                CFStringRef pathStr = CFStringCreateWithCString(kCFAllocatorDefault, p, kCFStringEncodingUTF8);
                CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, pathStr,
                                                             kCFURLPOSIXPathStyle, false);
                CFReadStreamRef rs = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
                if (rs && CFReadStreamOpen(rs)) {
                    CFPropertyListRef pl = CFPropertyListCreateWithStream(kCFAllocatorDefault, rs, 0,
                                                                          kCFPropertyListImmutable, NULL, NULL);
                    if (pl) {
                        CFStringRef bid = (CFStringRef)CFDictionaryGetValue((CFDictionaryRef)pl,
                                                                            CFSTR("CFBundleIdentifier"));
                        CFStringRef ver = (CFStringRef)CFDictionaryGetValue((CFDictionaryRef)pl,
                                                                            CFSTR("CFBundleVersion"));
                        if (bid && ver &&
                            CFStringCompare(bid, CFSTR("com.sunck.Kline"), 0) == kCFCompareEqualTo) {
                            long v = parseVersion(ver);
                            if (v > cur) {
                                // bundle 目录 = 去掉 /Info.plist：.../Kline.app；可执行 = .../Kline
                                char dir[4096];
                                snprintf(dir, sizeof dir, "%s", p);
                                char *slash = strrchr(dir, '/');
                                if (slash) *slash = 0; // 去掉 /Info.plist → .../Kline.app
                                char exe[4200];
                                snprintf(exe, sizeof exe, "%s/Kline", dir);
                                char brandNewVer[32]; snprintf(brandNewVer, sizeof brandNewVer, "%ld", v);
                                char *av[] = { exe, brandNewVer, NULL };
                                pid_t pid = 0;
                                int sr = posix_spawn(&pid, exe, NULL, NULL, av, environ);
                                // 无论成败都结束 opener（不常驻）。拉起成功即达成使命。
                                (void)sr; (void)bundlePath; (void)brandNewVer;
                                return sr == 0 ? 0 : 2;
                            }
                        }
                        CFRelease(pl);
                    }
                    CFReadStreamClose(rs);
                    CFRelease(rs);
                }
                CFRelease(url);
                CFRelease(pathStr);
            }
        }
        globfree(&g);
        if (++waited >= maxWait) break;
        sleep(1);
    }
    return 1;
}