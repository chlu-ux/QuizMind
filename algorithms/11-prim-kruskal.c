/* ============================================================================
 * 最小生成树 MST（Minimum Spanning Tree）—— 贪心法：Prim 与 Kruskal
 * ============================================================================
 * 【概念】 连通无向带权图的生成树 = 包含所有 n 个顶点、恰好 n-1 条边、无回路的子图；
 *          边权之和最小者为最小生成树。MST 的权值唯一，但树的形态可能不唯一
 *          （当存在权值相同的边时）；若所有边权互不相同，则 MST 唯一。
 *
 * 【Prim 算法 —— 加点法】
 *   从任一顶点出发，每次选择"一端在树内、一端在树外"的权值最小的边，把树外端点加入。
 *   用 lowcost[i] 记录树外顶点 i 到树的最小边权，closest[i] 记录对应的树内顶点。
 *   邻接矩阵 O(n^2)，与边数无关 => 适合【稠密图】。
 *
 * 【Kruskal 算法 —— 加边法】
 *   把所有边按权值升序排列，依次考察：若这条边连接的是两个不同的连通分量就选中，
 *   否则会形成回路就舍弃；直到选够 n-1 条边。用【并查集】判断是否同属一个连通分量。
 *   时间 O(e log e)（排序为主） => 适合【稀疏图】。
 *
 * 【考点】
 *   ★ 手工模拟：给出图，写出 Prim（从某点出发）/ Kruskal 选边的先后顺序及 MST 权值。
 *     两种算法选边顺序不同，但总权值相同（如本例：Prim 先选 (0,1)，Kruskal 先选 (2,5)）。
 *   ★ 稠密图选 Prim，稀疏图选 Kruskal（常考选择题）。
 *   ★ 贪心依据：割性质（跨越割的最小边必在某棵 MST 中）；回路性质。
 *   ★ MST 不要求从某个顶点出发的路径最短——那是 Dijkstra 要解决的，别混淆。
 *   ★ 破圈法、避圈法：避圈法就是 Kruskal，破圈法是不断删去回路中最大边。
 * ============================================================================ */
#include "common.h"

#define N 6
#define INF 1000000

typedef struct { int u, v, w; } Edge;

/* ---------------------------- Prim ---------------------------- */
static int prim(int g[N][N]) {
    int lowcost[N], closest[N], total = 0;

    /* 从顶点 0 出发。lowcost[i]=0 表示 i 已在树中 */
    for (int i = 1; i < N; i++) { lowcost[i] = g[0][i]; closest[i] = 0; }
    lowcost[0] = 0;

    for (int round = 1; round < N; round++) {   /* 要加入 N-1 个顶点 */
        int k = -1;
        for (int i = 1; i < N; i++)             /* 找树外离树最近的顶点 */
            if (lowcost[i] != 0 && (k == -1 || lowcost[i] < lowcost[k])) k = i;  /* 【填空①】Prim：在树外顶点中选 lowcost 最小者 */
        printf("Prim: edge (%d,%d) w=%d\n", closest[k], k, lowcost[k]);
        total += lowcost[k];
        lowcost[k] = 0;                         /* k 加入树 */
        for (int i = 1; i < N; i++)             /* 用 k 更新树外各点的 lowcost */
            if (lowcost[i] != 0 && g[k][i] < lowcost[i]) {  /* 【填空②】Prim：新顶点 k 入树后更新 lowcost 与 closest */
                lowcost[i] = g[k][i];
                closest[i] = k;
            }
    }
    return total;
}

/* ---------------------------- Kruskal ---------------------------- */
/* 并查集 find：带路径压缩（路径减半），近似 O(1) */
static int find(int parent[], int x) {
    while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }  /* 【填空③】并查集 find：一直向上找到根 */
    return x;
}

static int cmp_edge(const void *a, const void *b) {
    return ((const Edge *)a)->w - ((const Edge *)b)->w;   /* 权值升序 */
}

static int kruskal(Edge edges[], int e) {
    int parent[N], total = 0, picked = 0;
    for (int i = 0; i < N; i++) parent[i] = i;  /* 每个顶点自成一个连通分量 */
    qsort(edges, e, sizeof edges[0], cmp_edge);

    for (int i = 0; i < e && picked < N - 1; i++) {
        int ru = find(parent, edges[i].u), rv = find(parent, edges[i].v);
        if (ru == rv) continue;                 /* 【填空④】Kruskal：两端点根相同则成环，舍弃该边｜同一分量：选了会成环，舍弃 */
        parent[ru] = rv;                        /* 【填空⑤】Kruskal：合并两个连通分量｜合并两个分量 */
        printf("Kruskal: edge (%d,%d) w=%d\n", edges[i].u, edges[i].v, edges[i].w);
        total += edges[i].w;
        picked++;
    }
    return total;
}

int main(void) {
    Edge edges[] = {{0, 1, 7}, {0, 2, 9}, {0, 5, 14}, {1, 2, 10}, {1, 3, 15},
                    {2, 3, 11}, {2, 5, 2}, {3, 4, 6}, {4, 5, 9}};
    int e = sizeof edges / sizeof edges[0];

    int g[N][N];
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) g[i][j] = INF;
    for (int k = 0; k < e; k++)
        g[edges[k].u][edges[k].v] = g[edges[k].v][edges[k].u] = edges[k].w;

    int tp = prim(g);
    int tk = kruskal(edges, e);
    printf("MST weight: prim=%d kruskal=%d\n", tp, tk);
    CHECK(tp == 33);                         /* 2+6+7+9+9 */
    CHECK(tk == 33);                         /* 两种算法权值必须一致 */
    return 0;
}
