// opener.m — 方案A「装完自动打开新版」的 root daemon。
// 由 Kline 触发安装前以 root spawn，独立于 App 生命周期（安装会终止 Kline，opener 不受影响）。
//   1) 记下当前版 argv[1]；等待窗口 argv[2]（秒，默认 90）；
//      额外日志路径 argv[3]（可选，App 沙盒 Documents，便于事后排查）；
//   2) 每 1s 轮询已装 Kline bundle 的 CFBundleVersion；
//   3) 发现"与当前不同"的版本后，**下一轮再确认一次**才打开（避开安装中间态）：
//      用 LSApplicationWorkspace openApplicationWithBundleID:
//      把新版 Kline 带到前台（裸 posix_spawn 可执行无法让 UI 前台显示，须走 LaunchServices）；
//   4) 成功即退出；超时(maxWait)自退，绝非常驻。
// 日志：追加到 /private/var/tmp/opener.log（root 可写；Kline no-sandbox 可读），
//      若给了 argv[3] 则同写一份到 App 沙盒（跨版本升级后容器路径不变，便于回看）。
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <glob.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <dirent.h>

#define LOG_PATH "/private/var/tmp/opener.log"

// py 模式的 Python C API 函数指针（dlsym 取用，版本无关）
typedef void (*VoidFnInit)(void);
typedef int (*VoidFnRun)(const char *);

// cp 模式：iOS 无 cp 命令（/bin/cp、/usr/bin/cp 均不存在，2026-10-04 实证），
// 递归拷贝用纯 C 实现（目录/普通文件/符号链接）
static int copyRec(const char *src, const char *dst);   // 前置声明（递归）

static char gExtraLog[1024] = {0};   // argv[3]：额外日志文件（App 沙盒），空 = 不写

static void logmsg(const char *s);   // 前置声明：loadLSFrameworks 在其定义前调用

// LSApplicationWorkspace 在私有框架 LaunchServices/CoreServices 里，
// 且该类只在进程内"已加载的镜像"中存在——opener 只链了 Foundation/CoreFoundation，
// 故 NSClassFromString 找不到。这里在启动时 dlopen 候选框架，把该类拉进进程。
static void loadLSFrameworks(void) {
    const char *candidates[] = {
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices",
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        if (dlopen(candidates[i], RTLD_NOW)) {
            char log[256]; snprintf(log, sizeof log, "dlopen OK: %s", candidates[i]); logmsg(log);
        }
    }
}

static void logmsg(const char *s) {
    FILE *f = fopen(LOG_PATH, "a");
    if (f) { fprintf(f, "%s\n", s); fclose(f); }
    if (gExtraLog[0]) {
        FILE *g = fopen(gExtraLog, "a");
        if (g) { fprintf(g, "%s\n", s); fclose(g); }
    }
}

static long parseVersion(CFStringRef v) {
    char b[32] = {0};
    if (!CFStringGetCString(v, b, sizeof b, kCFStringEncodingUTF8)) return 0;
    return strtol(b, NULL, 10);
}

// 经 LaunchServices 打开前台（root 下有效），替代裸 posix_spawn
static int openApp(const char *bundleID) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    Class LSWS = NSClassFromString(@"LSApplicationWorkspace");
    if (!LSWS) { logmsg("LSApplicationWorkspace class NOT found"); [pool drain]; return -1; }
    id ws = [LSWS performSelector:NSSelectorFromString(@"defaultWorkspace")];
    if (!ws) { logmsg("defaultWorkspace nil"); [pool drain]; return -2; }
    NSString *bid = [NSString stringWithUTF8String:bundleID];
    BOOL ok = (BOOL)[ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bid];
    char log[256]; snprintf(log, sizeof log, "openApplicationWithBundleID:%s -> %d", [bid UTF8String], (int)ok); logmsg(log);
    [pool drain];
    return ok ? 0 : -3;
}

// py 模式：opener 已被证明可 exec（Kline.app 内受信二进制），而 Engine.app 内的
// 二进制 exec 会被 AMFI SIGKILL（2026-10-04 实证）——故 Python 子进程隔离借道 opener：
//   opener --py <dylibPath> <home> <scriptPath> <outPath> [stderrPath]
// 流程：stderr 重定向（可选）→ setenv PYTHONHOME → dlopen Engine.app 内 libpython
//       → Py_Initialize → PyRun_SimpleString(脚本文件) → 退出码 0=成功
// 脚本自己把结果写到 outPath（__kline_out__ 约定）；fatal abort 的死前信息落 stderrPath。
static int runPyMode(int argc, char **argv) {
    if (argc < 6) { logmsg("py mode: argc<6"); return 3; }
    const char *dylib = argv[2], *home = argv[3], *script = argv[4], *out = argv[5];
    if (argc >= 7) {
        FILE *se = fopen(argv[6], "a");
        if (se) { dup2(fileno(se), 2); fclose(se); }
    }
    char log[512];
    setenv("PYTHONHOME", home, 1);
    snprintf(log, sizeof log, "py mode: PYTHONHOME=%s dylib=%s", home, dylib); logmsg(log);
    void *h = dlopen(dylib, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        snprintf(log, sizeof log, "py mode dlopen fail: %s", dlerror()); logmsg(log);
        return 4;
    }
    VoidFnInit init = (VoidFnInit)dlsym(h, "Py_Initialize");
    VoidFnRun run = (VoidFnRun)dlsym(h, "PyRun_SimpleString");
    if (!init || !run) { logmsg("py mode dlsym fail"); return 5; }
    init();
    FILE *f = fopen(script, "r");
    if (!f) { logmsg("py mode script open fail"); return 6; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { if (buf) free(buf); fclose(f); logmsg("py mode script read fail"); return 7; }
    buf[n] = 0; fclose(f);
    int rc = run(buf);
    free(buf);
    snprintf(log, sizeof log, "py mode PyRun rc=%d", rc); logmsg(log);
    return rc;
}

static int copyRec(const char *src, const char *dst) {
    struct stat st;
    if (lstat(src, &st) != 0) return -1;
    if (S_ISDIR(st.st_mode)) {
        mkdir(dst, 0755);
        DIR *d = opendir(src);
        if (!d) return -2;
        struct dirent *e;
        int rc = 0;
        while ((e = readdir(d)) != NULL) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char *s2 = (char *)malloc(strlen(src) + strlen(e->d_name) + 2);
            char *d2 = (char *)malloc(strlen(dst) + strlen(e->d_name) + 2);
            if (!s2 || !d2) { free(s2); free(d2); closedir(d); return -8; }
            sprintf(s2, "%s/%s", src, e->d_name);
            sprintf(d2, "%s/%s", dst, e->d_name);
            int r = copyRec(s2, d2);
            free(s2); free(d2);
            if (r != 0) { rc = r; break; }
        }
        closedir(d);
        return rc;
    }
    if (S_ISLNK(st.st_mode)) {
        char target[1024];
        ssize_t n = readlink(src, target, sizeof target - 1);
        if (n < 0) return -3;
        target[n] = 0;
        unlink(dst);
        return symlink(target, dst) != 0 ? -4 : 0;
    }
    FILE *a = fopen(src, "rb");
    if (!a) return -5;
    FILE *b = fopen(dst, "wb");
    if (!b) { fclose(a); return -6; }
    char buf[65536];
    size_t r;
    int rc = 0;
    while ((r = fread(buf, 1, sizeof buf, a)) > 0) {
        if (fwrite(buf, 1, r, b) != r) { rc = -7; break; }
    }
    fclose(a); fclose(b);
    chmod(dst, st.st_mode & 07777);
    return rc;
}

int main(int argc, char **argv) {
    // cp 模式分发：opener --cp <src> <dst>（递归拷贝，root 权限读 CrashReporter 等）
    if (argc >= 2 && strcmp(argv[1], "--cp") == 0) {
        if (argc < 4) { logmsg("cp mode: argc<4"); return 3; }
        return copyRec(argv[2], argv[3]);
    }
    // py 模式分发：不涉及 LaunchServices/更新守护，直接执行并返回
    if (argc >= 2 && strcmp(argv[1], "--py") == 0) {
        return runPyMode(argc, argv);
    }
    // 小结：用 autoreleasepool 包裹主逻辑，避免 ObjC 泄漏
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    loadLSFrameworks();   // 先 dlopen 私有框架，保证 NSClassFromString 能找到 LSApplicationWorkspace
    long cur = (argc > 1) ? strtol(argv[1], NULL, 10) : 0;
    int maxWait = (argc > 2) ? atoi(argv[2]) : 90;
    if (argc > 3) { snprintf(gExtraLog, sizeof gExtraLog, "%s", argv[3]); }
    const char *PATTERN = "/private/var/containers/Bundle/Application/*/Kline.app/Info.plist";
    char log[256];
    snprintf(log, sizeof log, "opener start cur=%ld maxWait=%d extraLog=%s",
             cur, maxWait, gExtraLog[0] ? gExtraLog : "(none)");
    logmsg(log);

    int pendingConfirm = 0;   // 上一轮已见到"版本不同"，本轮再确认一次才真正打开
    int waited = 0;
    for (;;) {
        glob_t g; memset(&g, 0, sizeof g);
        int sawDifferent = 0;
        if (glob(PATTERN, 0, NULL, &g) == 0) {
            for (size_t i = 0; i < g.gl_pathc; i++) {
                const char *p = g.gl_pathv[i];
                CFStringRef ps = CFStringCreateWithCString(kCFAllocatorDefault, p, kCFStringEncodingUTF8);
                CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, ps, kCFURLPOSIXPathStyle, false);
                CFReadStreamRef rs = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
                if (rs && CFReadStreamOpen(rs)) {
                    CFPropertyListRef pl = CFPropertyListCreateWithStream(kCFAllocatorDefault, rs, 0,
                                                                          kCFPropertyListImmutable, NULL, NULL);
                    if (pl) {
                        CFStringRef bid = (CFStringRef)CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR("CFBundleIdentifier"));
                        CFStringRef ver = (CFStringRef)CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR("CFBundleVersion"));
                        if (bid && ver && CFStringCompare(bid, CFSTR("com.sunck.Kline"), 0) == kCFCompareEqualTo) {
                            long v = parseVersion(ver);
                            // 判定：只要是"与当前已装版本不同的 Kline"安装（不必更高），即可打开。
                            // 避免为了触发生成一堆递增版本号。
                            if (v != cur) {
                                sawDifferent = 1;
                                if (pendingConfirm) {
                                    snprintf(log, sizeof log, "new version confirmed (v=%ld cur=%ld) -> open", v, cur);
                                    logmsg(log);
                                    int r = openApp("com.sunck.Kline");
                                    snprintf(log, sizeof log, "open ret=%d", r); logmsg(log);
                                    CFReadStreamClose(rs); CFRelease(rs);
                                    CFRelease(url); CFRelease(ps); CFRelease(pl);
                                    globfree(&g);
                                    [pool drain];
                                    return r == 0 ? 0 : 3;
                                }
                                snprintf(log, sizeof log, "new version detected (v=%ld cur=%ld) -> confirm next tick", v, cur);
                                logmsg(log);
                            }
                        }
                        CFRelease(pl);
                    }
                    CFReadStreamClose(rs); CFRelease(rs);
                }
                CFRelease(url); CFRelease(ps);
            }
        }
        globfree(&g);
        // 只有"连续两轮都看到版本不同"才打开：安装过程中可能出现瞬时读数，提前打开会烧掉唯一的守护
        if (!sawDifferent && pendingConfirm) { logmsg("version reverted -> wait again"); }
        pendingConfirm = sawDifferent;
        if (++waited >= maxWait) break;
        sleep(1);
    }
    snprintf(log, sizeof log, "opener timeout after %ds (cur=%ld)", maxWait, cur);
    logmsg(log);
    [pool drain];
    return 1;
}