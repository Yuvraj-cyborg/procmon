import Testing
@testable import Procmon

@Suite struct ThreadStackTests {
    private let report = """
        Sampling process 42 for 1 second with 1 millisecond of run time between samples

        Call graph:
            865 Thread_10150   DispatchQueue_1: com.apple.main-thread  (serial)
            + 865 start  (in dyld) + 6992  [0x18b2304e4]
            +   865 NSApplicationMain  (in AppKit) + 880  [0x18fab97b0]
            +     700 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x18b6b9108]
            +     ! 700 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x18b5b7c34]
            +     165 -[Worker compute]  (in Demo) + 40  [0x100001000]
            865 Thread_10238: com.apple.NSEventThread
            + 865 thread_start  (in libsystem_pthread.dylib) + 8  [0x18b5f6c1c]
            +   865 -[Store save]  (in Demo) + 12  [0x100002000]
            +     865 __psynch_mutexwait  (in libsystem_kernel.dylib) + 8  [0x18b5b9f10]
            865 Thread_13349
            + 865 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x18b5f6c10]
            +   865 xpc_connection_send_message_with_reply_sync  (in libxpc.dylib) + 200  [0x18b2e0000]
            +     865 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x18b5b7c34]

        Total number in stack (recursive counted multiple times) = 3
        """

    @Test func readsEachThreadsDominantStack() throws {
        let stacks = ThreadStacks.parse(report)
        #expect(stacks.count == 3)
        let main = try #require(stacks[ThreadID(raw: 10150)])
        #expect(main.name == "com.apple.main-thread")
        #expect(main.frames.map(\.symbol) == ["start", "NSApplicationMain", "__CFRunLoopServiceMachPort", "mach_msg2_trap"])
        #expect(main.frames.last?.library == "libsystem_kernel.dylib")
        #expect(main.samples == 700)
        #expect(main.total == 865)
        #expect(stacks[ThreadID(raw: 10238)]?.name == "com.apple.NSEventThread")
        #expect(stacks[ThreadID(raw: 13349)]?.name == nil)
    }

    @Test func classifiesWhatThreadsWaitOn() {
        let stacks = ThreadStacks.parse(report)
        #expect(stacks[ThreadID(raw: 10150)]?.activity == .idle)
        #expect(stacks[ThreadID(raw: 10238)]?.activity == .waitingForLock)
        #expect(stacks[ThreadID(raw: 13349)]?.activity == .waitingForReply)
        #expect(ThreadStacks.classify([StackFrame(symbol: "hash", library: "Demo")]) == .running("hash"))
        #expect(ThreadStacks.classify([StackFrame(symbol: "usleep", library: nil), StackFrame(symbol: "__semwait_signal", library: nil)]) == .sleeping)
        #expect(ThreadActivity.waitingForLock.mayBeStuck)
        #expect(!ThreadActivity.idle.mayBeStuck)
    }
}
