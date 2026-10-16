# 软件设计师（中级）下午题四（算法）

## T4.1 四大算法设计策略

下午题四考算法设计与分析：给出一段 C 代码，要求补全空缺、说明所用的设计策略、分析时间复杂度、手算运行结果。
分治法把问题分解成相互独立的同类子问题，递归求解后再合并，子问题之间没有重叠。
动态规划的两大特征是最优子结构和重叠子问题，自底向上填表保存子问题的解。
贪心法的两大特征是贪心选择性质和最优子结构，每一步取局部最优且不回溯。
回溯法在解空间树上做深度优先搜索，用约束函数和限界函数剪枝，用来求所有解或可行解。
分支限界法用广度优先或最小耗费优先搜索解空间树，用来求最优解。
属于分治法的典型题目有快速排序、归并排序、折半查找、汉诺塔和最大子段和的分治解法。
属于动态规划的典型题目有 0-1 背包、最长公共子序列、矩阵连乘、Floyd 最短路径和最大子段和的动态规划解法。
属于贪心法的典型题目有部分背包、Dijkstra、Prim、Kruskal、哈夫曼编码和活动安排。
属于回溯法的典型题目有 N 皇后、图的着色、哈密顿回路和 0-1 背包的回溯解法。
主定理：T(n)=aT(n/b)+f(n)，比较 f(n) 与 n 的 log_b a 次方，两者同阶时 T(n)=Θ(f(n)·log n)。
递归式 T(n)=2T(n/2)+Θ(n) 的解是 Θ(n log n)，折半查找的递归式 T(n)=T(n/2)+Θ(1) 的解是 Θ(log n)。
动态规划是自底向上，贪心法是自顶向下一步步做选择，贪心法不回头，所以贪心法通常比动态规划更简单。

## T4.2 排序算法对比

直接插入排序、冒泡排序、简单选择排序的平均时间复杂度都是 O(n²)。
快速排序平均时间 O(n log n)，最坏时间 O(n²)，平均空间 O(log n)，是不稳定排序。
堆排序最好、最坏、平均时间都是 O(n log n)，空间 O(1)，是不稳定排序。
归并排序时间 O(n log n)，空间 O(n)，是稳定排序。
稳定的排序有直接插入、冒泡、归并和基数排序，不稳定的排序有简单选择、希尔、快速和堆排序。
快速排序在序列已经有序或逆序、且枢轴取首元素时退化为最坏情况。
直接插入排序和带标志的冒泡排序在序列基本有序时接近 O(n)。
希尔排序是对直接插入排序的改进，时间复杂度与增量序列有关，是不稳定排序。
基于比较的排序算法，最坏情况下时间复杂度的下界是 Ω(n log n)。
只有归并排序同时具备稳定和最坏 O(n log n) 两个特点，代价是需要 O(n) 的辅助空间。

## T4.3 快速排序：思想与考点

快速排序属于分治法：选一个枢轴，一趟划分后枢轴左边的元素都不大于它，右边的元素都不小于它，枢轴落在最终位置，再递归排序左右两个子区间。
一趟划分常用挖坑填数：取 a[lo] 为枢轴，hi 从右往左找第一个小于枢轴的数填到左坑，lo 从左往右找第一个大于枢轴的数填到右坑，最后把枢轴填入最后的坑。
快速排序的平均时间复杂度为 O(n log n)，最坏时间复杂度为 O(n²)，平均空间复杂度 O(log n)，最坏 O(n)，是不稳定排序。
序列已经有序或逆序、枢轴又取首元素时，每次只划出一个元素，递归式为 T(n)=T(n-1)+O(n)，时间退化为 O(n²)。
对序列 49 38 65 97 76 13 27 49 55 4 以 49 为枢轴做第一趟划分，结果是 4 38 27 13 49 76 97 49 55 65，枢轴落在下标 4。
对序列 5 3 8 6 2 7 1 4 以 5 为枢轴做第一趟划分，结果是 4 3 1 2 5 7 6 8。
改进的办法有三数取中或随机选枢轴、小区间改用插入排序、先递归较短的一侧使栈深度保持 O(log n)。
非递归的快速排序用显式栈保存待排区间，出栈顺序与入栈相反，先压较长的区间、后压较短的区间，栈深度为 O(log n)。

## T4.4 快速排序：核心代码

```c
static int partition(int a[], int lo, int hi) {
    int pivot = a[lo];
    while (lo < hi) {
        while (lo < hi && a[hi] >= pivot) hi--;
        a[lo] = a[hi];
        while (lo < hi && a[lo] <= pivot) lo++;
        a[hi] = a[lo];
    }
    a[lo] = pivot;
    return lo;
}

static void quick_sort(int a[], int lo, int hi) {
    if (lo >= hi) return;
    int p = partition(a, lo, hi);
    quick_sort(a, lo, p - 1);
    quick_sort(a, p + 1, hi);
}
```

内层 while 循环必须带 lo < hi 条件，否则指针会越界。
递归出口是 lo >= hi，也就是区间内元素个数不超过 1。
划分返回枢轴的最终下标 p，递归的两个子区间是 [lo, p-1] 和 [p+1, hi]，枢轴本身不再参与。
常见填空：内层 while 的比较符号、a[lo] = a[hi] 的赋值方向、递归出口和递归区间。

## T4.5 归并排序：思想与考点

归并排序属于分治法：把序列从中间一分为二，递归排序两半，再把两个有序子序列合并成一个有序序列。
归并排序在任何情况下时间复杂度都是 O(n log n)，空间复杂度为 O(n)，是稳定排序。
合并时左右两段的队首元素相等，先取左段的元素，这样才能保证稳定性。
二路归并 n 个元素需要 ⌈log2 n⌉ 趟，有序段长度依次为 1、2、4、8，每趟把相邻的两个有序段合并。
自底向上的非递归归并排序直接从长度为 1 的有序段开始，每趟段长翻倍。
对 49 38 65 97 76 13 27 49 55 4 做自底向上的二路归并，第 1 趟之后的序列是 38 49 65 97 13 76 27 49 4 55。
同一序列的第 2 趟之后是 38 49 65 97 13 27 49 76 4 55，第 3 趟之后是 13 27 38 49 49 65 76 97 4 55。
合并两个长度分别为 m 和 n 的有序表，比较次数最少为 min(m,n)，最多为 m+n-1。
归并排序是外部排序的基础。

## T4.6 归并排序：核心代码

```c
static void merge(int a[], int tmp[], int lo, int mid, int hi) {
    int i = lo, j = mid + 1, k = lo;
    while (i <= mid && j <= hi) tmp[k++] = (a[i] <= a[j]) ? a[i++] : a[j++];
    while (i <= mid) tmp[k++] = a[i++];
    while (j <= hi)  tmp[k++] = a[j++];
    for (k = lo; k <= hi; k++) a[k] = tmp[k];
}

static void merge_sort(int a[], int tmp[], int lo, int hi) {
    if (lo >= hi) return;
    int mid = lo + (hi - lo) / 2;
    merge_sort(a, tmp, lo, mid);
    merge_sort(a, tmp, mid + 1, hi);
    merge(a, tmp, lo, mid, hi);
}
```

自底向上的非递归写法：

```c
for (int w = 1; w < n; w *= 2)
    for (int lo = 0; lo < n - w; lo += 2 * w) {
        int mid = lo + w - 1;
        int hi = (lo + 2 * w - 1 < n) ? lo + 2 * w - 1 : n - 1;
        merge(a, tmp, lo, mid, hi);
    }
```

mid = lo + (hi - lo) / 2 的写法可以避免 lo + hi 溢出。
merge 放在两次递归调用之后，属于后序处理。
非递归版中最后一个右段可能不足 w 个元素，所以 hi 要取 n-1。

## T4.7 堆排序：思想与考点

堆是完全二叉树，大顶堆中每个结点都不小于它的左右孩子，小顶堆则相反。
下标从 0 开始时，结点 i 的左孩子是 2i+1，右孩子是 2i+2，父结点是 (i-1)/2；下标从 1 开始时，左孩子是 2i，右孩子是 2i+1，父结点是 i/2。
最后一个非叶子结点的下标，从 0 开始是 n/2-1，从 1 开始是 ⌊n/2⌋。
堆排序先建堆，再反复把堆顶与堆尾交换，堆长度减 1，对堆顶向下调整。
升序排序用大顶堆，降序排序用小顶堆。
建堆的时间复杂度是 O(n)，整个堆排序最好、最坏、平均都是 O(n log n)，空间复杂度 O(1)，是不稳定排序。
对 49 38 65 97 76 13 27 49 55 4 建大顶堆，得到的数组是 97 76 65 55 49 13 27 49 38 4。
对这个大顶堆做第一次交换并调整后，前 9 个元素是 76 55 65 49 49 13 27 4 38，97 已在末尾。
堆排序不适合链式存储，适合求 Top-K。

## T4.8 堆排序：核心代码

```c
static void sift_down(int a[], int i, int n) {
    int x = a[i];
    for (int child = 2 * i + 1; child < n; child = 2 * i + 1) {
        if (child + 1 < n && a[child + 1] > a[child]) child++;
        if (a[child] <= x) break;
        a[i] = a[child];
        i = child;
    }
    a[i] = x;
}

static void heap_sort(int a[], int n) {
    for (int i = n / 2 - 1; i >= 0; i--) sift_down(a, i, n);
    for (int end = n - 1; end > 0; end--) {
        int t = a[0]; a[0] = a[end]; a[end] = t;
        sift_down(a, 0, end);
    }
}
```

选左右孩子中较大者时要先判断 child + 1 < n，防止越界。
建堆从最后一个非叶子结点 n/2-1 倒序到 0，逐个向下调整。
交换之后堆的长度缩为 end，已经排好的元素不再参与调整。

## T4.9 折半查找

折半查找要求顺序存储且关键字有序，链表不适用。
每次与中间元素 a[mid] 比较，相等则成功，key 更小到左半区间，key 更大到右半区间，区间为空则查找失败。
折半查找的时间复杂度是 O(log n)，最多比较 ⌊log2 n⌋+1 次，成功查找的平均查找长度约为 log2(n+1)-1。
折半查找的判定树是近似平衡的二叉树，树高为 ⌈log2(n+1)⌉，比较次数等于元素在判定树上的层数。
对 5 13 19 21 37 56 64 75 80 88 92 共 11 个元素折半查找，平均查找长度为 33/11，查找 92 需要比较 4 次，查找 21 需要比较 3 次。
防止溢出时 mid 写成 lo + (hi - lo) / 2，而不是 (lo + hi) / 2。

```c
int lo = 0, hi = n - 1;
while (lo <= hi) {
    int mid = lo + (hi - lo) / 2;
    if (a[mid] == key) return mid;
    if (a[mid] < key) lo = mid + 1;
    else hi = mid - 1;
}
return -1;
```

循环条件是 lo <= hi，写成 lo < hi 会漏掉只剩一个元素的区间。
缩小区间时必须写 lo = mid + 1 和 hi = mid - 1，少加减 1 可能死循环。
递归版的递归出口是 lo > hi，表示空区间，查找失败。
与其他查找对比：顺序查找 O(n)，分块查找块内无序块间有序，哈希查找平均 O(1)，二叉排序树平均 O(log n) 但可能退化为 O(n)。

## T4.10 0-1 背包：思想与考点

0-1 背包问题：n 个物品，重量 w[i]、价值 v[i]，背包容量 C，每个物品要么整个装入要么不装，求不超过容量的最大总价值。
0-1 背包用动态规划求解：dp[i][c] 表示只考虑前 i 个物品、容量为 c 时的最大价值。
递推式：装不下（c < w[i]）时 dp[i][c] = dp[i-1][c]；装得下时 dp[i][c] = max(dp[i-1][c], dp[i-1][c-w[i]] + v[i])。
边界条件是 dp[0][c] = 0 和 dp[i][0] = 0。
时间复杂度和空间复杂度都是 O(n·C)，这是伪多项式时间。
用一维数组把空间优化到 O(C) 时，容量 c 必须从大到小逆序遍历，否则同一物品会被重复装入。
从 dp[n][C] 回溯构造解：若 dp[i][c] 不等于 dp[i-1][c]，说明第 i 个物品被选中，然后 c 减去 w[i]。
备忘录递归是自顶向下的动态规划，不带备忘录的纯递归是指数级 O(2^n)。
回溯法解 0-1 背包的解空间树是子集树，每个物品有装和不装两个分支，用约束函数（装入后不超重）和上界函数剪枝。
三件物品（重量,价值）为 (10,60)、(20,100)、(30,120)，容量 50，最大价值为 220，选第 2、3 件。
四件物品重量为 2、3、4、5，价值为 3、4、5、6，容量 8，最大价值为 10，dp[4][8] = 10。

## T4.11 0-1 背包：核心代码

```c
for (int i = 1; i <= N; i++)
    for (int c = 0; c <= C; c++) {
        dp[i][c] = dp[i - 1][c];
        if (c >= w[i] && dp[i - 1][c - w[i]] + v[i] > dp[i][c])
            dp[i][c] = dp[i - 1][c - w[i]] + v[i];
    }
```

回溯构造所选物品：

```c
for (int i = N; i >= 1; i--)
    if (dp[i][c] != dp[i - 1][c]) {
        c -= w[i];
    }
```

一维滚动数组：

```c
for (int i = 1; i <= n; i++)
    for (int c = cap; c >= w[i]; c--)
        if (f[c - w[i]] + v[i] > f[c]) f[c] = f[c - w[i]] + v[i];
```

备忘录递归：

```c
static int knap_memo(const int w[], const int v[], int i, int c) {
    if (i == 0) return 0;
    if (kmemo[i][c] >= 0) return kmemo[i][c];
    int best = knap_memo(w, v, i - 1, c);
    if (c >= w[i]) {
        int t = knap_memo(w, v, i - 1, c - w[i]) + v[i];
        if (t > best) best = t;
    }
    return kmemo[i][c] = best;
}
```

备忘录数组初值设为 -1 表示该子问题还没有计算过。

## T4.12 部分背包与贪心法

部分背包问题中物品可以拆分，用贪心法求解：按单位重量价值 v/w 从大到小排序，依次整件装入，装不下的那一件按剩余容量取一部分。
部分背包的时间复杂度由排序决定，为 O(n log n)。
物品 (10,60)、(20,100)、(30,120)，容量 50，单位价值依次为 6、5、4，部分背包的最大价值为 240。
同一组数据照搬贪心去做 0-1 背包，只能装下前两件，价值 160，而最优解是 220，所以 0-1 背包不能用贪心法。

```c
static int cmp(const void *x, const void *y) {
    const Item *a = x, *b = y;
    double ra = a->v / a->w, rb = b->v / b->w;
    return (ra < rb) - (ra > rb);
}
for (int i = 0; i < n && cap > 0; i++) {
    if (items[i].w <= cap) {
        cap -= items[i].w;
        total += items[i].v;
    } else {
        total += items[i].v * (cap / items[i].w);
        cap = 0;
    }
}
```

比较函数返回 (ra < rb) - (ra > rb)，实现按单位价值降序排序。
整件装得下就全拿并扣减剩余容量，装不下就按比例取一部分，然后背包装满结束。

## T4.13 最长公共子序列 LCS

子序列不要求连续，子串必须连续，LCS 是最长公共子序列，不是最长公共子串。
X=ABCBDAB 与 Y=BDCABA 的 LCS 长度为 4，例如 BCBA，LCS 不唯一。
递推式：c[i][j] 在 i=0 或 j=0 时为 0；x[i]==y[j] 时为 c[i-1][j-1]+1；否则为 max(c[i-1][j], c[i][j-1])。
LCS 的时间复杂度和空间复杂度都是 O(m·n)，只求长度时空间可以压缩到 O(min(m,n))。
暴力枚举 X 的全部子序列是指数级，动态规划把它降为多项式。
对 X=ABCBDAB 和 Y=BDCABA 填表，c[4][5] = 3，c[7][6] = 4。
对 X=ABCD 和 Y=ACBD，LCS 长度为 3。
回溯构造 LCS：x[i]==y[j] 时该字符属于 LCS，i 和 j 同时减 1；否则向 c 值较大的一侧移动。

```c
for (int i = 1; i <= m; i++)
    for (int j = 1; j <= n; j++) {
        if (x[i - 1] == y[j - 1])
            c[i][j] = c[i - 1][j - 1] + 1;
        else
            c[i][j] = c[i - 1][j] >= c[i][j - 1] ? c[i - 1][j] : c[i][j - 1];
    }
```

字符串下标从 0 开始，所以比较的是 x[i-1] 和 y[j-1]。
备忘录递归写法的边界是 if (i == 0 || j == 0) return 0。

## T4.14 矩阵连乘

p×q 的矩阵与 q×r 的矩阵相乘，需要 p·q·r 次标量乘法。
A(10×100)、B(100×5)、C(5×50)三个矩阵连乘，(AB)C 需要 7500 次乘法，A(BC) 需要 75000 次。
矩阵 A_i 的维度是 p[i-1]×p[i]，m[i][j] 表示计算 A_i 到 A_j 的最少乘法次数。
递推式：i=j 时 m[i][j]=0；i<j 时 m[i][j] = min(m[i][k] + m[k+1][j] + p[i-1]·p[k]·p[j])，k 取 i 到 j-1。
s[i][j] 记录取得最小值的断点 k，用来还原最优括号化方案。
填表顺序按链长从小到大，也就是按对角线填，因为 m[i][j] 依赖更短的子链。
时间复杂度 O(n³)，空间复杂度 O(n²)；暴力枚举所有加括号方式的数目是卡特兰数，是指数级。
6 个矩阵的维度数组 p = 30 35 15 5 10 20 25，最少需要 15125 次标量乘法。
三个矩阵的维度数组 p = 10 30 5 60，最少需要 4500 次标量乘法，断点 s[1][3] = 2。

```c
for (int len = 2; len <= N; len++)
    for (int i = 1; i + len - 1 <= N; i++) {
        int j = i + len - 1;
        m[i][j] = 1 << 30;
        for (int k = i; k < j; k++) {
            int cost = m[i][k] + m[k + 1][j] + p[i - 1] * p[k] * p[j];
            if (cost < m[i][j]) { m[i][j] = cost; s[i][j] = k; }
        }
    }
```

最外层循环是链长 len，从 2 到 N，三重循环的顺序是链长、起点、断点。
输出括号方案时左段是 [i, s[i][j]]，右段是 [s[i][j]+1, j]。
备忘录递归版本同样是 O(n³)，不带备忘录的递归是指数级。

## T4.15 Dijkstra 单源最短路径

Dijkstra 求从源点到其余各顶点的最短路径，边权必须非负，有负权边时要用 Bellman-Ford。
Dijkstra 属于贪心法：每轮从未确定的顶点里选 dist 最小的顶点 u 加入集合 S，再用 u 松弛其余顶点。
松弛条件是 dist[u] + g[u][v] < dist[v]，松弛成功时更新 dist[v] 并记录前驱 prev[v] = u。
用邻接矩阵实现的时间复杂度是 O(n²)，用邻接表加小顶堆实现是 O((n+e) log n)。
顶点加入集合 S 的顺序是按最短距离从小到大的。
Dijkstra 与 Prim 结构相似，Prim 比较到树内任一点的最小边权，Dijkstra 比较到源点的累计距离。
单源最短路径用贪心法，Floyd 多源最短路径用动态规划。
无向图有边 (0,1)=7、(0,2)=9、(0,5)=14、(1,2)=10、(1,3)=15、(2,3)=11、(2,5)=2、(3,4)=6、(4,5)=9，从顶点 0 出发的最短距离依次为 0 7 9 20 20 11，到顶点 4 的最短路径是 0→2→5→4。

```c
for (int round = 1; round < N; round++) {
    int u = -1;
    for (int i = 0; i < N; i++)
        if (!done[i] && (u == -1 || dist[i] < dist[u])) u = i;
    done[u] = 1;
    for (int v = 0; v < N; v++)
        if (!done[v] && g[u][v] < INF && dist[u] + g[u][v] < dist[v]) {
            dist[v] = dist[u] + g[u][v];
            prev[v] = u;
        }
}
```

输出路径时沿 prev 数组从终点回到源点，递归先打印前驱再打印当前顶点。

## T4.16 Floyd 多源最短路径

Floyd 求任意两点之间的最短路径，属于动态规划。
递推式：d_k[i][j] = min(d_{k-1}[i][j], d_{k-1}[i][k] + d_{k-1}[k][j])，k 依次作为允许经过的中间顶点。
Floyd 的时间复杂度是 O(n³)，空间复杂度是 O(n²)，可以在一个二维数组上原地更新。
Floyd 允许有负权边，但不能有负权回路。
三重循环中 k 必须放在最外层，把 k 放在内层会得到错误的结果。
邻接矩阵初始化时对角线为 0，没有边的位置为 INF，INF 参与加法要防止溢出。
要输出具体路径，需要另外维护 path[i][j] 记录中转点。
把加法和取最小换成逻辑与和逻辑或，就是求传递闭包的 Warshall 算法。
有向图四个顶点有边 0→1 权 5、0→3 权 10、1→2 权 3、2→3 权 1，Floyd 之后 d[0][3] = 9，d[1][3] = 4，d[3][0] 为 INF。

```c
for (int k = 0; k < N; k++)
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            if (d[i][k] + d[k][j] < d[i][j])
                d[i][j] = d[i][k] + d[k][j];
```

## T4.17 最小生成树：思想与考点

连通无向带权图的生成树包含全部 n 个顶点和恰好 n-1 条边，没有回路，边权之和最小的生成树就是最小生成树。
最小生成树的权值是唯一的，但树的形态可能不唯一；若所有边权互不相同，则最小生成树唯一。
Prim 算法是加点法：从一个顶点出发，每次选一端在树内、一端在树外的权值最小的边，把树外端点加入。
Prim 用 lowcost[i] 记录树外顶点 i 到树的最小边权，closest[i] 记录对应的树内顶点。
Prim 用邻接矩阵实现的时间复杂度是 O(n²)，与边数无关，适合稠密图。
Kruskal 算法是加边法：把边按权值升序排列，依次考察，不构成回路就选中，直到选够 n-1 条边。
Kruskal 用并查集判断两个端点是否已经连通，时间复杂度是 O(e log e)，适合稀疏图。
Kruskal 也叫避圈法，破圈法是不断删去回路中权值最大的边。
无向图有边 (0,1)=7、(0,2)=9、(0,5)=14、(1,2)=10、(1,3)=15、(2,3)=11、(2,5)=2、(3,4)=6、(4,5)=9，最小生成树的权值为 33。
对这个图从顶点 0 出发，Prim 选边的顺序是 (0,1)、(0,2)、(2,5)、(5,4)、(4,3)，Kruskal 第一条选的边是 (2,5)。
最小生成树解决的是连通所有顶点的总代价最小，不是从某个顶点出发的路径最短，后者是 Dijkstra 要解决的问题。

## T4.18 最小生成树：核心代码

```c
/* Prim */
for (int round = 1; round < N; round++) {
    int k = -1;
    for (int i = 1; i < N; i++)
        if (lowcost[i] != 0 && (k == -1 || lowcost[i] < lowcost[k])) k = i;
    total += lowcost[k];
    lowcost[k] = 0;
    for (int i = 1; i < N; i++)
        if (lowcost[i] != 0 && g[k][i] < lowcost[i]) {
            lowcost[i] = g[k][i];
            closest[i] = k;
        }
}
```

```c
/* Kruskal */
static int find(int parent[], int x) {
    while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
    return x;
}
for (int i = 0; i < e && picked < N - 1; i++) {
    int ru = find(parent, edges[i].u), rv = find(parent, edges[i].v);
    if (ru == rv) continue;
    parent[ru] = rv;
    total += edges[i].w;
    picked++;
}
```

Prim 中 lowcost[i] 等于 0 表示顶点 i 已经在树中。
Kruskal 中两个端点的根相同说明选这条边会形成回路，应当舍弃。
选中一条边之后用 parent[ru] = rv 合并两个连通分量。

## T4.19 哈夫曼编码：思想与考点

带权路径长度 WPL 是所有叶子的权值乘以该叶子路径长度之和，WPL 最小的二叉树叫哈夫曼树，也叫最优二叉树。
构造哈夫曼树属于贪心法：每次选出根权值最小的两棵树合并成新树，新根的权值是两者之和，直到只剩一棵树。
哈夫曼编码规定左分支记 0、右分支记 1，从根到叶子的 0/1 串就是该叶子字符的编码。
n 个叶子的哈夫曼树共有 2n-1 个结点，度为 0 的 n 个，度为 2 的 n-1 个，没有度为 1 的结点。
WPL 也等于所有内部（非叶子）结点的权值之和。
哈夫曼编码是前缀码，任一字符的编码都不是另一字符编码的前缀，所以译码没有歧义，出现频率高的字符编码短。
哈夫曼树不唯一，编码也不唯一，但 WPL 唯一。
线性查找最小两项时构造的时间复杂度是 O(n²)，用小顶堆可以优化到 O(n log n)。
六个字符 a、b、c、d、e、f 的频率为 45、13、12、16、9、5，WPL 为 224，其中 a 的编码长度为 1，e 和 f 的编码长度为 4。
频率最低的两个字符在最优编码树中一定是最深的兄弟叶子，这是哈夫曼算法的贪心选择性质。

## T4.20 哈夫曼编码：核心代码

```c
typedef struct { int weight, parent, lchild, rchild; } Node;

static int select_min(const Node t[], int upto) {
    int k = -1;
    for (int i = 0; i < upto; i++)
        if (t[i].parent == -1 && (k == -1 || t[i].weight < t[k].weight)) k = i;
    return k;
}

for (int i = N; i < M; i++) {
    int a = select_min(t, i);
    t[a].parent = i;
    int b = select_min(t, i);
    t[b].parent = i;
    t[i].lchild = a;
    t[i].rchild = b;
    t[i].weight = t[a].weight + t[b].weight;
}
```

求编码时从叶子往根走，沿途记录当前结点是父结点的左孩子还是右孩子：

```c
for (int c = i; t[c].parent != -1; c = t[c].parent)
    code[len++] = (t[t[c].parent].lchild == c) ? '0' : '1';
wpl += w[i] * len;
```

结点总数 M = 2N-1，前 N 个下标是叶子，后 N-1 个是合并产生的内部结点。
select_min 只在无父结点的结点中找权值最小者，已经被合并过的结点不会再被选中。
从叶子往根走得到的是逆序编码，需要反转后才是从根到叶子的编码。

## T4.21 N 皇后：思想与考点

N 皇后问题要在 n×n 棋盘上放 n 个皇后，使任意两个皇后不在同一行、同一列、同一对角线。
N 皇后用回溯法求解，回溯法就是深度优先搜索加剪枝。
用 x[r] 表示第 r 行皇后所在的列，N 皇后的解空间是排列树，各行天然不冲突，只需要检查列和对角线。
第 i 行和第 r 行的皇后同列的条件是 x[i] == x[r]，在同一对角线的条件是 |x[i]-x[r]| == r-i。
解空间树有子集树和排列树两种：子集树有 2^n 个叶子，排列树有 n! 个叶子；0-1 背包是子集树，N 皇后和旅行商问题是排列树。
8 皇后共有 92 个解，去掉旋转和对称后有 12 个基本解；4 皇后有 2 个解，n=2 和 n=3 无解。
回溯法求所有解或可行解，用深度优先；分支限界法求最优解，用广度优先或最小耗费优先。
其他典型回溯问题有图的 m 着色、哈密顿回路、0-1 背包、子集和、迷宫和数独。
回溯法的通用框架是：到达叶子则记录解；否则对每个选择先置入，约束函数和限界函数都满足才递归下一层。
非递归回溯用 r 表示当前行、x[r] 表示该行试到的列：本行有可放的列就前进 r++，本行所有列都试完就回溯 r--。

## T4.22 N 皇后：核心代码

```c
static int place_ok(int r) {
    for (int i = 0; i < r; i++)
        if (x[i] == x[r] || abs(x[i] - x[r]) == r - i) return 0;
    return 1;
}

static void backtrack(int r) {
    if (r == n) {
        count++;
        return;
    }
    for (int c = 0; c < n; c++) {
        x[r] = c;
        if (place_ok(r)) backtrack(r + 1);
    }
}
```

非递归写法：

```c
static int solve_iter(void) {
    int cnt = 0, r = 0;
    x[0] = -1;
    while (r >= 0) {
        x[r]++;
        while (x[r] < n && !place_ok(r)) x[r]++;
        if (x[r] < n) {
            if (r == n - 1) cnt++;
            else x[++r] = -1;
        } else {
            r--;
        }
    }
    return cnt;
}
```

递归出口是 r == n，表示前 n 行都已放好，得到一个解。
place_ok 是约束函数，只检查第 r 行与前 r 行是否冲突。
可行才递归进入下一行，不可行就剪枝，循环自动尝试下一列，这就是回溯。
非递归版进入下一行时要把下一行的列重置为 -1，表示还没有试过任何列。
非递归版中 r 小于 0 说明第 0 行也已试完，搜索结束。

## T4.23 活动安排问题

活动安排问题：每个活动占用时间 [s,f)，两个活动不重叠才相容，求最多能安排多少个互相相容的活动。
活动安排用贪心法：按结束时间升序排序，先选第一个，之后依次选开始时间不早于上一个已选活动结束时间的活动。
贪心的依据是结束得最早的活动给后面留下的时间最多，这是贪心选择性质。
按开始时间最早或按持续时间最短来选都不能保证最优，只有按结束时间最早才被证明是最优的。
时间复杂度由排序决定为 O(n log n)，排序之后一次扫描是 O(n)。
相容的判断条件是 s[i] >= last_end，首尾相接可以算相容，因为活动区间是半开区间。
11 个活动按结束时间排好后，开始时间为 1 3 0 5 3 5 6 8 8 2 12，结束时间为 4 5 6 7 9 9 10 11 12 14 16，最多可以安排 4 个活动。

```c
int chosen[N], cnt = 0, last_end = 0;
for (int i = 0; i < N; i++)
    if (s[i] >= last_end) {
        chosen[cnt++] = i;
        last_end = f[i];
    }
```

递归写法以上一个已选活动 k 为参数：

```c
static int rec_select(const int s[], const int f[], int k, int n, int chosen[], int cnt) {
    int m = k + 1;
    int last_end = (k < 0) ? 0 : f[k];
    while (m < n && s[m] < last_end) m++;
    if (m >= n) return cnt;
    chosen[cnt++] = m;
    return rec_select(s, f, m, n, chosen, cnt);
}
```

同类题型还有会议室安排、区间调度、区间选点和区间覆盖。

## T4.24 KMP 模式匹配：思想与考点

朴素匹配 BF 在失配时主串指针回退到本次起点的下一位，模式串回到开头，最坏时间复杂度为 O(n·m)。
KMP 在失配时主串指针不回溯，只让模式串指针回退，时间复杂度为 O(n+m)。
失败函数 pi[i] 是模式 P[0..i] 的最长相等真前缀与真后缀的长度，下标从 0 开始。
教材中的 next 数组下标从 1 开始：next[1]=0，next[j] 等于 P1 到 P(j-1) 中最长相等前后缀的长度加 1。
两种定义的关系是 next[j] = pi[j-2] + 1，其中 j 大于等于 2。
模式串 ABCDABD 的 pi 数组是 0 0 0 0 1 2 0，教材 next 数组是 0 1 1 1 1 2 3。
模式串 ababaa 的 next 数组是 0 1 1 2 3 4。
失配于 P[j] 时，下一步用 P[next[j]] 继续与当前主串字符比较；next[j]=0 表示主串指针前进一位、模式串从头开始。
nextval 是 next 的修正：若 P[next[j]] 等于 P[j]，则 nextval[j] = nextval[next[j]]，避免连续相同字符的无效比较。
在主串 BBC ABCDAB ABCDABCDABDE 中查找 ABCDABD，首次出现的下标是 15。

## T4.25 KMP 模式匹配：核心代码

```c
static void prefix_function(const char *p, int pi[]) {
    int m = strlen(p);
    pi[0] = 0;
    for (int i = 1, k = 0; i < m; i++) {
        while (k > 0 && p[i] != p[k]) k = pi[k - 1];
        if (p[i] == p[k]) k++;
        pi[i] = k;
    }
}

static int kmp_search(const char *t, const char *p) {
    int n = strlen(t), m = strlen(p), pi[MAXM];
    prefix_function(p, pi);
    for (int i = 0, k = 0; i < n; i++) {
        while (k > 0 && t[i] != p[k]) k = pi[k - 1];
        if (t[i] == p[k]) k++;
        if (k == m) return i - m + 1;
    }
    return -1;
}
```

教材写法的匹配循环，下标从 1 开始：

```c
int i = 1, j = 1;
while (i <= n && j <= m) {
    if (j == 0 || t[i - 1] == p[j - 1]) { i++; j++; }
    else j = next[j];
}
return j > m ? i - m - 1 : -1;
```

朴素匹配失配时的回退写法：

```c
if (t[i] == p[j]) { i++; j++; }
else { i = i - j + 1; j = 0; }
```

求 pi 数组时，失配就让 k 回退到 pi[k-1]，匹配则 k 加 1。
KMP 匹配时 i 只增不减，主串指针不回溯。
k == m 表示模式串全部匹配，起点下标为 i-m+1。
教材写法中 j == 0 或字符相等时，i 和 j 同时前进。

## T4.26 最大子段和：思想与考点

最大子段和问题：给定整数序列，求连续子段之和的最大值，约定全为负数时结果取 0。
序列 -2 11 -4 13 -5 -2 的最大子段和为 20，对应子段 11 -4 13。
暴力枚举所有子段并重新累加是 O(n³)，利用增量累加可降到 O(n²)。
分治解法把序列从中间分成左右两半，最大子段在左半、在右半，或者跨越中点，取三者最大。
跨越中点的最大子段和，等于左半中以 mid 结尾的最大和加上右半中以 mid+1 开头的最大和。
分治解法的递归式是 T(n)=2T(n/2)+Θ(n)，由主定理得 Θ(n log n)。
动态规划解法设 b[j] 为以 a[j] 结尾的最大子段和，b[j] = max(b[j-1], 0) + a[j]，答案是所有 b[j] 中的最大值。
动态规划解法的时间复杂度是 O(n)，只需一个变量滚动保存 b，空间复杂度是 O(1)。
序列 1 -2 3 10 -4 7 2 -5 的最大子段和是 18，对应子段 3 10 -4 7 2。

## T4.27 最大子段和：核心代码

```c
static int divide(const int a[], int lo, int hi) {
    if (lo == hi) return a[lo] > 0 ? a[lo] : 0;
    int mid = lo + (hi - lo) / 2;
    int left  = divide(a, lo, mid);
    int right = divide(a, mid + 1, hi);

    int s1 = 0, best1 = 0;
    for (int i = mid; i >= lo; i--) { s1 += a[i]; if (s1 > best1) best1 = s1; }
    int s2 = 0, best2 = 0;
    for (int i = mid + 1; i <= hi; i++) { s2 += a[i]; if (s2 > best2) best2 = s2; }

    return max3(left, right, best1 + best2);
}
```

```c
static int dp(const int a[], int n) {
    int best = 0, b = 0;
    for (int j = 0; j < n; j++) {
        b = (b > 0 ? b : 0) + a[j];
        if (b > best) best = b;
    }
    return best;
}
```

```c
/* O(n^2)：固定起点 i，向右增量累加 */
for (int i = 0; i < n; i++) {
    int s = 0;
    for (int j = i; j < n; j++) {
        s += a[j];
        if (s > best) best = s;
    }
}
```

分治出口是单个元素，元素为负数时按 0 处理。
前面累积的和不为正时就舍弃它，从 a[j] 重新开始。
最大值不一定出现在最后一个 b 上，所以要在循环中不断更新 best。

## T4.28 汉诺塔

汉诺塔有三根柱子，n 个盘子从 A 移到 C，每次只移动一个，任何时刻大盘子都不能压在小盘子上。
递归思路：先把上面 n-1 个盘子借助 C 从 A 移到 B，再把最大的盘子从 A 移到 C，最后把 n-1 个盘子借助 A 从 B 移到 C。
汉诺塔的移动次数满足 T(n) = 2T(n-1) + 1，T(0) = 0，解得 T(n) = 2^n - 1，是指数级。
汉诺塔的递归深度是 n，空间复杂度是 O(n)。
汉诺塔的子问题没有重叠，属于分治 / 递归，不适合用动态规划。
递归的两个要素是递归出口和递归式。

```c
static void hanoi(int n, char from, char via, char to) {
    if (n == 0) return;
    hanoi(n - 1, from, to, via);
    printf("move disk %d: %c -> %c\n", n, from, to);
    hanoi(n - 1, via, from, to);
}
```

第一次递归把 via 和 to 互换角色，第二次递归把 from 和 via 互换角色。
3 个盘子需要移动 7 次，4 个盘子需要移动 15 次。
非递归写法用栈保存待办任务，栈是后进先出，所以要按相反的顺序压栈：

```c
st[top++] = (Task){t.n - 1, t.via, t.from, t.to, 0};
st[top++] = (Task){t.n, t.from, t.via, t.to, 1};
st[top++] = (Task){t.n - 1, t.from, t.to, t.via, 0};
```

压栈顺序是先压第三步，再压移动最大盘，最后压第一步，这样出栈时第一步最先执行。
