/* ============================================================================
 * 最长公共子序列 LCS（Longest Common Subsequence）—— 动态规划
 * ============================================================================
 * 【概念辨析 ★】
 *   子序列：从原序列中删掉若干元素（不要求连续），保持相对顺序。
 *   子串  ：必须连续。LCS 是"子序列"，不是"最长公共子串"。
 *   例：X=ABCBDAB，Y=BDCABA，LCS 长度为 4，如 BCBA / BDAB / BCAB。LCS 不唯一。
 *
 * 【递推式】 c[i][j] = X 前 i 个字符与 Y 前 j 个字符的 LCS 长度
 *     c[i][j] = 0                              , i = 0 或 j = 0
 *             = c[i-1][j-1] + 1                , i,j > 0 且 x[i] == y[j]
 *             = max( c[i-1][j], c[i][j-1] )    , i,j > 0 且 x[i] != y[j]
 *
 * 【复杂度】 时间 O(m*n)，空间 O(m*n)；只求长度时可压缩到 O(min(m,n))，
 *            要构造具体序列则需保留整张表（或额外的方向表 b[i][j]）。
 *
 * 【考点】
 *   ★ 写出递推式；按行（或按列）填表；从 c[m][n] 回溯得到一个 LCS。
 *   ★ 最优子结构：LCS(X,Y) 的末尾若 x_m == y_n，则它们必在 LCS 里，
 *     且前面部分是 LCS(X_{m-1}, Y_{n-1})。
 *   ★ 与暴力枚举对比：X 有 2^m 个子序列，暴力是指数级；DP 降到多项式。
 *   ★ 回溯时 c[i-1][j] 与 c[i][j-1] 相等的取舍，决定输出哪一个 LCS（题目会指定）。
 *   ★ 类似思路：编辑距离、最长递增子序列、最长公共子串（只需把递推改成"不等则 0"）。
 *
 * 【多种实现】
 *   ① 自底向上填表（lcs）；② 自顶向下备忘录递归（lcs_memo）。
 *   不加备忘录的朴素递归时间 O(2^(m+n))（子问题大量重复）；加备忘录后 O(m*n)。
 * ============================================================================ */
#include <string.h>
#include "common.h"

#define MAXN 64

static int lcs(const char *x, const char *y, char *out) {
    int m = strlen(x), n = strlen(y);
    static int c[MAXN][MAXN];                /* static 清零：第 0 行、第 0 列即边界 0 */

    /* 填表：c[i][j] 依赖左上、上、左三个格子，所以按行从左到右 */
    for (int i = 1; i <= m; i++)
        for (int j = 1; j <= n; j++) {
            if (x[i - 1] == y[j - 1])        /* 字符串下标从 0 开始，故 i-1 */
                c[i][j] = c[i - 1][j - 1] + 1;  /* 【填空①】字符相等：左上角 +1 */
            else
                c[i][j] = c[i - 1][j] >= c[i][j - 1] ? c[i - 1][j] : c[i][j - 1];  /* 【填空②】字符不等：取上方、左方的较大者 */
        }

    /* 回溯：从右下角走回去，相等就是 LCS 的一个字符（倒着填入 out） */
    int len = c[m][n], k = len;
    out[k] = '\0';
    for (int i = m, j = n; i > 0 && j > 0;) {
        if (x[i - 1] == y[j - 1]) { out[--k] = x[i - 1]; i--; j--; }  /* 【填空③】回溯：相等则属于 LCS，i、j 同时减 1 */
        else if (c[i - 1][j] >= c[i][j - 1]) i--;   /* 来自上方 */
        else j--;                                    /* 来自左方 */
    }
    return len;
}

/* ---------------------------------------------------------------------------
 * 备忘录递归（自顶向下）：递归式与填表法完全一样，只是按需计算 + 记录结果。
 * --------------------------------------------------------------------------- */
static int memo[MAXN][MAXN];                 /* -1：还没算过 */
static const char *X, *Y;

static int lcs_memo(int i, int j) {
    if (i == 0 || j == 0) return 0;          /* 【填空④】边界：空串的 LCS 为 0 */
    if (memo[i][j] >= 0) return memo[i][j];  /* 已算过 */
    int r;
    if (X[i - 1] == Y[j - 1]) {
        r = lcs_memo(i - 1, j - 1) + 1;      /* 【填空⑤】相等：左上 +1 */
    } else {
        int a = lcs_memo(i - 1, j), b = lcs_memo(i, j - 1);
        r = a > b ? a : b;                   /* 不等：取较大者 */
    }
    return memo[i][j] = r;
}

static int lcs_memo_len(const char *x, const char *y) {
    X = x; Y = y;
    for (int i = 0; i < MAXN; i++)
        for (int j = 0; j < MAXN; j++) memo[i][j] = -1;
    return lcs_memo(strlen(x), strlen(y));
}

int main(void) {
    char s[MAXN];
    int len = lcs("ABCBDAB", "BDCABA", s);
    printf("LCS length = %d, one LCS = %s\n", len, s);
    CHECK(len == 4);
    CHECK(strlen(s) == 4);
    CHECK(lcs_memo_len("ABCBDAB", "BDCABA") == 4);   /* 备忘录递归与填表结果一致 */
    CHECK(lcs_memo_len("XMJYAUZ", "MZJAWXU") == 4);  /* MJAU */
    return 0;
}
