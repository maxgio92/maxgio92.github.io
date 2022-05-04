---
title: "Introduction to the Linux Scheduler"
date: 2022-05-02T18:36:15+02:00
tags: [linux, scheduler]
categories: [linux]
draft: false
---

Two years ago more or less I started my journey in Linux. I was scared at first and I didn't know where to start from.
But then I decided to start from a [book](https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468) in order to be introduced by following a prepared path. During the journey I integrated the material with up-to-date documentation from [kernel.org](https://docs.kernel.org). In the meantime I started to learn C a bit so that I also could have [played](https://github.com/maxgio92/linux/tree/syscall/maxgio) with what I was learning, step by step.

One of the things I was fascinated by was how Linux is able to manage and let the CPU run thousands and thousands of processes each second.
To give you an idea, just now Linux on my laptop configured with an Intel i7-1185G7 CPU within only one second did 28,428 context switches! Isn't that fantastic?

```shell
$ perf stat -e sched:sched_switch --timeout 1000
 Performance counter stats for 'system wide':
            28,428      sched:sched_switch
       1.001137885 seconds time elapsed
```

During this journey inside Linux, I've written notes as it helps me to digest and re-process the informations I learn in my own way. And I though: "why not sharing them? Maybe they're useful to someone!".

## Resource sharing is the key!

So let’s dive into the part of Linux which is responsible of doing such great work. In order to do it start by imaging what we would generally expect from an operating system. Let's say that from an operating system we’d want to run tasks that we need to complete, providing it hardware resources.

Tasks come of different natures but we can simply categorise them as CPU intensive and interactive ones.
Something should provide the efficiency of tasks completion and responsiveness.
Consider a typewriter that prints letters with one second of delay, it would be impossible to use!
So, in few words I would like to say to the scheduler: “I want to execute this task and I want it’s completed when I need or to respond when I need”.
The goal of a scheduler is to decide “what runs next” leading to have the best balance between the needings of the different natures of the tasks.

The completely fair scheduler (CFS) comes from Linux, as the replacement of the O(1) scheduler from the 2.6.23, with the aim to guarantee best fairness of CPU owning by the tasks, and at the same time tailoring to a broad nature range of tasks.

As as a side note consider that the Linux scheduler is made of different scheduler classes, of which the CFS is the default one.

Interactive tasks would run for small amounts of time but need to run quickly as events happen. CPU-intensive tasks don’t require to complete ASAP, but require CPU time.
Based on that, time accounting is what guarantees fairness in Linux CFS scheduler as long as the task who run for less time will run next.

## Time accounting

This comes to the time accounting, which is implemented by measuring the task execution time (stored in the [scheduler entity](TODO:link) structure as `delta_exec`) weighted by the number of runnable processes and its [niceness](https://www.kernel.org/doc/html/latest/scheduler/sched-nice-design.html) value - more on scheduler structures in this [blog](https://josefbacik.github.io/kernel/scheduler/2017/07/14/scheduler-basics.html).

The result is the so called virtual runtime, which is a member of the Scheduler entity structure. A scheduler entity can be a task or a group of tasks, like a control group (more on entities tracking [here](https://lwn.net/Articles/531853/)).

This value is updated via `update_curr()` function, which is called whenever a task becomes [runnable](TODO:link) and periodically by the [system timer](TODO:link).

So, how this accounting is honoured in the process selection in the scheduler in order to guarantee fairness of execution?

## Process selection

The processes eligible to run (which are in a runnable state) are put in a run queue, which is implemented as a [red black self-balancing binary tree](TODO:link) that contains task structures ordered by `vruntime`.
Consequently, the `vruntime` is the binary tree key and the task with the smallest `vruntime` is picked by `__pick_next_entity()`.

As a detail, in order to provide efficiency and to not need to traverse the whole tree every time a scheduling is needed, as the element in an ordered red black tree that is leftmost is the element with minor key value (i.e. the `vruntime`) a cache is easily keeped as `rb_leftmost` variable in the runqueue (TODO:check) structure.

But, how the runqueue is populated? When a new task is added do the runqueue?
- when a `clone()` is called, and
- when a task wakes up after having slept via `try_to_wake_up(`) function call

via `enqueue_entity()`.

Furthermore, the next question is: when a task is removed from the runqueue?
- When a task explicitly `exit()`s
- When a task explicitly or implicitly `sleep()`

via `dequeue_entity()`.

Later I’ll expand on enqueue_entity() and dequeue_entity().

In both cases the `rb_leftmost` cache is updated and replaced it with `rb_next()` result.

## Scheduler entrypoint

Now that we have a runqueue populated, how the scheduler picks one task from there?

`schedule()` calls `pick_next_task()` which picks the highest priority scheduler class which return the highest priority task.
The CFS is the highest-priority of the scheduler classes by default and `pick_next_entity()` function internally calls its implementation of `pick_next_entity()` that calls the `__pick_next_entity()` function.
Then, `schedule()` calls `context_switch()` that switches to the returned task.

And this comes to one of the next topics: context switch. But before talking about it let’s continue talking about the life of a task.

Let’s imagine that we are in process context and that our task is now running.
Not all tasks complete from the time have being scheduled.
For example tasks waiting for events (like for keyboard input or for file I/O) can be put to sleep, and also are in interruptible/uninterruptible state so that aren’t picked from the runqueue.

## Sleep and wake up

A task can decide to sleep but something then is needed to wake it up. We should also consider that multiple tasks can wait for some event to occur.

A wait queue (of type `wait_queue_head_t`) is implemented for this purpose as a list of tasks waiting for some events to occur.
It allows tasks to be notified when those events occur, generally from what generates the event itself.
As for almost all data structures in Linux, It can be declared statically or dynamically.

A task can put itself to sleep as below:
- create a wait queue via the `DECLARE_WAIT()` macro
- add the task to it via `add_wait_queue()` function call
- set its state to interruptible/uninterruptible via `prepare_to_wait()` function call
- call `schedule()` which in turn removes the task from the runqueue via `deactivate_task()`.

It can also do it nonvoluntarily waiting for semaphores.

Then ` wake_up()` (which calls `try_to_wake_up()`) is there to wake all processes in a wait queue when the associated event occurs. `try_to_wake_up()` does the work that consists of:
- set task state to running
- `activate_task()` adds the task to the runqueue via `enqueue_task()`
- sets `need_resched` flag on current task if the awakened task has higher priority than the current one (we’ll talk about this flag later)
- `schedule()`
- `__remove_wait_queue()` removes the task from the wait queue.

Also signals can wake up interruptible tasks (set task state).
The task code itself should then manage spurious wake up by checking the event that occurs or manage the signal, for example `notify` does it.

## Context switch and Preemption

When a task starts to sleep a context switch is needed, and the next task is voluntarily picked and the scheduling is done via `schedule()`.

The context switch work is done by `context_switch()`, called by `schedule()` and does:
- `switch_mm()` to switch virtual memory mappings process-specific.
- `switch_to()` to save and restore stack informations and all registers which contain process-specific data.

The context switch is requested by the tasks themselves voluntarily or by the scheduler, nonvoluntarily from the point of view of a task.

### Voluntarily

A task can trigger context switch via `schedule()` in kernelspace, through:
- `sleep()` which creates and add task to the wait queue, set task state interruptible/uninterruptible, and`schedule()` removes the task from the runqueue via `deactivate_task()`
- `try_to_wake_up()` which sets the task state to running, `activate_task()` adds the task to the runqueue and `schedule()`, `_remove_wait_queue()` to remove it from the wait queue
- when it blocks, which implicitly results into a `schedule()` call.

Context switches are not done only when code in kernelspace voluntarily calls `schedule()`, otherwise tasks could monopolise a CPU, so an external component should intervene.

### Nonvoluntary but fair context switch

As the main Linux scheduler class is a fair scheduler the fairness must be guaranteed in some way... Ok, but how?

For this purpose a flag named `need_reschedule` is present in the task struct and is set or unset on the current task to notify that it should leave the CPU which in turn, after `schedule()` call, will switch to another process context.

So, when this flag is set?
- `scheduler_tick()`, which is constantly called by the [timer interrupt](TODO:link) handler, continuously checks `vruntime` and sets it when a preemption is needed.
- `try_to_wake_up()`, when the current task has minor priority than the awakened.

Instead, in order to clarify when the flag is checked we can think about when a task preemption is needed and consequently a context switch would be done.

##### In userspace

Returning from kernelspace to userspace is safe to context switch: has this userspace task still to run? Maybe it’s no longer fair to run it. This is what happens when:
- system calls
- interrupt handlers

return to userspace.

If `need_resched` is set a schedule is needed, the next entity task is picked, and context switch done.

> As a note, consider that both these paths are architecture dependent.

##### In kernel space

A note deserves to be explained. The kernel is fully preemptive from 2.6 that is, a task can be preempted as long as the kernel is in a safe state.

When preemption can’t be done, locks are in place to mark it, so that a safe state is defined when the kernel doesn’t hold a lock.

Basically a lock counter (`preempt_count`) is added to `thread_info` struct to let preempt tasks running in kernelspace only when it’s equal to zero.

Upon return from interrupt (e.g. the timer one [TODO:link]) if returning to kernelspace. If `need_resched` set + `preempt_count` = 0 the current task is preempted, otherwise the interrupt returns to the interrupted task.
Everytime `preempt_count` is updated and decreased to zero, and `need_resched` is set to true, preemption is done.

Also, the kernel is SMP-safe that is, a task can be safely restored in a symmetrical multi processor.

You can check in the kernel version by running `uname -v`.

```
$ uname -v
#1 SMP PREEMPT Wed, 27 Apr 2022 20:56:11 +0000
```

That’s all folks!

# Thank you!

I hope this was interesting for you as it was for me. Please feel free to reach out for everytihng!

# Links

- https://lwn.net/Articles/531853/
- https://mechpen.github.io/posts/2020-04-27-cfs-group/index.html#2.2.-data-structures
- https://josefbacik.github.io/kernel/scheduler/2017/07/14/scheduler-basics.html
- https://www.kernel.org/doc/html/latest/scheduler/index.html