/* ============================================================================
 * 最大子段和（Maximum Subarray Sum）—— 分治法 与 动态规划
 * ============================================================================
 * 【问题】 给定整数序列 a[0..n-1]（可含负数），求连续子段之和的最大值。
 *          约定：若全为负数，最大子段和取 0（空子段）。
 *          例：(-2, 11, -4, 13, -5, -2) 的最大子段和为 20（11 + -4 + 13）。
 *
 * 【解法一：暴力】 枚举所有 (i,j) 并累加，O(n^3)；利用前缀和可降到 O(n^2)。
 *
 * 【解法二：分治 O(n log n)】 把序列从中间分成左、右两半，最大子段只有三种可能：
 *   1. 完全在左半；2. 完全在右半；
 *   3. 跨越中点：= 左半中【以 mid 结尾】的最大和 + 右半中【以 mid+1 开头】的最大和
 *      （两部分各自线性扫描求得）。
 *   取三者最大。递推式 T(n) = 2T(n/2) + Θ(n)，由主定理得 Θ(n log n)。
 *
 * 【解法三：动态规划 O(n)】 设 b[j] = 以 a[j] 结尾的最大子段和：
 *     b[j] = max( b[j-1] + a[j], a[j] ) = max(b[j-1], 0) + a[j]
 *   即：前面累积的和为负，就扔掉它重新开始。答案 = max_j b[j]。
 *   只需一个变量滚动保存 b，空间 O(1)。
 *
 * 【考点】
 *   ★ 这是软考"算法设计"填空题最经典的题型之一：三种解法的时间复杂度对比
 *     O(n^3) / O(n^2) / O(n log n) / O(n)；
 *   ★ 分治法的三个步骤：分解、求解、合并；
 *   ★ 主定理：T(n)=aT(n/b)+f(n)。本题 a=2, b=2, f(n)=n => n^(log_b a)=n，
 *     与 f(n) 同阶，故 T(n)=Θ(n log n)。
 *   ★ 动态规划的 b[j] 递推式、取全局最大值的位置（不是 b[n-1]）。
 *
 * 【多种实现】 暴力 O(n^3) -> 暴力 O(n^2) -> 分治 O(n log n) -> 动态规划 O(n)，
 *   真题常把这几种做法的时间复杂度放在一起比较，或让你在其中一种里填空。
 * ============================================================================ */
#include "common.h"

static int max3(int a, int b, int c) {
    int m = a > b ? a : b;
    return m > c ? m : c;
}

/* 分治：求 a[lo..hi] 的最大子段和 */
static int divide(const int a[], int lo, int hi) {
    if (lo == hi) return a[lo] > 0 ? a[lo] : 0;   /* 【填空①】分治出口：单元素，负数按 0 处理｜单个元素：为负取 0 */
    int mid = lo + (hi - lo) / 2;
    int left  = divide(a, lo, mid);               /* 情形 1：完全在左半 */
    int right = divide(a, mid + 1, hi);           /* 情形 2：完全在右半 */

    /* 情形 3：跨中点。向左扩展求"以 mid 结尾"的最大和，向右求"以 mid+1 开头"的最大和 */
    int s1 = 0, best1 = 0;
    for (int i = mid; i >= lo; i--) { s1 += a[i]; if (s1 > best1) best1 = s1; }
    int s2 = 0, best2 = 0;
    for (int i = mid + 1; i <= hi; i++) { s2 += a[i]; if (s2 > best2) best2 = s2; }

    return max3(left, right, best1 + best2);  /* 【填空②】合并：左半、右半、跨中点三者取最大 */
}

/* 动态规划：b 为"以 j 结尾的最大子段和"，best 为全局最大 */
static int dp(const int a[], int n) {
    int best = 0, b = 0;
    for (int j = 0; j < n; j++) {
        b = (b > 0 ? b : 0) + a[j];          /* 【填空③】DP 递推式：前面为负则舍弃，从 a[j] 重新开始｜前面为负就舍弃，从 a[j] 重新开始 */
        if (b > best) best = b;              /* 【填空④】答案是所有 b[j] 的最大值，不是最后一个 b｜最大值不一定在最后一个 b 上 */
    }
    return best;
}

/* 暴力 O(n^3)：枚举所有 (i,j)，每次重新累加 a[i..j] */
static int brute_n3(const int a[], int n) {
    int best = 0;
    for (int i = 0; i < n; i++)
        for (int j = i; j < n; j++) {
            int s = 0;
            for (int k = i; k <= j; k++) s += a[k];
            if (s > best) best = s;
        }
    return best;
}

/* 暴力 O(n^2)：固定起点 i，向右扩展时在原有和上增量累加，省掉最内层循环 */
static int brute_n2(const int a[], int n) {
    int best = 0;
    for (int i = 0; i < n; i++) {
        int s = 0;
        for (int j = i; j < n; j++) {
            s += a[j];                       /* 【填空⑤】增量累加：a[i..j] = a[i..j-1] + a[j] */
            if (s > best) best = s;
        }
    }
    return best;
}

int main(void) {
    int a[] = {-2, 11, -4, 13, -5, -2};
    int n = sizeof a / sizeof a[0];
    int d = divide(a, 0, n - 1), p = dp(a, n);
    printf("divide=%d dp=%d\n", d, p);
    CHECK(d == 20 && p == 20);

    int neg[] = {-3, -1, -2};                /* 全负数：按约定结果为 0 */
    CHECK(divide(neg, 0, 2) == 0 && dp(neg, 3) == 0);

    int c[] = {1, -2, 3, 10, -4, 7, 2, -5};  /* 3+10-4+7+2 = 18 */
    CHECK(divide(c, 0, 7) == 18 && dp(c, 8) == 18);
    /* 四种方法结果必须一致 */
    CHECK(brute_n3(a, n) == 20 && brute_n2(a, n) == 20);
    CHECK(brute_n3(c, 8) == 18 && brute_n2(c, 8) == 18);
    CHECK(brute_n3(neg, 3) == 0 && brute_n2(neg, 3) == 0);
    return 0;
}
