/* ============================================================================
 * 折半查找 / 二分查找（Binary Search）—— 分治法
 * ============================================================================
 * 【前提条件】 ★ 必须是顺序存储（数组）且关键字有序。链表不适用（无法 O(1) 取中点）。
 *
 * 【算法思想】
 *   与区间中间元素 a[mid] 比较：
 *     相等 => 查找成功；key 更小 => 到左半区间继续；key 更大 => 到右半区间继续；
 *   区间为空（lo > hi）=> 查找失败。每次区间减半。
 *
 * 【复杂度】
 *   - 时间 O(log n)；最多比较次数 ⌊log2 n⌋ + 1
 *   - 成功查找的平均查找长度 ASL ≈ log2(n+1) - 1
 *   - 空间：迭代 O(1)，递归 O(log n)
 *
 * 【考点】
 *   ★ 判定树：折半查找过程对应一棵（近似）平衡的二叉判定树，
 *     树高 = ⌈log2(n+1)⌉，查找某元素的比较次数 = 它在判定树上的层数。
 *     真题常给 11 个元素，让你画判定树/算 ASL。
 *   ★ mid 的取整：⌊(lo+hi)/2⌋ 与 ⌈(lo+hi)/2⌉ 得到的判定树不同，看清题目约定。
 *   ★ 与其他查找对比：顺序查找 O(n)（对存储、有序性无要求）；
 *     分块查找 = 块内无序 + 块间有序，介于两者之间；
 *     哈希查找平均 O(1)；二叉排序树平均 O(log n)，但退化时 O(n)。
 *   ★ 防溢出：写 lo + (hi - lo) / 2 而不是 (lo + hi) / 2。
 *   ★ 插入、删除需要移动元素，所以折半查找适用于"静态"有序表。
 * ============================================================================ */
#include "common.h"

/* 迭代版：返回下标，找不到返回 -1 */
static int bsearch_iter(const int a[], int n, int key) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {                       /* 【填空①】循环条件 lo<=hi，区间非空才继续｜易错：是 <= 而不是 <，否则漏掉单元素区间 */
        int mid = lo + (hi - lo) / 2;
        if (a[mid] == key) return mid;
        if (a[mid] < key) lo = mid + 1;      /* 【填空②】缩小区间：lo=mid+1 / hi=mid-1，少 1 会死循环｜易错：必须 +1 / -1，否则可能死循环 */
        else hi = mid - 1;
    }
    return -1;
}

/* 递归版：体现分治结构，递归出口 lo > hi（空区间） */
static int bsearch_rec(const int a[], int lo, int hi, int key) {
    if (lo > hi) return -1;  /* 【填空③】递归出口：空区间表示查找失败 */
    int mid = lo + (hi - lo) / 2;
    if (a[mid] == key) return mid;
    if (a[mid] < key) return bsearch_rec(a, mid + 1, hi, key);  /* 【填空④】key 更大：到右半区间递归 */
    return bsearch_rec(a, lo, mid - 1, key);
}

/* 统计比较次数，用来验证"最多 ⌊log2 n⌋+1 次" */
static int compare_count(const int a[], int n, int key) {
    int lo = 0, hi = n - 1, cnt = 0;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        cnt++;
        if (a[mid] == key) break;
        if (a[mid] < key) lo = mid + 1; else hi = mid - 1;
    }
    return cnt;
}

int main(void) {
    /* 11 个元素：这是教材判定树的经典规模，判定树高 4 */
    int a[] = {5, 13, 19, 21, 37, 56, 64, 75, 80, 88, 92};
    int n = sizeof a / sizeof a[0];
    CHECK(bsearch_iter(a, n, 21) == 3);
    CHECK(bsearch_iter(a, n, 92) == 10);
    CHECK(bsearch_iter(a, n, 5) == 0);
    CHECK(bsearch_iter(a, n, 22) == -1);     /* 不存在 */
    CHECK(bsearch_rec(a, 0, n - 1, 64) == 6);
    CHECK(bsearch_rec(a, 0, n - 1, 100) == -1);

    /* 根 mid=5(56) 比较 1 次；21 经 56->19... 共 3 次；每个元素最多 4 次 */
    int total = 0;
    for (int i = 0; i < n; i++) {
        int c = compare_count(a, n, a[i]);
        CHECK(c <= 4);                       /* ⌊log2 11⌋+1 = 4 */
        total += c;
    }
    printf("ASL (success) = %d/%d = %.3f\n", total, n, (double)total / n);
    CHECK(total == 33);                      /* 1*1 + 2*2 + 3*4 + 4*4 = 33 */
    return 0;
}
