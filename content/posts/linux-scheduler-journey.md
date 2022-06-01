---
title: "A journey into the Linux scheduler"
date: 2022-05-02T18:36:15+02:00
tags: [linux, scheduler]
categories: [linux]
draft: false
---

Two years ago more or less I started my journey in Linux. I was scared at first and I didn't know where to start from.
But then I decided to buy a [book](https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468) - and what a book! - in order to follow a path.

Along the way I integrated the material with up-to-date documentation from [kernel.org](https://docs.kernel.org) and [source code](https://elixir.bootlin.com/linux/v5.17.9/source). In the meantime I started to learn C a bit so that I also could have [played](https://github.com/maxgio92/linux/tree/syscall/maxgio) with what I was learning, step by step.

One of the things I was fascinated by was how Linux is able to manage and let the CPU run thousands and thousands of processes each second.
To give you an idea, just now Linux on my laptop configured with an Intel i7-1185G7 CPU within only one second did 28,428 context switches! That’s fantastic, isn’t it?

```shell
$ perf stat -e sched:sched_switch --timeout 1000
 Performance counter stats for 'system wide':
            28,428      sched:sched_switch
       1.001137885 seconds time elapsed
```

During this journey inside Linux, I've written notes as it helps me to digest and re-process in my own way the informations I learn. Then I though: "Maybe they're useful to someone. Why not sharing them?”.

So here I am with with a blog.

### Table of contents

1. [Introduction](#1-resource-sharing-is-the-key)
2. [Time accounting](#2-time-accounting)
    1. [The runtime](#the-runtime)
    2. [The virtual runtime](#the-virtual-runtime)
    3. [The schedule entities](#the-schedule-entities)
    4. [The weight](#the-weight)
    5. [Update of the virtual runtime](#update-of-the-virtual-runtime)
3. [Tasks selection](#3-tasks-selection)
    1. [The runqueues](#the-runqueues)
    2. [Wrapping up the structures](#wrapping-up-the-structures)
    3. [Weight for task groups](#weight-for-task-groups)
    4. [Wrapping up the time accounting](#wrapping-up-the-time-accounting)
    5. [Runqueues population](#runqueues-population)
    6. [The scheduler entrypoint](#the-scheduler-entrypoint)
4. [Sleep and wake up](#4-sleep-and-wake-up)
    1. [Sleep](#sleep)
    2. [Wake up](#wake-up)
        1. [Signals](#signals)
5. [Context switch and preemption](#5-context-switch-and-preemption)
    1. [Voluntarily](#voluntarily)
    2. [Nonvoluntary: preemption](#nonvoluntary-preemption)
        1. [User space](#user-space)
        2. [Kernel space](#kernel-space)
6. [Wrapping up](#wrapping-up)
---

## 1. Resource sharing is the key!

Let’s dive into the Linux component which is responsible of doing such great work: the scheduler.

In order to do it imagine what we would expect from an operating system. Let's say that we’d want it to run tasks that we need to complete, providing the OS hardware resources.
Tasks come of different natures but we can simply categorise them as CPU intensive and interactive ones.

Something should provide the efficiency of tasks completion and responsiveness. Consider a typewriter that prints letters with 1s second of delay, it would be impossible to use!
So, in few words I would like to request to the scheduler: “I want to execute this task and I want it’s completed when I need or to respond when I need”.
The goal of a scheduler is to decide “what runs next” leading to have the best balance between the needings of the different natures of the tasks.

As Linux is a *preemptive multitasking* operating system, the completely fair scheduler (CFS) came to Linux, as the replacement of the O(1) scheduler from the 2.6.23, with the aim to guarantee fairness of CPU owning by the tasks, and at the same time tailoring to a broad nature range of tasks. The algorithm complexity saw an improvement from O(1) to O(log N).

As a side note consider that the Linux scheduler is made of different [scheduler classes](https://www.kernel.org/doc/html/v5.17/scheduler/sched-design-CFS.html#scheduling-classes) ([code](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L2117)), of which the [CFS class](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L11737) is the highest-priority one. Another one is the [real time](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/rt.c#L2642) scheduler class, tailored as the name suggests for tasks that need responsiveness.

Interactive tasks would run for small amounts of time but need to run quickly as events happen. CPU-intensive tasks don’t require to complete ASAP, but require CPU time.
Based on that, time accounting is what guarantees fairness in Linux CFS scheduler as long as the task who run for less time will run next.

This comes to the time accounting, so let's start to dig into it! 

---

## 2. Time accounting

Linux CFS actually does not directly assign timeslices to tasks as the O(1) scheduler did, instead it measures execution time, in order to be flexible with respect to both interactive and processor-intensive tasks.

### The runtime

Remember, the fundamental rule in the Completely Fair Scheduler is: *the task that ran less, will run next*! Which is, each task should have his fair slice of the processor time, *when it needs*!
For example, interactive tasks can run frequently but for less time than intensive ones, and still have their fair amount of CPU time.

The implementation is written in the [`update_curr()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L844) function, which is called periodically to account tasks for the CPU time they used in the last period ([`delta_exec`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L853)).

### The virtual runtime

The execution time is [further weighted](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L870) to implement priority between tasks. This is done by the [fair delta calculation](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L233). The more the weight, the more the time the task will have.

#### Example

Let' do an example with timeslices: considering a single CPU, if every T time period two tasks A and B run respectively with a weight of 1 and 2, the allocated CPU time is obtained by multiplying T by the ratio of the weight to the sum of the weights of all running tasks:

```
CPU_timeslice(A) = T * (1 / (1 + 2))).
CPU_timeslice(B) = T * (2 / (1 + 2))).
```

For each T time period, task A will run for 0.334~T and task B 0.667~T.

> This is what is calculated [here](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L710).

#### Implementation

Coming to the actual implemenation, the CFS class accounts tasks for their real execution time considering their weight, which is ensured by periodically measuring the `runtime` and multiplying it by the ratio `weight/(base weight)`.

```
runtime += runtime * (w / base w)).
```

Which is exactly what is done in [`update_curr()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L844):

```
static void update_curr(struct cfs_rq *cfs_rq)
{
	struct sched_entity *curr = cfs_rq->curr;
	...
	delta_exec = now - curr->exec_start;
	...
	curr->vruntime += calc_delta_fair(delta_exec, curr);
	...
}
```

And the result is the so called virtual runtime ([`vruntime`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L547)).

As the weight implementation [depends](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L873) on the nature of the schedulble entities, let's spend a couple of words about them.

> Indeed, the [`vruntime`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L547) is a member of the [`sched_entity`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L538) structure.

Then, we'll talk more about the runtime weight.

### The schedule entities

Until now we talked about tasks as the only schedulable entity but actually, tasks can be put into group of tasks, in order to treat a group equally to a single task, and have the group share the resources (I.e. CPU) between the entities of the group without afflicting the overall system.
That’s the case of [cgroups](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L877) and why they’re there.

Also, task groups can be composed of other groups, and there is a root group.
In the end a running Linux is likely going to manage a hierarchy tree of schedule entities.
So when a task should be [accounted for time](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L11153), also the [parent group's entity](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L11158) should be, and so on, [until the root group'entity](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L282) is found.

> Consider that the [`sched_entity`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L538) structure is the structure that tracks informations about the scheduling, like the [`vruntime`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L547), and it refers to tasks or tasks group structures. As they track scheduling data, they are per-CPU structures. Instead, [`task_struct`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L728) and [`task_group`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L391) structures, are global.

And this comes to the weight.

### The weight

We said before that the weight implementation depends on the nature of the entity. If the entity is a task the weight is represented by the [niceness](https://www.kernel.org/doc/html/latest/scheduler/sched-nice-design.html) value ([code](https://elixir.bootlin.com/linux/latest/source/include/linux/sched.h#L1861)).
If it’s a task group, the weight is represented by the CPU [shares](https://elixir.bootlin.com/linux/latest/source/kernel/sched/sched.h#L384) value.

> In cgroup v2 the shares is named directly weight.

In the end the weight is what matters: in the case of tasks the niceness is converted [to priority](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched/prio.h#L26) and then [to weight](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L10902) ([here](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L10750)). In the case of task groups the user-visible value is [internally converted](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L10718).

For the sake of simplicity let’s remember this: the groups are hierarchical, and a task is part of a task group. The bigger the depth of the hierarchy, the more the weight gets diluted. Adding a heavily weighted task to one child group is not going to afflict the overall tasks tree the same as it would do if it was part of the root group. This is because the task weight is relative to the group where the task is put into.

Each entity, whether a task or a task group, is treated the same. The time accounting is applied [to the currently locally running entity](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4586) and [recursively up through the hierarchy](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L11158).

> In case of task groups, the weight is further scaled, but don't worry, we'll talk about it later.

### Update of the virtual runtime

This virtual runtime is updated on the schedule entity that is [currently running](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L846) on the local CPU via [`update_curr()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L844) function, which is called:
- whenever a task [becomes runnable](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4272), or
- whenever [blocks](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4371) becoming [unrannable](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L111), and
- [periodically](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5250) (every 1/[`CONFIG_HZ`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/Kconfig.hz#L51) seconds) by the [system timer interrupt handler](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/time/tick-common.c#L85).

> As a detail, the virtual runtime value if the task is just forked, is initialised to a [minimum value](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L529) which depends on the runqueue load ([`cfs_rq->min_vruntime`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L540)).

And this leads to the next question: how this accounting is honoured in the task selection in the scheduler in order to guarantee fairness of execution?

---

## 3. Task selection

The schedule entities eligible to run (which are in a [runnable state](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L83)) are put in a run queue, which is implemented as a [red black self-balancing binary tree](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L532) that contains schedule entity structures ordered by `vruntime`.

### The runqueues

Runqueues are per-CPU structures and contain schedule entities and they have a [pointer](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L556) to the entity which is currently running on the related CPU. The schedule entities they refer to are related to the local CPU, because the `sched_entity`s contain information about scheduling and thus are specific to a CPU. The `vruntime` is the binary tree key so the entity with the smallest `vruntime` is picked during a new schedule.

> Each scheduler class has its specific runqueue, which [are part](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L962) of the [general runqueues](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L926). Anyway, let's consider now only CFS runqueues.

In turn, also each task group has a dedicated [CFS runqueue](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L398), from the root task group through its child task groups. [`__pick_next_entity()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L606) picks the entity with the smallest virtual runtime, whether is an actual task or a group. If it’s a task group the search is repeated on its runqueue and so on, going through the hierarchy of runqueues [until a real task is found be run](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L7206).

Each runqueue keeps track of the schedule entities that are running/runnable on the local CPU.

#### In a nutshell

- Tasks groups are global.
- Tasks also are global.
- Every task is part of a task group.
- There is one runqueue per task group per CPU.
- Runqueues are composed by schedule entities.
- Schedule entities reference task or task groups.
- Schedule entities are per CPU

### Wrappin up the structures

To make it more clear, let's see a practical example.
You can see below a diagram for a sample scenario where there are two tasks (`p1` and `p2`), and two task grups (root task group and `tg1`, child of the root task group). And `p1` is direct child of task group `tg1` and `p2` is direct child of the root task group. `i` is the *i*-th CPU:
![Linux Scheduler entities relations](/images/linux_sched_structs.png)


#### Global structures

- `task_group.se`: `se[i]` is the task groups's `sched_entity` data for *i*-th CPU.
- `task_group.cfs_rq`: `cfs_rq[i]` is the task group's `cfs_rq` data for *i*-th CPU.
- `task_group.parent`: the parent task group.
- `task_group.shares`: the task group `cpu.shares`
- `task_struct.sched_class`: the scheduler class the tasks should be scheduled with.

#### Per-CPU structures

- `sched_entity.vruntime`: the virtual runtime.
- `sched_entity.parent`: the schedule entity of the parent task group.
- `sched_entity.my_q`: when not a task (`NULL`), the task group's CFS runqueue on the local CPU.
- `sched_entity.run_node`: the related red-black tree node on the runqueue tree.
- `sched_entity.cfs_rq`: the CFS runqueue that manages the schedule entity
- `sched_entity.load`: the weight of the entity. If it relates to a task group, is the sum of the weights of the tasks of the group, on the local CPU.
- `cfs_rq.load`: the load of the runqueue, aka the sum of the weights of the entities that compose it.
- `cfs_rq.current`: the schedule entity that is currently running on the local CPU, where a group or a task.
- `cfs_rq.rq`: the general CPU runqueue to which the CFS runqueue is attached.
- `cfs_rq.tg`: the task group that owns the runqueue, whether the root one or a child.
- `rq.cfs_tasks`: the [linked list](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/types.h#L178) containing the reb-black tree nodes (e.g. [here](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L7320) CFS puts the next entity into it).

> If you would like to explore the relations between the entities, I recommend [this blog](https://mechpen.github.io/posts/2020-04-27-cfs-group/index.html#2.2.-data-structures).

Now that we introduced runqueues, let's talk about the further scaling of the runtime weight for task groups schedule entities.

### Weight for task groups

As [task groups](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L391) can be run on multiple CPUs doing a real multitasking, the weight (i.e. CPU shares) for task group's runqueue is [further updated](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4592) (scaled) in `entity_tick()` based on how much the task group is loaded on the local CPU.

The weight is multiplied by the ratio of the [load](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/sched.h#L533) of the task group running on the local CPU (which is the task group's runqueue) to the global load of the task group.

This ratio tells us how much the task group is loaded on the local CPU.

> As a detail, [this is done](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L3215) if configured Linux for symmetrical multiprocessor, otherwise the shares [is not scaled](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L3209).

In detail, the load is the sum of the weights of the entities that compose the task group or the task group's runqueue.

```
shares = shares * (runqueue's load / task group's load)
```

TL;DR: in the end the ratio is the sum of the weights of the entities that compose the runqueues to the sum of the weights of the entities that compose the task group:

The calculcation is done by the [`calc_group_shares()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L3157) function, to get the final value of the task goup's shares that will weight the virtual runtime of the task group schedule entity:

```
static long calc_group_shares(struct cfs_rq *cfs_rq)
{
	long tg_weight, tg_shares, load, shares;
	/
	struct task_group *tg = cfs_rq->tg;

	/*
	   tg_shares is the task group's CPU shares.
	 */
	tg_shares = READ_ONCE(tg->shares);

	/*
	   load is the load of the local CFS runqueue which is,
	   the load of the task group on the local CPU.
	 */
	load = max(scale_load_down(cfs_rq->load.weight), cfs_rq->avg.load_avg);

	/*
	   tg_weight is the global load of the task group.
	 */
	tg_weight = atomic_long_read(&tg->load_avg);

	/* Ensure tg_weight >= load */
	tg_weight -= cfs_rq->tg_load_avg_contrib;
	tg_weight += load;

	shares = (tg_shares * load);
	if (tg_weight)
		shares /= tg_weight;

	// ...

	/*
	   shares is now the per CPU-scaled task group shares.
	*/
	return clamp_t(long, shares, MIN_SHARES, tg_shares);
}
```

This is done to treat fairly also groups among CPUs!

```
...
shares = (tg_shares * load);
	if (tg_weight)
		shares /= tg_weight;
...
```

Consequently, the `vruntime` is the binary tree key so the entity with the smallest `vruntime` is picked by [`__pick_next_entity()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L606), whether is an actual task or a group. If it’s a task group the search is repeated on its runqueue and so on, going through the hierarchy of runqueues until a real task is found be run.

> As a detail, in order to provide efficiency and to not need to [traverse](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L606) the whole tree every time a scheduling is needed, as the element in an ordered red black tree that is leftmost is the element with minor key value (i.e. the `vruntime`) a cache [is easily keeped](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L588) as [`rb_leftmost`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/rbtree_types.h#L28) variable in each runqueue structure. And it's [ideally picked](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4518) by `pick_next_entity()`.

And now we need to see the whole picture, and better, with code!

### Wrapping up the time accounting!

Now that we have the most important notions of the time accounting, considering how the weight is calculated for both tasks and tasks groups schedule entities, which are part of hierarchical tasks groups' runqueues, let's see how the time accounting is honoured during the periodic tick, fired by the timer interrupt:

```
/*
 * Called by the timer interrupt handler every 1/HZ seconds.
 */
scheduler_tick()
/* The local CPU */
-> int cpu = smp_processor_id();
/* The local CPU runqueue */
-> struct rq *rq = cpu_rq(cpu);
/* The local CPU runqueue currently running task */
-> struct task_struct *curr = rq->curr;
/* The current running task's scheduler class' periodic tick function. */
-> curr->sched_class->task_tick(rq, curr)
   /* Let's assume the class is CFS. */
   -> task_tick_fair()
      -> struct sched_entity *se = &curr->se;
      /*
       * For each schedule entity through parent task groups
       * up to the root task group.
       */
      -> for_each_sched_entity(se)
         /* The runqueue where the entity is placed. */
         -> cfs_rq = cfs_rq_of(se);
         -> entity_tick(cfs_rq, se)
            /*
             * Update the virtual runtime for the current running entity
             * on the current selected by loop-task group's runqueue.
             */
            -> update_curr(cfs_rq)
               -> struct sched_entity *curr = cfs_rq->curr;
               -> delta_exec = now - curr->exec_start;
               -> curr->exec_start = now;
               -> curr->vruntime += calc_delta_fair(delta_exec, curr);
            /*
             * If it's a task group update the shares 
             * based on its group runqueue,
             * which is the group load on the local CPU
             */
            -> update_cfs_group(se)
               /* The CFS runqueue of the entity, if it's a task group. */
               -> struct cfs_rq *gcfs_rq = group_cfs_rq(se);
               /* If the entity is a task, skip */
               -> if (!gcfs_rq)
               ->   return;
               /*
                * Update the CPU shares for the task group entity.
                */
               -> shares = calc_group_shares(gcfs_rq);
               -> reweight_entity(cfs_rq_of(se), se, shares);
```

> The code has been a bit simplified to show a clearer picture.

So, the next question is: how a runqueue is populated? When a new task is added do a runqueue?

### Runqueues population

The runqueues are populated when:
- a [`clone()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/fork.c#L2524) is called, and
- a task wakes up after having slept via [`try_to_wake_up()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3985) function call

with [`enqueue_entity()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4260).

Furthermore, the next question is: when a task is removed from the runqueue?
- When a task explicitly [`exit()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/exit.c#L733)s (via [`exit()`](https://man7.org/linux/man-pages/man3/exit.3.html) libc function)
- When a task explicitly or implicitly requests to [`sleep()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L261)

with [`dequeue_entity()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4366).

In both enqueue and dequeue cases the `rb_leftmost` cache is [`updated`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/rbtree.h#L165) and replaced it with [`rb_next()`](https://elixir.bootlin.com/linux/v5.17.9/source/lib/rbtree.c#L492) result.

Now that we have a runqueue populated, how the scheduler picks one task from there?

### The scheduler entrypoint

[`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377) is the main function which (through [`__schedule`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6189)), calls [`pick_next_task`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5681) that will return the task that ran less.

For the sake of simplicity, let's consider that the [hyperthreading support](https://lwn.net/Articles/861251/) is not [configured]() (more on core scheduling [here](https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/core-scheduling.html)). 

 [`__pick_next_task()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5604) picks the [highest priority scheduler class](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5615) which returns the [higher priority task](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L7213), by looping through the hierarchy of task groups' runqueues, [until](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L7269) a real task is found. Actually, as we said before, the runqueue red-black trees are not traversed on each schedule, instead it picks in the end the [`rb_leftmost`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/rbtree.h#L106) entity rb node, through [`__pick_next_entity`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4528).

It loops [while](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6386) the currently running task should be rescheduled, which is, is no longer fair to be run.

> The path is a bit [different](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5695) when the [core scheduling](https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/core-scheduling.html) feature is enabled.

Then, [`__schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6189)  calls [`context_switch()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L4945) that switches to the returned task.

And this comes to one of the next topics: **context switch**. But before talking about that let’s continue talking about the life of a task.

Let’s imagine that we are in process context ([TL;DR](https://stackoverflow.com/questions/57987140/difference-between-interrupt-context-and-process-context)) and that our task is now running.
Not all tasks complete from the time have being scheduled.
For example tasks waiting for events (like for keyboard input or for file I/O) can be put to sleep, and also are in [interruptible](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L84) / [uninterruptible](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L85) state so that aren’t picked from the runqueue.

---

## 4. Sleep and wake up

A task can decide to sleep but something then is needed to wake it up. We should also consider that multiple tasks can wait for some event to occur.

A wait queue (of type [`wait_queue_head`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/wait.h#L37) is implemented for this purpose as a list of tasks waiting for some events to occur.
It allows tasks to be notified when those events occur by referencing the wait queue, generally from what generates the event itself.

### Sleep

A task can put itself to sleep in the kernel similar with what does the [`wait`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L18) syscall:
- create a wait queue via the [`DECLARE_WAIT_QUEUE_HEAD()`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/wait.h#L61) macro
- add the task itself to it via [`add_wait_queue()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L18) function call
- set its state to [interruptible](https://elixir.bootlin.com/linux/latest/source/include/linux/sched.h#L84) / [uninterruptible](https://elixir.bootlin.com/linux/latest/source/include/linux/sched.h#L85) via [`prepare_to_wait()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L261). If task is set interruptible signals can wakes it up.
- call [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377) which in turn removes the task from the runqueue via [`deactivate_task()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L2041).

```
/* ‘q’ is the wait queue we wish to sleep on */
DEFINE_WAIT_QUEUE_HEAD(wait); 
add_wait_queue(q, &wait);

while (!condition) { /* condition is the event that we are waiting for */ 
	prepare_to_wait(&q, &wait, TASK_INTERRUPTIBLE);
	...
	schedule(); 
}
```

It can also do it nonvoluntarily waiting for [semaphores](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/semaphore.h#L15).

### Wake up

Instead, to wake those tasks that are sleeping waiting for an event here is the flow.

> As a detail, wait queues have two implementations, the one we mentioned above and the original one (Linux 2.0) which has been kept for simple use cases, and is called now [simple wait queues](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/swait.h#L48) (more on the history [here](https://lwn.net/Articles/577370/)).

For the sake of simplicity on the path to waking up let’s take the example of the simple wait queue, as the standard wait queue here is more complex than it is in the preparation to wait, and we don't need to understand it now.

[`swake_up_all()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/swait.c#L62) (which is pretty analogous to the sibling implementation's [` wake_up_all()`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/wait.h#L224)) calls [`try_to_wake_up()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3985) and is there to wake all processes in a wait queue when the associated event occurs.

[`try_to_wake_up()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3985) does the work that consists of:
- [set task state](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L4083) to [running](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L83) - and through [`ttwu_queue`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3801):
- [calls](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3615) the [`activate_task()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L2034) function which adds the task to the runqueue via [`enqueue_task()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L2000)
- [sets `need_resched`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L2125) flag on current task if the awakened task has higher priority than the current one (we’ll talk about this flag later) which provokes a [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L996) (and consequent context switch)

[`swake_up_all()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/swait.c#L62) then [removes](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/swait.c#L73) the task from the wait queue.

#### Signals

Also signals can wake up tasks if they are in [interruptible](https://elixir.bootlin.com/linux/latest/source/include/linux/sched.h#L84).
In this case the task code itself should then manage the spurious wake up ([example](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L435)), by checking the event that occurs or [manage the signal](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched/signal.h#L363) (e.g. [`inotify`](https://elixir.bootlin.com/linux/v5.17.9/source/fs/notify/inotify/inotify_user.c#L235) does it), and call [`finish_wait`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/wait.c#L388) to update its state and remove itself from the wait queue.

Completing the sample code above by managing also the waking up part we'll have something like this:

```
/* ‘q’ is the wait queue we wish to sleep on */
DEFINE_WAIT_QUEUE_HEAD(wait); 
add_wait_queue(q, &wait);

while (!condition) { /* condition is the event that we are waiting for */ 
	prepare_to_wait(&q, &wait, TASK_INTERRUPTIBLE);
	if (signal_pending(current))
 		/* handle signal */
	schedule(); 
}
finish_wait(&q, &wait); 
```


As a detail, wake up can be provoked in both process context and interrupt context, during an interrupt handler execution. Sleep can be only done in process context.

---

## 5. Context switch and Preemption

And this comes to the context switch.
For example, when a task starts to sleep a context switch is needed, and the next task is voluntarily picked and the scheduling is done via [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377).

The context switch work is done by [`context_switch()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L4945), called by the internal [`__schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6189) and executes:
- [`switch_mm()`](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/include/asm/mmu_context.h#L128) (implementation [here](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/mm/tlb.c#L488) for x86) to switch virtual memory mappings process-specific.
- [`switch_to()` (x86_64)](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/entry/entry_64.S#L225) to save and restore stack informations and all registers which contain process-specific data.

As you saw, both functions are architecture dependent (ASM) code.
The context switch is requested by the tasks themselves voluntarily or by the scheduler, nonvoluntarily from the point of view of a task.

### Voluntarily

As we saw tasks can trigger context switch via [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377) in kernelspace, either when they explicitely request it or when they put themselves to sleep or they try to wake up other ones. Also, context switch happens when tasks block, for example when synchronizing with [semaphores](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/semaphore.h#L15) or [mutexes](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/mutex.h#L63).

Anyway context switches are not done only when code in kernelspace voluntarily calls [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377), otherwise tasks could monopolise a CPU, so an external component should intervene.

### Nonvoluntary: preemption

As the main Linux scheduler class is a fair scheduler the fairness must be guaranteed in some way... Ok, but how it preempts?

For this purpose a flag named [`need_reschedule`](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/include/asm/thread_info.h#L83) is present in the [`task_struct`](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/sched.h#L734)'s [`thread_info` flags (x86)](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/include/asm/thread_info.h#L57) and is set or unset on the current task to notify that it should leave the CPU which in turn, after [`schedule()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6377) call, will switch to another process context.

So, when this flag is set?
- in [`scheduler_tick()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L5250), which is constantly called by the timer interrupt [handler](https://elixir.bootlin.com/linux/v2.6.39/source/kernel/time/tick-common.c#L63) (the architecture independent part actually), continuously checking and updating `vruntime` and it [sets the flag](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/fair.c#L4600) when a preemption is needed.
- in [`try_to_wake_up()`](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3985), when the current task [has minor priority](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L3562) than the awakened.

Then, in order to understand when the flag is checked we can think about when a task preemption is needed and also can be done safely.

##### In userspace

Returning [from kernelspace to userspace](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/entry-common.h#L301) is safe to context switch: if it is safe to continue executing the
current task, it is also safe to pick a new task to execute. Has this userspace task still to run? Maybe it’s no longer fair to run it. This is what happens when from:
- [system calls](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/entry-common.h#L336)
- [interrupt handlers](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/entry-common.h#L380)

return to userspace.

[If `need_resched` is set](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6459) a schedule is needed, the next entity task is picked, and context switch done.

> As a note, consider that both these paths are architecture dependent, and typically implemented in assembly in entry.S (e.g. [x86_64](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/entry/entry_64.S)) which, aside from kernel entry code, also contains kernel exit code).

##### In kernel space

A note deserves to be explained. The kernel is fully [preemptive](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/Kconfig.preempt#L51) from [2.6](https://elixir.bootlin.com/linux/v2.6.0/source/arch/x86_64/Kconfig#L189) that is, a task can be preempted as long as the kernel is in a safe state.
When preemption can’t be done, locks are in place to mark it, so that a safe state is defined when the kernel doesn’t hold a lock.
Basically a lock counter `preempt_count` is added to [`thread_info` flags (x86)](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/include/asm/thread_info.h#L57) to let preempt tasks running in kernelspace only when it’s equal to zero.

Upon return from interrupt to kernelspace or from process context during [preemption](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6493), if `need_resched` is set and [`preempt_count` == 0](https://elixir.bootlin.com/linux/v5.17.9/source/include/linux/preempt.h#L215) the current task is preempted, otherwise the interrupt returns to the interrupted task.

Also, everytime `preempt_count` is updated and decreased to zero and [`need_resched`](https://elixir.bootlin.com/linux/v5.17.9/source/arch/arm64/include/asm/thread_info.h#L33) is true, preemption is done.

For example, considering the return path from interrupt which is architecture-dependent, the xtensa's ISA [common exception exit path](https://elixir.bootlin.com/linux/v5.17.9/source/arch/xtensa/kernel/entry.S#L488) is pretty self-explanatory:

```
common_exception_return:

	...

#ifdef CONFIG_PREEMPTION
6:
	_bbci.la4, TIF_NEED_RESCHED, 4f

	/* Check current_thread_info->preempt_count */

	l32ia4, a2, TI_PRE_COUNT
	bneza4, 4f
	abi_callpreempt_schedule_irq
	j4f
#endif
	...
```

> TL;DR About what we said above, you can check the `__schedule()` function [comments](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/sched/core.c#L6151).

Also, the kernel is [SMP-safe](https://elixir.bootlin.com/linux/v5.17.9/source/arch/arm64/Kconfig#L312) that is, a task can be safely restored in a symmetrical multi processor.

You can check both [preemption config](https://elixir.bootlin.com/linux/v5.17.9/source/kernel/Kconfig.preempt#L51) and [SMP config (x86)](https://elixir.bootlin.com/linux/v5.17.9/source/arch/x86/Kconfig#L400) it your running kernel version:

```
$ uname -v
#1 SMP PREEMPT Wed, 27 Apr 2022 20:56:11 +0000
```

That’s all folks! We've arrived to the end of this little journey.

---

## Wrapping up

> The linked code refers to Linux 5.17.9.

I didn't want to interrupt the trip but instead leave to you the choice to dig into each single path the kernel does to manage the tasks scheduling. That's why I intentionally didn't include so much snippets, as the code is there and open for you, whenever you want.

What is incredible is that, even if it's one of the largest OSS projects, you can understand how Linux works and also contribute. That's why I love open source more every time!

# Thank you!

I hope this was interesting for you as it was for me. Please, feel free to reach out!

# Links

- https://www.kernel.org/doc/html/v5.17/scheduler/index.html
- https://elixir.bootlin.com/linux/v5.17.9/source
- https://www.amazon.com/Linux-Kernel-Development-Robert-Love/dp/0672329468
- https://mechpen.github.io/posts/2020-04-27-cfs-group/index.html#2.2.-data-structures
- https://josefbacik.github.io/kernel/scheduler/2017/07/14/scheduler-basics.html
- https://opensource.com/article/19/2/fair-scheduling-linux
- https://lwn.net/Articles/531853/
- https://oska874.gitbooks.io/process-scheduling-in-linux/content/
