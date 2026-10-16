#ifndef COMMON_H
#define COMMON_H

#include <stdio.h>
#include <stdlib.h>

/* 断言失败时打印位置并以非零状态退出，供 make test 判定 */
#define CHECK(cond)                                                      \
    do {                                                                 \
        if (!(cond)) {                                                   \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            exit(1);                                                     \
        }                                                                \
    } while (0)

static inline void print_array(const char *label, const int a[], int n) {
    printf("%s:", label);
    for (int i = 0; i < n; i++) printf(" %d", a[i]);
    printf("\n");
}

static inline int is_sorted(const int a[], int n) {
    for (int i = 1; i < n; i++)
        if (a[i - 1] > a[i]) return 0;
    return 1;
}

#endif
