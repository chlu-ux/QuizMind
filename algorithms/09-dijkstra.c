/* ============================================================================
 * Dijkstra 单源最短路径 —— 贪心法
 * ============================================================================
 * 【问题】 带权图中，求从源点 src 到其余各顶点的最短路径。
 *
 * 【算法思想】 维护已确定最短路径的顶点集合 S（初始只有 src）和 dist[] 数组：
 *   1. 从不在 S 中的顶点里选 dist 最小的顶点 u（贪心选择），加入 S；
 *   2. 用 u 去"松弛"其余顶点 v：若 dist[u] + w(u,v) < dist[v]，则更新 dist[v]，
 *      并记录前驱 prev[v] = u；
 *   3. 重复直到所有顶点都进入 S。
 *   路径用 prev[] 从终点往回追溯得到。
 *
 * 【复杂度】
 *   - 邻接矩阵：O(n^2)（本代码）
 *   - 邻接表 + 小顶堆(优先队列)：O((n+e) log n)
 *   - 空间 O(n)（不含图本身）
 *
 * 【考点】
 *   ★ 前提：边权必须非负！有负权边时贪心性质不成立，要用 Bellman-Ford。
 *   ★ 手工模拟：给出图，让你写出每一轮选中的顶点、dist 数组的变化、最终路径。
 *     注意"加入 S 的顺序"是按最短距离从小到大的（本例顺序 0,1,2,5,3/4 ...）。
 *   ★ 与 Prim 的对比：二者结构几乎一样，都是"每次选离集合最近的顶点"。
 *     区别在于 Prim 比较的是"到集合内任一点的最小边权"，
 *     Dijkstra 比较的是"到源点的累计距离 dist"。
 *   ★ 与 Floyd 的对比：Dijkstra 单源；Floyd 求所有点对；
 *     对每个点都跑一次 Dijkstra 也是 O(n^3)。
 *   ★ 单源最短路径是"贪心"，Floyd 是"动态规划"——常考的归类题。
 * ============================================================================ */
#include "common.h"

#define N 6
#define INF 1000000                         /* 表示"无直接边"；足够大又不会加法溢出 */

static void dijkstra(int g[N][N], int src, int dist[], int prev[]) {
    int done[N] = {0};                      /* done[i]=1 表示 i 已在集合 S 中 */

    /* 初始化：dist 取源点到各点的直接距离 */
    for (int i = 0; i < N; i++) {
        dist[i] = g[src][i];
        prev[i] = (g[src][i] < INF) ? src : -1;
    }
    dist[src] = 0;
    done[src] = 1;

    for (int round = 1; round < N; round++) {  /* 其余 N-1 个顶点，每轮确定一个 */
        int u = -1;
        for (int i = 0; i < N; i++)            /* 贪心：选未确定顶点中 dist 最小者 */
            if (!done[i] && (u == -1 || dist[i] < dist[u])) u = i;  /* 【填空①】贪心：从未确定顶点中选 dist 最小者 */
        done[u] = 1;

        for (int v = 0; v < N; v++)            /* 松弛：经 u 中转是否更近 */
            if (!done[v] && g[u][v] < INF && dist[u] + g[u][v] < dist[v]) {  /* 【填空②】松弛条件：经 u 中转更近 */
                dist[v] = dist[u] + g[u][v];
                prev[v] = u;  /* 【填空③】松弛成功同时记录前驱，用于还原路径 */
            }
    }
}

/* 递归输出 src 到 v 的路径 */
static void print_path(const int prev[], int src, int v) {
    if (v == src) { printf("%d", v); return; }
    print_path(prev, src, prev[v]);  /* 【填空④】沿前驱递归回到源点，再顺序输出路径 */
    printf(" -> %d", v);
}

int main(void) {
    int g[N][N];
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) g[i][j] = (i == j) ? 0 : INF;
    /* 教材经典图（无向）：{顶点u, 顶点v, 权} */
    int edges[][3] = {{0, 1, 7}, {0, 2, 9}, {0, 5, 14}, {1, 2, 10}, {1, 3, 15},
                      {2, 3, 11}, {2, 5, 2}, {3, 4, 6}, {4, 5, 9}};
    for (unsigned k = 0; k < sizeof edges / sizeof edges[0]; k++) {
        g[edges[k][0]][edges[k][1]] = edges[k][2];
        g[edges[k][1]][edges[k][0]] = edges[k][2]; /* 无向图：矩阵对称 */
    }

    int dist[N], prev[N];
    dijkstra(g, 0, dist, prev);
    print_array("dist from 0", dist, N);
    printf("path to 4: ");
    print_path(prev, 0, 4);                  /* 0->2->5->4，总长 9+2+9=20 */
    printf("\n");

    int expect[N] = {0, 7, 9, 20, 20, 11};
    for (int i = 0; i < N; i++) CHECK(dist[i] == expect[i]);
    CHECK(prev[4] == 5 && prev[5] == 2 && prev[2] == 0);
    return 0;
}
