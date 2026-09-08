// rootprobe.c — 方案A 阶段1/2 的极简 root 探针。
// 由 Kline 以 persona 99 + uid0 spawnRoot 启动，自身打印 getuid/getgid，
// 用于在 iOS（无 /usr/bin/id 等用户态 CLI）上显式确认是否真拿到了 root。
// 后续可扩展为真正的 trollstorehelper（install 子命令）。
#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("UID=%d GID=%d EUID=%d\n",
           (int)getuid(), (int)getgid(), (int)geteuid());
    fflush(stdout);
    return 0;
}