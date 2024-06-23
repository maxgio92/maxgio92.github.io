---
Title: 'Unleashing the power of frame pointers pt.1 - The execution environment'
date: 2024-06-23T21:00:00+02:00
tags: [profiling, optimization, ebpf]
categories: [profiling]
slug: unleashing-power-frame-poiners-execution-environment
draft: false
---

Profiling the CPU allows us to analyze the program's performance, identify bottlenecks, and optimize its efficiency.

Have you ever wondered what happens behind the scenes when you run a program and how to account for CPU time for the actual program functions? And even more, how to write such a tool to profile the program?

Even though great open-source projects provide continuous profiling with vast support for compiled, JITed, and interpreted, languages, with or without debug info, with or without frame pointers, etc., don't be discouraged!

Writing your own can be a fantastic learning experience. Building your own profiler offers a unique challenge and the satisfaction of unlocking powerful performance analysis tools.

This blog series will embark on a journey to give you the basics for writing a program profiler.

In this first episode, we'll establish the foundation by exploring the program execution environment. We'll dig into how the CPU executes a program and keeps track of the execution flow. Finally, we'll discover how this tracking data is stored and becomes the key to unlocking the profiling primitives.

## Introduction

We know that the CPU executes the programs and that the program's binary instructions are stored in a volatile memory which is the random access memory.

As RAM locations are byte-addressable the CPU needs a way to keep track of the addresses in order to retrieve the data from it, which is in our case CPU instructions that are then executed.

The CPU uses small built-in memory areas called registers to hold data retrieved from the main memory. Registers come in two types: general-purpose and special-purpose. Special-purpose registers include pointer registers, which are designed specifically to store pointers, which means, they store the memory address's value.

There are other types of registers but they're out of scope for this walkthrough.

The first part will go through the main pointer registers, which are commonly implemented by the predominant architectures (x86, ARM, MIPS, PowerPC as far as I know).
So, please consider that these specifics may differ depending on the architecture.

## The good, the bad and the ugly pointer registers

### The program counter

The program counter (PC), often also called instruction pointer (IP) in x86 architectures, is a register that points to code, that is, the instruction that will be executed next. The instruction data will be fetched, will be stored in the instruction register (IR), and executed during the instruction cycle.
You can follow a diagram of a simplified instruction cycle in the picture below:

![cpu-pc-ir](https://raw.githubusercontent.com/maxgio92/notes/b76dfca9825c61c9d1d02c0eddf0b4619869185d/content/images/cpu-pc-ir-cycle.svg)

1. The CPU control unit (CU) read the value of the PC
2. It sends it to the CPU Memory Unit (MU)
3. The MU reads the instruction code from the memory at the address pointed to by the PC
4. The MU stores the opcode to the IR
5. The MU reads the opcode
6. The MU sends the opcode to the CU
7. The CU instructs the Register File (RF) to read operands - if available from registers, I'm simplifying - from general purpose registers (GPR)
8. The RF reads operands from GPRs
9. The CU sends them to the Arithmetic Logic Unit (ALU), which calculates and stores the result in its temporary memory
10. The CU requests the ALU to perform the arithmetic and logic operations
11. The RF reads the result from the ALU
12. The RF stores the AL result in GPRs

For example, considering a `CALL` instruction, this could be the flow considering the PC, the IR and the mainly involved general purpose registers to store the operands:

![cpu-pc-ir-call](https://raw.githubusercontent.com/maxgio92/notes/4979fc04a3da60187ea4e3175dfa8966abdf0fc6/content/images/cpu-pc-ir-cycle-2.svg)

Depending on the instruction set, the PC will be increased instruction by instruction by the instruction size (e.g. 8 bytes on 64 but Instruction Set Architectures).

In an executable file, the machine code to be executed by the CPU is usually stored in a dedicated section, depending on the executable format. For example, in ELF (Executable and Linkable Format) the machine code is organized in the `.text` section.

### The stack pointer

On the other side, the stack pointer (SP) and base pointer (BP) point to the stack, which contains data about the program being executed.

While a detailed explanation of the stack is beyond the scope of this blog, here's a basic idea: it's a special area of memory that the CPU uses to manage data related to the program's functions (subroutines) as they are called and executed, pushing it to it in a LIFO method. We'll see later on in more detail.

Data and code are organized in specific regions inside the process address space. It's constantly updated by the CPU on push and pop operations on the stack. The stack pointer is usually set by the OS during the load to point to the top of the stack memory region.

As the stack grows whenever the CPU adds new data while executing the program's instructions, the stack pointer decrements and is always at the lowest position in the stack.
> Remember: the stack grows from the highest address to the lowest address:
> 
> ![mem-stack-code-heap](https://raw.githubusercontent.com/maxgio92/notes/faf4b0c39f4a1e2e84a3bb497729fa5863aed5ed/content/images/mem-stack-code-heap.svg)

So, when a new variable of 4 bytes is declared, the stack pointer will be decreased by 4 bytes too.

For instance, considering a C function that declare a local variable:

``` c
void myFunction() {
  int localVar = 10; // Local variable declaration
  // Use localVar here
}
```

the simplified resulting machine code could be something like the following: 

```assembly
; Allocate space for local variables (assuming 4 bytes for integer)
sub  rsp, 4               ; Subtract 4 from stack pointer (SP) to reserve space

; Move value 10 (in binary) to localVar's memory location
mov  dword ptr [rsp], 10  ; Move 10 (dword = 4 bytes) to memory pointed to by SP (stack top)

; ...

; Function cleanup (potential instruction to restore stack space)
add  rsp, 4              ; Add 4 back to stack pointer to deallocate local variable space
```

> **Clarification about the register names**
>
> You'll find different names for these pointer registers depending on the architectures. For example for x86:
> * On 16-bit architecture are usually called `sp`, `bp`, and `ip`.
> * Instead on 32-bit `esp`, `ebp`, and `eip`.
> * Finally, on 64-bit they're usually called `rsp`, `rbp`, and `rip`.

Specifically, a stack pointer (SP) points to the first free and unused address on the stack.
It can reserve more space on the stack by adjusting the stack pointer like in the previous code example.

As a detail, a more concise way could be to use `push` that combines the decrement of the SP (i.e. by 4 bytes) and the store of the operand (i.e. the integer `10`) at the new address pointed to by the SP.

### The base pointer

The base pointer (BP) is set during function calls by copying the current SP. The BP is a snapshot of the SP at the moment of the function call (e.g. when the CPU fetches a `call` instruction), so that function parameters and local variables are accessed by adding and subtracting, respectively, a constant offset from it.

Moreover when a new function is called a new space in the stack dedicated to the new function is created and some data like declaration of local variables is pushed.

This memory space dedicated to these subroutines are the stack frames, so each function will have a stack frame. You can find a simple scheme of stack frames with the main data pushed to the stack in the picture below:

![memory-sp-bp](https://raw.githubusercontent.com/maxgio92/notes/99171626abe0c24cf00a66c480287d4701ec61df/content/images/memory-sp-bp.svg)

Please bear in mind that the stack layout can vary based on the ABI calling convention and the architecture.

We'll now go through the call path and see which data is also pushed to the stack, which is used to keep track of the execution path.

## The call path

When a new function is called the previous base pointer (BP) is also pushed to the new stack frame.

While this is usually true, it's not mandatory and it depends on how the binary has been compiled. This mainly depends on the compiler optimization techniques.

In particular, CALL instruction pushes also the value of the program counter at the moment of the new function call (next instruction address), and gives control to the target address. The program counter is set to the target address of the `CALL` instruction, which is, the first instruction of the called function.

In a nutshell: the just pushed return address is a snapshot of the program counter, and the pushed frame pointer is a snapshot of the base pointer, and they're both available in the stack.

As a result, control is passed to the called subroutine address and the return address, that is the address of the instruction next to `CALL`, is available on the stack.

The following diagram wrap ups what's been discussed until now:

![pc-sp-bc-stack-code](https://raw.githubusercontent.com/maxgio92/notes/352907a2c42b9f695d0a97e6cd8d3e95977d024d/content/images/pc-sp-bc-stack-code.svg)

## The return path

On the return path from the function, `RET` instruction `POP`s the return address from the stack and puts it in the program counter register. So, the next instruction is available from that return address.

Since the program counter register holds the address of the next instruction to be executed, loading the return address into the PC effectively points the program execution to the instruction that follows the function call. This ensures the program resumes execution from the correct location after the function is completed.

![stack-frames](https://raw.githubusercontent.com/maxgio92/notes/14bdde325f646b53ee0b6501f0ba9d3ecbaded4f/content/notes/memory-stack-frames.png)
> Credits for the diagram to the [Learn WinDbg](http://www.windbg.xyz/windbg/article/202-Typical-x86-call-stack-example) website.

In the case of a function calling a function, the program counter returns to the return address in the previous stack frame and starts executing from there.

Because all of the above points need to be memorized on the stack, the stack size will naturally increase, and on return decrease. And of course, the same happens to the stack and base pointers. Naturally, the stack is protected by a guard to avoid the stack overflow accessing unexpected area of memory.

As I'm a visual learner, the next section will show how the program's code and data are organized in its process address space. This should give you a clearer picture of their layout within the process's address space.

## The address space regions

The process address space is a logical view of memory managed by the operating system, hiding the complexity of managing physical memory.

While explaining how memory mapping implementations work in operating systems is out of scope here, it's important to say that user processes see one contiguous memory space thanks to the memory mapping features provided by the OS.

The address space is typically divided into different regions, and the following names are mostly standard between the operating systems:
* Text segment: this is the area where the (machine) code of the program is stored
* Data segment: this region contains typically static variables which are initialized
* BSS (Block Started by Symbol) segment: it contains global and static variables that are not initialized when the program starts.
Because the data would be a block of zeros, the BSS content is omitted in the executable file, saving space. Instead, the program headers allow the loader to know how much space to allocate for the BSS section in virtual memory and it filled it out with zeros. That's why, despite uninitialized data being data, is not placed in the data section.
* Heap: it's a region available for dynamic allocation available to the running process. Programs can request pages from it at runtime (e.g. `malloc` from the C standard library).
* Stack: we already talked about it.

The next diagram will show the discussed memory regions starting from the physical perspective to the perspective of the single virtual address space of a program process:

![memory-regions-stack-instructions](https://raw.githubusercontent.com/maxgio92/notes/68c5220995702493845a3d96cc9d6dc7ce61ec8f/content/notes/memory-regions-allocations.jpg)
> Credits for the diagram to [yousha.blog.ir](https://yousha.blog.ir/).

The operating system can enforce protection for each of them, like marking the text section read-only to prevent modification of the running program's instructions.

When a program is loaded into memory, the operating system allocates a specific amount of memory for it and dedicates specific regions to static and dynamic allocation. The static allocation includes the allocation for the program's instructions and the stack.

Dynamic allocations can be handled by the stack or the heap. The heap usually acquires memory from the bottom of the same region and grows upwards towards the middle of the same memory region.

![memory-regions](https://raw.githubusercontent.com/maxgio92/notes/b64ccd53d5c3a07969dd70f1a5a394c04edd8c35/content/images/memory-regions.svg)

## Program loading in Unix-like OSes

On program execution (Unix-like `fork` and `exec` system call groups) OS allocates memory to later store the program's code and data.
The `exec` family of system calls replaces the program executed by a process.
When a process calls `exec`, all sections are replaced, including the `.text` section, and the data in the process are replaced with the executable of the new program.

In particular, the loader parses the executable file, decides which is the base address, allocates memory for the program segments based on the base address, loads the segments in memory, and prepares the execution environment.

Once the loader completes its tasks, it signals the kernel the program is ready. The kernel sets the process context and the PC to the first instruction in the `.text` section, which is fetched, decoded, and executed by the CPU.

![memory-map-exec](https://raw.githubusercontent.com/maxgio92/notes/d3bf6f231c330ba746354cc463469245fc9de7bc/content/notes/memory-map-exec.png)
> Credits for the diagram to the [Uppsala University](https://www2.it.uu.se/edu/course/homepage/os/vt19/module-2/exec/).
> I haven't managed yet to find where the information about how to set up the stack at exec time from an ELF file is stored in the ELF structure. If you do, feel free to share it!

Moreover, as a detail, although all data is replaced, all open file descriptors remain open after calling exec unless explicitly set to close-on-exec.

If you want to go deeper on the Linux `exec` path, I recommend [this chapter](https://github.com/0xAX/linux-insides/blob/f7c6b82a5c02309f066686dde697f4985645b3de/SysCall/linux-syscall-4.md#execve-system-call) from the [Linux insides](https://0xax.gitbooks.io/linux-insides/content/index.html) book.

Now let's get back to the main characters of this blog, which are the pointer register. We mentioned that the base pointer is also called the frame pointer, indeed it points to a single stack frame. But, let's see how they're vital for CPU profiling.

<!--
### References: the ELF structure

Digging into the ELF format you can find below the structure of this executable and linkable format:

![elf-structure](https://raw.githubusercontent.com/maxgio92/notes/20f4417f50afb71a79a8712decea1f76ffc16cc9/content/notes/elf-dissection.avif)

For more information please refer to the man of file formats and conventions for elf (`man 5 elf`).
-->

## Frame pointer and the stack walking

I've read more often the name _frame pointer_ than _base pointer_, but actually the frame pointer *is* the base pointer.

As already discussed, the name base pointer comes to the fact that is set up when a function is called and is pushed to the new stack frame, to establish a fixed reference (base) to access local variables and parameters within the function's stack frame.

What is pushed to the stack are also the parameters, but depending on the ABI, they can be passed either on the stack or via registers. For instance:
* x86-64 System V ABI: in the general purpose registers `rdi`, `rsi`, `rdx`, `rcx`, `r8`, and `r9` for the first six parameters. On the stack from the seventh parameter onward.
* i386 System V ABI: in the general purpose registers `eax`, `ecx`, `edx`, and `ebx` for the first four parameters. On the stack from the fifth parameter onward.

In general, the data that is commonly stored on the stack is:
- the return address
- the previous frame pointer
- saved register state
- the local variables of the function.

![memory-sp-bp-3](https://github.com/maxgio92/notes/raw/95038de4ae46e0b980cfbdbae35817132b3afffd/content/images/memory-sp-bp-3.svg)

> Remember: the return address is a snapshot of the program counter, so it points to instructions (code).
The previous frame pointer is a snapshot of the base pointer, so it points to the stack (data).

Below the local variables are other stack frames resulting from more recent function calls, as well as generic stack space used for computation and temporary storage. The most recent of these is pointed to by the stack pointer. This is the difference between the stack pointer and the frame/base pointer.

However, the frame pointer is not always required. Compiler optimization technique can generate code that just uses the stack pointer.

Frame pointer elimination (FPE) is an optimization that removes the need for a frame pointer under certain conditions, mainly to reduce the space allocated for the stack and to optimize performance because pushing and popping the frame pointer takes time during the function call. The compiler analyzes the function's code to see if it relies on the frame pointer for example to access local variables, or if the function does not call any other function. At any point in code generation, it can determine where the return address, parameters, and locals are relative to the stack pointer address (either by a constant offset or programmatically).

Frame pointer omission (FPO) is instead an optimization that simply instructs the compiler to not generate instructions to push and pop the frame pointer at all during function calls and returns.

> If you're interested in the impacts of libraries compiled and distributed with this optimization I recommend the following Brendan Gregg's great article: [The Return of the Frame Pointers](https://www.brendangregg.com/blog/2024-03-17/the-return-of-the-frame-pointers.html).

Because the frame pointer is pushed on function call to the stack frame just created for the newly called function, and its value is the value of the stack pointer at the moment of the `CALL`, it points to the previous stack frame.

A fundmental data needed by CPU profilers is to build stack traces, to understand the execution flow of a program and calculate the time spent for each trace and function.

One standard technique to build a stack trace is by walking fhe stack.
And one technique to walk the stack is to follow the linked list of the saved frame pointers, beginning with the value hold by the base pointer register.

Because a `RET` (function returns) pops a stack frame out of the stack, when consequent `RET`s reach the top of the stack, which is the stack frame of the main function, a stack trace is complete. The same goes on and on with subsequent chains of call-returns that reach the top of the stack.

You can see it in the following picture a simplified scheme of the linked list of frame pointers:

![stack-walking](https://raw.githubusercontent.com/maxgio92/notes/5eeff1703e85c00799e7af0117a3898918d7a438/content/notes/stack-walking.avif)
> I didn't manage to find the author of this diagram. If you do, please let me know so that I can give the right credits, thank you.

This technique is particularly useful for profilers and debuggers. The following is a basic example of what a profiler could retrieve, leveraging frame pointers:

```shell
$ ./my-profiler run --pid 12345
 2.6%     main.main;runtime.main;runtime.goexit;
65.3%     main.foo;runtime.main;runtime.goexit;
32.1%     main.bar;runtime.main;runtime.goexit;
```

And this comes to the next episode of this series, which will dive into how to write a basic low-overhead, kernel-assisted CPU profiler leveraging eBPF, that will produce a result like the one above!

I hope this has been interesting to you. Any feedback is more than appreciated.

See you in the next episode!

