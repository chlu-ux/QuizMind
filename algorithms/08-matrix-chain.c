/* ============================================================================
 * 矩阵连乘问题 —— 动态规划
 * ============================================================================
 * 【问题】 n 个矩阵 A1 A2 ... An 连乘，A_i 的维度为 p[i-1] x p[i]。
 *          矩阵乘法满足结合律，不同的加括号方式标量乘法次数差别很大，求最少次数。
 *          例：A(10x100) B(100x5) C(5x50)：
 *              (AB)C = 10*100*5 + 10*5*50  = 7500 次
 *              A(BC) = 100*5*50 + 10*100*50 = 75000 次
 *          维度为 p x q 的矩阵与 q x r 的矩阵相乘，需要 p*q*r 次标量乘法。
 *
 * 【递推式】 m[i][j] = 计算 A_i ... A_j 的最少乘法次数
 *     m[i][j] = 0                                                , i = j
 *             = min_{i<=k<j} ( m[i][k] + m[k+1][j] + p[i-1]*p[k]*p[j] ) , i < j
 *   其中 k 是最后一次断开的位置：(A_i..A_k)(A_{k+1}..A_j)，最后合并两个结果矩阵
 *   的代价是 p[i-1]*p[k]*p[j]。s[i][j] 记录取得最小值的 k，用于还原括号方案。
 *
 * 【填表顺序 ★】 按链长 len = 2,3,...,n（即按"对角线"）填，
 *                因为 m[i][j] 依赖更短的 m[i][k] 与 m[k+1][j]。
 *
 * 【复杂度】 时间 O(n^3)（三重循环：链长、起点、断点），空间 O(n^2)。
 *            暴力枚举所有加括号方式是卡特兰数，指数级。
 *
 * 【考点】
 *   ★ 写出递推式、填 m 表和 s 表、写出最优括号化方案（真题给 4~6 个矩阵）。
 *   ★ 三重 for 循环的位置：for len / for i / for k，填空题常挖这几处。
 *   ★ 递归（不带备忘）求解的时间是指数级；加备忘录或自底向上才是 O(n^3)。
 *   ★ 满足最优子结构 + 子问题重叠，所以是动态规划而非分治。
 *
 * 【多种实现】
 *   ① 自底向上填表（matrix_chain）；② 自顶向下备忘录递归（lookup_chain）。
 *   不加备忘录的递归时间 Ω(2^n)；加备忘录后每个 m[i][j] 只算一次，O(n^3)。
 * ============================================================================ */
#include "common.h"

#define N 6

static int m[N + 1][N + 1], s[N + 1][N + 1];  /* 下标从 1 开始使用 */

static void matrix_chain(const int p[]) {
    /* m[i][i] = 0 已由静态存储区清零 */
    for (int len = 2; len <= N; len++)            /* 【填空①】最外层按链长递增（对角线）填表｜链长：2..N */
        for (int i = 1; i + len - 1 <= N; i++) {  /* 起点 i，终点 j = i+len-1 */
            int j = i + len - 1;
            m[i][j] = 1 << 30;                    /* 先设为"无穷大" */
            for (int k = i; k < j; k++) {         /* 尝试在 k 处断开 */
                int cost = m[i][k] + m[k + 1][j] + p[i - 1] * p[k] * p[j];  /* 【填空②】递推式：左段 + 右段 + 合并代价 p[i-1]*p[k]*p[j] */
                if (cost < m[i][j]) { m[i][j] = cost; s[i][j] = k; }  /* 【填空③】取最小并用 s 记录断点 k */
            }
        }
}

/* 根据 s 表递归输出最优括号化方案 */
static void print_parens(int i, int j) {
    if (i == j) { printf("A%d", i); return; }
    printf("(");
    print_parens(i, s[i][j]);
    print_parens(s[i][j] + 1, j);  /* 【填空④】按 s 表递归输出括号：左 [i,k]，右 [k+1,j] */
    printf(")");
}

/* ---------------------------------------------------------------------------
 * 备忘录递归（算法导论 LOOKUP-CHAIN）：memo[i][j] = -1 表示还没算。
 * --------------------------------------------------------------------------- */
static int memo[N + 1][N + 1];

static int lookup_chain(const int p[], int i, int j) {
    if (memo[i][j] >= 0) return memo[i][j];  /* 【填空⑤】已算过：直接返回 */
    if (i == j) return memo[i][j] = 0;       /* 单个矩阵不需要乘 */
    int best = 1 << 30;
    for (int k = i; k < j; k++) {
        int q = lookup_chain(p, i, k) + lookup_chain(p, k + 1, j) + p[i - 1] * p[k] * p[j];
        if (q < best) best = q;              /* 【填空⑥】在所有断点 k 中取最小 */
    }
    return memo[i][j] = best;
}

static int matrix_chain_memo(const int p[]) {
    for (int i = 0; i <= N; i++)
        for (int j = 0; j <= N; j++) memo[i][j] = -1;
    return lookup_chain(p, 1, N);
}

int main(void) {
    /* 6 个矩阵：A1=30x35, A2=35x15, A3=15x5, A4=5x10, A5=10x20, A6=20x25 */
    int p[N + 1] = {30, 35, 15, 5, 10, 20, 25};
    matrix_chain(p);
    printf("min multiplications = %d\norder: ", m[1][N]);
    print_parens(1, N);
    printf("\n");
    CHECK(m[1][N] == 15125);
    CHECK(m[2][3] == 35 * 15 * 5);                /* 两个矩阵直接相乘 */
    CHECK(matrix_chain_memo(p) == 15125);    /* 备忘录递归与填表结果一致 */
    return 0;
}
