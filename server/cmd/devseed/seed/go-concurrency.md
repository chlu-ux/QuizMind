# Go 并发编程笔记

## goroutine

goroutine 是 Go 运行时管理的轻量级线程，初始栈大小只有几 KB，可以按需增长。创建成千上万个 goroutine 在 Go 中是很常见的做法，因为它们的调度开销远小于操作系统线程。使用 go 关键字即可启动一个新的 goroutine，主函数返回时所有未结束的 goroutine 会被直接终止。

## channel

channel 是 goroutine 之间通信的管道，遵循「通过通信来共享内存」的理念。无缓冲 channel 的发送操作会阻塞，直到有接收者准备好接收数据。带缓冲的 channel 在缓冲区未满时发送不会阻塞。关闭 channel 后仍然可以从中读取剩余的数据，但向已关闭的 channel 发送数据会引发 panic。

## sync.Mutex

sync.Mutex 提供互斥锁，保证同一时刻只有一个 goroutine 能进入临界区。使用 Lock 加锁、Unlock 解锁，通常配合 defer 确保锁一定会被释放。Mutex 在第一次使用后不能被复制，否则会破坏锁的状态。sync.RWMutex 允许多个读者同时持有读锁，但写锁是独占的。

## context

context 包用于在 goroutine 之间传递取消信号、截止时间和请求范围的值。context.WithCancel 返回一个可以手动取消的上下文，context.WithTimeout 则会在超时后自动取消。按照惯例，context 应该作为函数的第一个参数传入，并且不要把它存放在结构体中。

## sync.WaitGroup

sync.WaitGroup 用于等待一组 goroutine 结束。调用 Add 增加计数，每个 goroutine 结束时调用 Done 减少计数，Wait 会阻塞直到计数归零。Add 必须在启动 goroutine 之前调用，否则可能出现 Wait 提前返回的竞态。

## 竞态检测

Go 提供了内置的竞态检测器，在运行测试或构建时加上 -race 参数即可启用。竞态检测器会在运行时监控内存访问，发现数据竞争时输出详细的堆栈信息。它会让程序变慢并占用更多内存，所以通常只在测试和调试阶段使用，不建议在生产环境长期开启。
