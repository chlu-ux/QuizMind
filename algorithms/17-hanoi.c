/* ============================================================================
 * 汉诺塔（Tower of Hanoi）—— 递归 / 分治
 * ============================================================================
 * 【问题】 三根柱子 A、B、C，A 上有 n 个大小不同的盘子（大在下、小在上）。
 *          每次只能移动一个盘子，且任何时刻大盘子不能压在小盘子上。
 *          把所有盘子从 A 移到 C（可借助 B）。
 *
 * 【递归思路】 hanoi(n, from, via, to)：
 *   1. 先把上面 n-1 个盘子从 from 借助 to 移到 via；
 *   2. 把第 n 个（最大）盘子从 from 直接移到 to；
 *   3. 再把 via 上的 n-1 个盘子借助 from 移到 to。
 *   递归出口：n == 0 不用移动（或 n == 1 直接移动）。
 *
 * 【复杂度】
 *   移动次数 T(n) = 2T(n-1) + 1，T(0)=0，解得 T(n) = 2^n - 1（指数级）。
 *   递归深度 n，空间 O(n)。
 *   传说 64 个盘子需要 2^64-1 次，按每秒一次约 5800 亿年。
 *
 * 【考点】
 *   ★ 递归函数的书写与"参数顺序"：第一次递归把 via 与 to 互换角色，
 *     第二次递归把 from 与 via 互换角色——填空题常挖这里。
 *   ★ 求移动次数 2^n - 1；给出 n=3 时的完整移动序列（本文件输出）。
 *   ★ 递归的两个要素：递归出口 + 递归式（把问题化为规模更小的同类问题）。
 *   ★ 递归的代价：栈空间、重复计算；对比斐波那契递归的指数级重复计算。
 *   ★ 属于分治 / 递归策略，没有重叠子问题，不适合用动态规划。
 *
 * 【多种实现】
 *   ① 递归（hanoi）；② 非递归（hanoi_iter）：用显式栈保存"待办任务"来模拟递归。
 *   非递归的关键：栈是后进先出，所以要按【相反的顺序】压栈——
 *   想先做 ①、再做 ②、最后做 ③，就先压 ③，再压 ②，最后压 ①。
 *   （另有一种不用栈的解法：奇数步移动最小盘按固定方向循环，偶数步做唯一合法的另一步。）
 * ============================================================================ */
#include "common.h"

static long moves;                          /* 累计移动次数 */
static int verbose;                         /* 是否打印每一步 */

static unsigned long move_hash;             /* 移动序列的哈希，用来比较两种实现 */

static void record_move(int n, char from, char to) {
    moves++;
    move_hash = move_hash * 131 + n * 9 + from * 3 + to;
}

static void hanoi(int n, char from, char via, char to) {
    if (n == 0) return;                      /* 【填空①】递归出口｜递归出口 */
    hanoi(n - 1, from, to, via);             /* 【填空②】上面 n-1 个移到 via：目标柱与辅助柱互换｜① 上面 n-1 个：from -> via（借助 to） */
    if (verbose) printf("move disk %d: %c -> %c\n", n, from, to);
    record_move(n, from, to);                                 /* 【填空③】最大盘 from -> to，移动次数 +1｜② 最大盘：from -> to */
    hanoi(n - 1, via, from, to);             /* 【填空④】n-1 个从 via 移到 to：起点与辅助柱互换｜③ 上面 n-1 个：via -> to（借助 from） */
}

/* ---------------------------------------------------------------------------
 * 非递归版：栈里每个任务要么是"解决 n 个盘的子问题"，要么是"移动一个盘子"。
 * --------------------------------------------------------------------------- */
typedef struct { int n; char from, via, to; int is_move; } Task;

static void hanoi_iter(int n, char from, char via, char to) {
    Task st[64];
    int top = 0;
    st[top++] = (Task){n, from, via, to, 0};
    while (top > 0) {
        Task t = st[--top];
        if (t.n == 0) continue;              /* 对应递归出口 */
        if (t.is_move) {                     /* "移动一个盘子"任务：执行 */
            if (verbose) printf("move disk %d: %c -> %c\n", t.n, t.from, t.to);
            record_move(t.n, t.from, t.to);
            continue;
        }
        /* 展开成三个任务。栈后进先出，所以逆序压入：③ 先压，① 最后压（最先执行） */
        st[top++] = (Task){t.n - 1, t.via, t.from, t.to, 0};   /* 【填空⑤】③ n-1 个：via -> to */
        st[top++] = (Task){t.n, t.from, t.via, t.to, 1};       /* ② 最大盘：from -> to */
        st[top++] = (Task){t.n - 1, t.from, t.to, t.via, 0};   /* 【填空⑥】① n-1 个：from -> via */
    }
}

int main(void) {
    verbose = 1;
    hanoi(3, 'A', 'B', 'C');                 /* 3 个盘需 7 步 */
    CHECK(moves == 7);

    verbose = 0;
    for (int n = 1; n <= 16; n++) {          /* 验证闭式解 T(n) = 2^n - 1 */
        moves = 0;
        hanoi(n, 'A', 'B', 'C');
        CHECK(moves == (1L << n) - 1);
    }
    printf("moves(n) = 2^n - 1 verified for n=1..16\n");
    /* 非递归版：移动序列必须与递归版逐步一致（用序列哈希比较） */
    for (int k = 1; k <= 12; k++) {
        moves = 0; move_hash = 0;
        hanoi(k, 'A', 'B', 'C');
        long m1 = moves; unsigned long h1 = move_hash;
        moves = 0; move_hash = 0;
        hanoi_iter(k, 'A', 'B', 'C');
        CHECK(moves == m1 && move_hash == h1);
    }
    printf("iterative version produces the identical move sequence\n");
    return 0;
}
