// rootprobe.c — 方案A 阶段1/2 的极简 root 探针。
// 由 Kline 以 persona 99 + uid0 spawnRoot 启动。用退出码表达结果：
//   0 = 拿到了 root（getuid/egid 均为 0）
//   1 = 未拿到 root
// 用退出码而非 stdout，彻底绕开管道采集，判定最稳定可靠。
#include <unistd.h>

int main(void) {
    return (getuid() == 0 && geteuid() == 0) ? 0 : 1;
}