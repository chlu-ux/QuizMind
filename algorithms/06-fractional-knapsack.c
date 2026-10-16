/* ============================================================================
 * 部分背包（分数背包）问题 —— 贪心法（Greedy）
 * ============================================================================
 * 【问题】 与 0-1 背包相同，但物品可以拆分，取走一部分按比例计算价值。
 *
 * 【贪心策略】 按单位重量价值 v/w 从大到小排序，依次整件装入；
 *              装不下的那一件按剩余容量取一部分，然后结束。
 *
 * 【贪心法的两大性质 —— 必背】
 *   1. 贪心选择性质：局部最优选择能导出全局最优解（可以做出选择后再解子问题）；
 *   2. 最优子结构：同动态规划。
 *   贪心法"自顶向下"、不回溯；动态规划"自底向上"、会比较各子问题。
 *
 * 【复杂度】 排序 O(n log n)，扫描 O(n)，总体 O(n log n)。
 *
 * 【考点】
 *   ★ 部分背包用贪心是最优的；0-1 背包用同样的贪心【不一定】最优，必须用动态规划。
 *     下面 main 里用同一组数据演示：贪心在 0-1 背包上只得 160，最优是 220。
 *   ★ 常见贪心问题：哈夫曼编码、活动安排、最小生成树（Prim/Kruskal）、
 *     Dijkstra 最短路径、部分背包、找零钱（面额特殊时）。
 *   ★ 判断一道题该用贪心还是动态规划：能证明"每步取局部最优不会后悔"用贪心，
 *     否则（需要考虑各种组合）用动态规划。
 * ============================================================================ */
#include "common.h"

typedef struct { double w, v; } Item;

/* qsort 比较函数：按 v/w 降序。 */
static int cmp(const void *x, const void *y) {
    const Item *a = x, *b = y;
    double ra = a->v / a->w, rb = b->v / b->w;
    return (ra < rb) - (ra > rb);  /* 【填空①】按单位价值 v/w 降序排序的比较函数 */
}

static double fractional_knapsack(Item items[], int n, double cap) {
    qsort(items, n, sizeof items[0], cmp);
    double total = 0;
    for (int i = 0; i < n && cap > 0; i++) {
        if (items[i].w <= cap) {             /* 【填空②】整件装得下就全拿，并扣减剩余容量｜整件装得下：全拿 */
            cap -= items[i].w;
            total += items[i].v;
        } else {                             /* 装不下：按比例拿一部分，背包装满 */
            total += items[i].v * (cap / items[i].w);  /* 【填空③】装不下：按剩余容量比例取一部分 */
            cap = 0;
        }
    }
    return total;
}

/* 反例演示：对 0-1 背包照搬同样的贪心（按 v/w 降序，装不下就跳过） */
static double greedy_for_01(Item items[], int n, double cap) {
    qsort(items, n, sizeof items[0], cmp);
    double total = 0;
    for (int i = 0; i < n; i++)
        if (items[i].w <= cap) { cap -= items[i].w; total += items[i].v; }
    return total;
}

int main(void) {
    /* 物品 (重量, 价值)，单价依次 6、5、4；容量 50 */
    Item a[] = {{10, 60}, {20, 100}, {30, 120}};
    double best = fractional_knapsack(a, 3, 50);
    printf("fractional: %.1f  (10+20 全拿 + 第三件的 20/30)\n", best);
    CHECK(best > 239.99 && best < 240.01);   /* 60 + 100 + 120*(20/30) = 240 */

    Item b[] = {{10, 60}, {20, 100}, {30, 120}};
    double g = greedy_for_01(b, 3, 50);
    printf("greedy on 0-1: %.1f  (true optimum is 220)\n", g);
    CHECK(g > 159.99 && g < 160.01);         /* 只能装 1、2 号，浪费 20 容量 => 160 < 220 */
    return 0;
}
