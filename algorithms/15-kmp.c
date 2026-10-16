/* ============================================================================
 * KMP 模式匹配算法
 * ============================================================================
 * 【问题】 在主串（文本）T 中查找模式串 P 第一次出现的位置。
 *
 * 【朴素匹配（BF）】 失配时主串指针回退到本次起点的下一位、模式串回到开头，
 *                    最坏 O(n*m)。
 *
 * 【KMP 的改进】 失配时【主串指针 i 不回溯】，只让模式串指针 j 回退到 next[j]，
 *                利用"已匹配部分的前缀与后缀相同"的信息，跳过不可能的比较。
 *                时间 O(n+m)：求 next 数组 O(m) + 匹配 O(n)。
 *
 * 【next 数组 —— 本题最大考点 ★】
 *   两种常见定义，务必看清题目用哪种：
 *   (1) 失败函数 pi[i]（本文件 prefix_function，下标从 0）：
 *       P[0..i] 的最长【相等真前缀与真后缀】的长度。
 *   (2) 教材 next[j]（下标从 1）：
 *       next[1] = 0；next[j] = (P1..P_{j-1} 中最长相等前后缀长度) + 1。
 *       关系：next[j] = pi[j-2] + 1（j >= 2）。本文件 get_next1 实现并验证。
 *   以 P = ABCDABD 为例：
 *       j        1 2 3 4 5 6 7
 *       P        A B C D A B D
 *       next[j]  0 1 1 1 1 2 3     <- 教材（1 起）
 *       pi       0 0 0 0 1 2 0     <- 本代码（0 起）
 *   失配于 P[j] 时，下一步用 P[next[j]] 继续与当前主串字符比较；next[j]=0 表示
 *   主串指针前进一位、模式串从头开始。
 *   （进阶：nextval 修正数组——若 P[next[j]] == P[j]，则 nextval[j] = nextval[next[j]]，
 *     避免连续相同字符的无效比较。）
 *
 * 【考点】
 *   ★ 手算 next / nextval 数组（几乎每年都有字符串匹配相关题）。
 *   ★ 说出 KMP 与朴素匹配的区别：主串指针不回溯；时间 O(n+m) 对 O(nm)。
 *   ★ KMP 的优势在"模式串与主串有大量部分匹配"时才明显；一般情况朴素算法也接近线性。
 *
 * 【多种实现】
 *   ① 朴素匹配 BF（bf_search）：失配时主串指针回退；
 *   ② 现代写法的 KMP（kmp_search，基于 pi，0 起）；
 *   ③ 教材写法的 KMP（kmp_search_next，基于 next，1 起）——软考真题多用这一种。
 * ============================================================================ */
#include <string.h>
#include "common.h"

#define MAXM 64

/* 失败函数 pi（0-based）。k 表示"当前已匹配的前后缀长度" */
static void prefix_function(const char *p, int pi[]) {
    int m = strlen(p);
    pi[0] = 0;                               /* 单个字符没有真前后缀 */
    for (int i = 1, k = 0; i < m; i++) {
        while (k > 0 && p[i] != p[k]) k = pi[k - 1];  /* 【填空①】失配：k 回退到 pi[k-1]，求 next 数组的核心｜失配：回退到更短的前后缀 */
        if (p[i] == p[k]) k++;                         /* 【填空②】匹配：相等前后缀长度 +1｜匹配：前后缀长度 +1 */
        pi[i] = k;
    }
}

/* 教材 next 数组（1-based）：next[1..m]；数组需有 m+1 个位置 */
static void get_next1(const char *p, int next[]) {
    int m = strlen(p), pi[MAXM];
    prefix_function(p, pi);
    next[1] = 0;
    for (int j = 2; j <= m; j++) next[j] = pi[j - 2] + 1;
}

/* 返回 p 在 t 中首次出现的下标（0-based），没有则 -1 */
static int kmp_search(const char *t, const char *p) {
    int n = strlen(t), m = strlen(p), pi[MAXM];
    prefix_function(p, pi);
    for (int i = 0, k = 0; i < n; i++) {     /* 【填空③】主串指针 i 不回溯，这是 KMP 与朴素匹配的区别｜i 只增不减：主串不回溯 */
        while (k > 0 && t[i] != p[k]) k = pi[k - 1];   /* 失配：模式串右移 */
        if (t[i] == p[k]) k++;
        if (k == m) return i - m + 1;        /* 【填空④】k==m 表示模式串全部匹配，起点为 i-m+1｜模式串全部匹配 */
    }
    return -1;
}

/* ---------------------------------------------------------------------------
 * 朴素（Brute Force）匹配：失配时 i 回退到本次起点的下一位，j 回到 0。最坏 O(n*m)。
 * --------------------------------------------------------------------------- */
static int bf_search(const char *t, const char *p) {
    int n = strlen(t), m = strlen(p), i = 0, j = 0;
    while (i < n && j < m) {
        if (t[i] == p[j]) { i++; j++; }
        else { i = i - j + 1; j = 0; }       /* 【填空⑤】主串回退：i-j+1，这是与 KMP 的根本区别 */
    }
    return j == m ? i - m : -1;
}

/* ---------------------------------------------------------------------------
 * 教材写法的 KMP：下标从 1 开始，用 next[j] 作为失配后模式串的新位置。
 * j == 0 表示"模式串第一个字符就失配"，此时主串前进一位、模式串从头开始。
 * --------------------------------------------------------------------------- */
static int kmp_search_next(const char *t, const char *p) {
    int n = strlen(t), m = strlen(p), next[MAXM + 1];
    get_next1(p, next);
    int i = 1, j = 1;                        /* 均为 1 起的位置，t[i-1]、p[j-1] 才是实际字符 */
    while (i <= n && j <= m) {
        if (j == 0 || t[i - 1] == p[j - 1]) { i++; j++; }   /* 【填空⑥】j==0 或字符相等：同时前进 */
        else j = next[j];                    /* 【填空⑦】失配：只回退 j，i 不动 */
    }
    return j > m ? i - m - 1 : -1;           /* 匹配成功时 1 起的起点是 i-m，转成 0 起再减 1 */
}

int main(void) {
    int pi[MAXM];
    prefix_function("ABCDABD", pi);
    print_array("pi(ABCDABD)", pi, 7);
    int expect[] = {0, 0, 0, 0, 1, 2, 0};
    for (int i = 0; i < 7; i++) CHECK(pi[i] == expect[i]);

    /* 教材形式的 next 数组 */
    int next[MAXM + 1];
    get_next1("ABCDABD", next);
    printf("next(ABCDABD):");
    for (int j = 1; j <= 7; j++) printf(" %d", next[j]);
    printf("\n");
    int expect_next[] = {0, 0, 1, 1, 1, 1, 2, 3};   /* 下标 0 占位 */
    for (int j = 1; j <= 7; j++) CHECK(next[j] == expect_next[j]);

    /* 另一个常考模式串 ababaa：next = 0 1 1 2 3 4 */
    get_next1("ababaa", next);
    int expect2[] = {0, 0, 1, 1, 2, 3, 4};
    for (int j = 1; j <= 6; j++) CHECK(next[j] == expect2[j]);

    CHECK(kmp_search("BBC ABCDAB ABCDABCDABDE", "ABCDABD") == 15);
    CHECK(kmp_search("hello world", "world") == 6);
    CHECK(kmp_search("aaaaab", "aab") == 3);
    CHECK(kmp_search("abc", "abd") == -1);
    /* 三种实现结果必须一致 */
    const char *ts[] = {"BBC ABCDAB ABCDABCDABDE", "hello world", "aaaaab", "abc"};
    const char *ps[] = {"ABCDABD", "world", "aab", "abd"};
    for (int k = 0; k < 4; k++) {
        int r = kmp_search(ts[k], ps[k]);
        CHECK(bf_search(ts[k], ps[k]) == r);
        CHECK(kmp_search_next(ts[k], ps[k]) == r);
    }
    return 0;
}
