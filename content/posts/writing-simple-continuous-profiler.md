---
Title: Unleashing the power of frame pointers for profiling pt.2 - Writing a simple profiler
date: 2024-08-18T21:00:00+02:00
tags: [profiling, optimization, ebpf]
categories: [profiling]
slug: unleashing-power-frame-pointers-writing-simple-continuous-profiler
draft: false
---

In the previous blog about the program execution environment, we introduced the concept of stack unwinding with frame pointers as one of the techniques leveraged for profiling a program.

In this blog, we'll see practically how we can build a simple sampling-based continuous profiler.

Since we don’t want the application to necessarily be instrumented, we can use the Linux kernel instrumentation. Thanks to eBPF we’re able to dynamically load and attach the profiler program to specific kernel entry points, limiting the introduced overhead by exchanging data with userspace through eBPF maps.

The goal is to calculate statistics about the time spent by a program on specific code paths.

A possible implementation can be summarized with the following responsibilities:
- to periodically sample stack traces
- to collect samples
- to calculate statistics with the samples
- to resolve instruction pointer to symbols

These responsibilities can be assigned to two main components:
- in kernel space, an eBPF program periodically samples stack traces for a specific process;
- in userspace, a program loads and attaches the eBPF program to a periodic trigger, filter and consumes the samples to calculate the statistics, and resolves the subroutine's symbols.

## Kernel space

The main responsibility of the eBPF program count how often a specific code path is executed and create a histogram of the results. Also, it gathers the stack traces to be accessed from userspace.

We'll use two data structures for this information:
- an histogram eBPF `BPF_MAP_TYPE_HASH` map
- a stack traces eBPF `BPF_MAP_TYPE_STACK_TRACE` map

![histogram_stack_traces_structs](https://raw.githubusercontent.com/maxgio92/notes/465c142604835037dfc08a9acf753d9177a9af94/content/images/yap_maps_stack_traces_histogram.svg)

### Histogram

We'll store the histogram of sample counts for a particular code path in a `BPF_MAP_TYPE_HASH` eBPF hash map:

```c
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, histogram_key_t);
	__type(value, u64);
	__uint(max_entries, K_NUM_MAP_ENTRIES);
} histogram SEC(".maps");
```

The key of this map represents the identifier for a particular state-in-point of the stack and is a structure that contains:
- PID;
- kernel stack ID;
- user stack ID:
  
```c
typedef struct histogram_key {
	u32 pid;
	u32 kernel_stack_id;
	u32 user_stack_id;
} histogram_key_t;
```

The value of this map is a `u64` to store stack trace counts. 

### Stack traces

To get the information about the running code path we can use the `bpf_get_stackid` eBPF helper.

eBPF helpers are functions that, as you might have guessed, simplify work. The [`bpf_get_stackid`](https://elixir.bootlin.com/linux/v6.8.5/source/kernel/bpf/stackmap.c#L283) helper collects user and kernel stack frames by walking the user and kernel stacks and returns the ID of the state of the stack at a specific point in time.

More precisely from the [eBPF Docs](https://ebpf-docs.dylanreimerink.nl/linux/helper-function/bpf_get_stackid/):

> Walk a user or a kernel stack and return its `id`. To achieve this, the helper needs `ctx`, which is a pointer to the context on which the tracing program is executed, and a pointer to a map of type `BPF_MAP_TYPE_STACK_TRACE`.

So, one of the most complex works that is the stack unwinding is abstracted away thanks to this helper.

For example, we declare the `stack_traces` `BPF_MAP_TYPE_STACK_TRACE` map that contains the list of instruction pointers, and we prepare the `histogram` key:

```c
struct {
    __uint(type, BPF_MAP_TYPE_STACK_TRACE);
    __uint(key_size, sizeof(u32));
    __uint(value_size, PERF_MAX_STACK_DEPTH * sizeof(u64));
    __uint(max_entries, 10000);
} stack_traces SEC(".maps");

SEC("perf_event")
int sample_stack_trace(struct bpf_perf_event_data* ctx)
{
	histogram_key_t key;
	// ...

	/* Sample the user and kernel stack traces, and record in the stack_traces structure. */
	key.pid = bpf_get_current_pid_tgid() >> 32;
	key.kernel_stack_id = bpf_get_stackid(ctx, &stack_traces, 0);
	key.user_stack_id = bpf_get_stackid(ctx, &stack_traces, 0 | BPF_F_USER_STACK);
	// ...
}
```

and for the specific stack trace (`key`) we update the sample count in the `histogram`:

```c
SEC("perf_event")
int sample_stack_trace(struct bpf_perf_event_data* ctx)
{
	histogram_key_t key;
	u64 one = 1;
	// ...

	/* Sample the user and kernel stack traces, and record in the stack_traces structure. */
	// ...

	/* Upsert stack trace histogram */
	count = (u64*)bpf_map_lookup_elem(&histogram, &key);
	if (count) {
		(*count)++;
	} else {
		bpf_map_update_elem(&histogram, &key, &one, BPF_NOEXIST);
	}

	return 0;
}
```

We also need to retrieve the stack trace, which is a list of instruction pointers. This information too is abstracted away thanks to the [`BPF_MAP_TYPE_STACK_TRACE`](https://elixir.bootlin.com/linux/v6.8.5/source/include/uapi/linux/bpf.h#L914) map, and available to userspace.

```c
struct {
	__uint(type, BPF_MAP_TYPE_STACK_TRACE);
	__uint(key_size, sizeof(u32));
	__uint(value_size, PERF_MAX_STACK_DEPTH * sizeof(u64));
	__uint(max_entries, K_NUM_MAP_ENTRIES);
} stack_traces SEC(".maps");
```

This is mostly the needed work in kernel space, which is pretty simplified thanks to the Linux kernel instrumentation.

Let's see how we can consume this data in userspace.

## Userspace

Besides loading and attaching the eBPF sampler probe, in userspace, we collect the stack traces from the `stack_traces` map. This map is accessible by stack IDs, which are available from the `histogram` map.

### Collecting stack traces

Using the [libbpfgo](https://github.com/aquasecurity/libbpfgo) library it can be achieved like that:

```go
import (
	"encoding/binary"
	"bytes"
	"unsafe"
)

type HistogramKey struct {
	Pid int32

	// UserStackId, an index into the stack-traces map.
	UserStackId uint32

	// KernelStackId, an index into the stack-traces map.
	KernelStackId uint32
}

// StackTrace is an array of instruction pointers (IP).
// 127 is the size of the profile, as for the default PERF_MAX_STACK_DEPTH.
type StackTrace [127]uint64

func Run(ctx context.Context) error {
	// ...
	for it := histogram.Iterator(); it.Next(); {
		k := it.Key()

		// ...
		
		var key HistogramKey
		if err = binary.Read(bytes.NewBuffer(k), binary.LittleEndian, &key); err != nil {
			// ...
		}

		var symbols string
		if int32(key.UserStackId) >= 0 {
			trace, err := getStackTrace(stackTraces, key.UserStackId)
			// ...
		}
		if int32(key.KernelStackId) >= 0 {
			trace, err := getStackTrace(stackTraces, key.KernelStackId)
			// ...
		}
		// ...
}

func getStackTrace(stackTraces *bpf.BPFMap, id uint32) (*StackTrace, error) {
	stackB, err := stackTraces.GetValue(unsafe.Pointer(&id))
	// ...

	var stackTrace StackTrace
	err = binary.Read(bytes.NewBuffer(stackB), binary.LittleEndian, &stackTrace)
	// ...

	return &stackTrace, nil
}
```

### Calculating statistics

Once the sampling is completed, we're able to calculate the program's residency fraction for each subroutine, that is, how much a specific subroutine has been run within a time frame:

```
residencyFraction = nTraceSamples / nTotalSamples * 100.
```

You find below the simple code:

```go
func calculateStats() (map[string]float64, error) {
	// ...

	traceSampleCounts := make(map[string]int, 0)
	totalSampleCount := 0
	
	// Iterate over the stack profile counts histogram map.
	for it := histogram.Iterator(); it.Next(); {
		k := it.Key()

		// ...

		// Get count for the specific sampled stack trace.
		countB, err := histogram.GetValue(unsafe.Pointer(&k[0]))
		// ...
		count := int(binary.LittleEndian.Uint64(countB))

		// ...
		
		// Increment the traceSampleCounts map value for the stack trace symbol string (e.g. "main;subfunc;")
		totalSampleCount += count
		traceSampleCounts[trace] += count
	}
	
	stats := make(map[string]float64, len(traceSampleCounts))
	for trace, count := range traceSampleCounts {
		residencyFraction := float64(count) / float64(totalSampleCount)
		stats[trace] = residencyFraction
	}

	return stats, nil
}
```

Finally, because traces are arrays of instruction pointers, we need to translate addresses to symbols.

### Symbolization

There are different ways to resolve symbols based on the binary format and the way the binary has been compiled.

Because this is a demonstration and the profiler is simple we'll consider just ELF binaries that are not stripped.

The ELF structure contains a [symbol table](https://refspecs.linuxbase.org/elf/gabi4+/ch4.symtab.html) in the `.symtab` section that holds information needed to locate and relocate a program's symbolic definitions and references. With that information, we're able to associate instruction addresses with subroutine names.

An entry in the symbol table has the following structure:

```c
typedef struct {
	Elf64_Word	st_name;
	unsigned char	st_info;
	unsigned char	st_other;
	Elf64_Half	st_shndx;
	Elf64_Addr	st_value;
	Elf64_Xword	st_size;
} Elf64_Sym;
```

The correct symbol name (`st_name`) for an instruction pointer is the one of which the start (`st_value`) and end instruction addresses (`st_value` + `st_size`) are minor or equal, and major or equal respectively to the instruction pointer address, for each frame in the stack trace.

Because the user space program is written in Go, we can leverage the `debug/elf` package from the standard library to access that information to access ELF data.
The [`elf.File`](https://pkg.go.dev/debug/elf#File.Symbols) struct exposes a [`Symbols()`](https://pkg.go.dev/debug/elf#File.Symbols) function that returns the symbol table for the specific ELF `File` as a slice of [`Symbol`](https://pkg.go.dev/debug/elf#Symbol) objects, which in turn expose `Value` and `Size`.

So, we can match the right symbol for frame's instruction pointer from the stack trace like below:

```go
import "debug/elf"

// ELFSymTab is one of the possible abstractions around executable
// file symbol tables, for ELF files.
type ELFSymTab struct {
	symtab []elf.Symbol
}

// Load loads from the underlying filesystem the ELF file
// with debug/elf.Open and stores it in the ELFSymTab struct.
func (e *ELFSymTab) Load(pathname string) error {
	// ...
	file, err := elf.Open(pathname)
	// ...
	syms, err := file.Symbols()
	// ...
	e.symtab = syms

	return nil
}

// GetSymbol returns symbol name from an instruction pointer address
// reading the ELF symbol table.
func (e *ELFSymTab) GetSymbol(ip uint64) (string, error) {
	var sym string
	// ...
	for _, s := range e.symtab {
		if ip >= s.Value && ip < (s.Value+s.Size) {
			sym = s.Name
		}
	}

	return sym, nil
}
```

#### Program executable path

To access the ELF binary we need the process's binary pathname. The pathname can be retrieved in kernel space from the `task_struct`'s user space memory mapping descriptor ([`task_struct`](https://elixir.bootlin.com/linux/v6.8.5/source/include/linux/sched.h#L748)->[`mm_struct`](https://elixir.bootlin.com/linux/v6.8.5/source/include/linux/mm_types.h#L734)->[`exe_file`](https://elixir.bootlin.com/linux/v6.8.5/source/include/linux/mm_types.h#L905)->[`f_path`](https://elixir.bootlin.com/linux/v6.8.5/source/include/linux/fs.h#L1016)) that we can pass through an eBPF map to userspace.

Because this data needs to be shared with userspace in order to read from the ELF symbol table, we can declare a map like the following:

![binprm_info_map](https://raw.githubusercontent.com/maxgio92/notes/465c142604835037dfc08a9acf753d9177a9af94/content/images/yap_maps_binprm_info.svg)

This hash map stores the binary program file path for each process:

```c
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u32);			/* pid */
	__type(value, char[MAX_ARRAY_SIZE]);	/* exe_path */
	__uint(max_entries, K_NUM_MAP_ENTRIES);
} binprm_info SEC(".maps");
```

that is updated accordingly alongside the histogram:

```c
SEC("perf_event")
int sample_stack_trace(struct bpf_perf_event_data* ctx)
{
	// ...
	struct task_struct *task;

	/* Get current task executable pathname */
	task = (struct task_struct *)bpf_get_current_task(); /* Current task struct */
	exe_path = get_task_exe_pathname(task);
	if (exe_path == NULL) {
		return 0;
	}
	len = bpf_core_read_str(&exe_path_str, sizeof(exe_path_str), exe_path);
	if (len < 0) {
		return 0;
	}

	// ...
	/* Upsert stack trace histogram */
	count = (u64*)bpf_map_lookup_elem(&histogram, &key);
	if (count) {
		(*count)++;
	} else {
		bpf_map_update_elem(&histogram, &key, &one, BPF_NOEXIST);
		bpf_map_update_elem(&binprm_info, &key.pid, &exe_path_str, BPF_ANY);
		// ...
	}
}
```

The userspace program will then consume the `exe_path` for the profiled process to access the `.symtab` ELF section.

```c
SEC("perf_event")
int sample_stack_trace(struct bpf_perf_event_data* ctx)
{
	// ...
	/* Get current task executable pathname */
	task = (struct task_struct *)bpf_get_current_task(); /* Current task struct */
	exe_path = get_task_exe_pathname(task);
	// ...
}

/*
 * get_task_exe_pathname returns the task exe_file pathname.
 * This does not apply to kernel threads as they share the same memory-mapped address space,
 * as opposed to user address space.
 */
static __always_inline void *get_task_exe_pathname(struct task_struct *task)
{
	/*
	 * Get ref file path from the task's user space memory mapping descriptor.
	 * exe_file->f_path could also be accessed from current task's binprm struct 
	 * (ctx->args[2]->file->f_path)
	 */
	struct path path = BPF_CORE_READ(task, mm, exe_file, f_path);

	buffer_t *string_buf = get_buffer(0);
	if (string_buf == NULL) {
		return NULL;
	}
	/* Write path string from path struct to the buffer */
	size_t buf_off = get_pathname_from_path(&path, string_buf);
	return &string_buf->data[buf_off];
}
```

To retrieve the pathname from the [`path`](https://elixir.bootlin.com/linux/v6.8.5/source/include/linux/path.h#L8) struct we need to walk the directory hierarchy until reaching the root directory of the same VFS mount. For the sake of simplicity, we don't go into the details of this part.

## The eBPF program trigger

To run the eBPF program with a fixed frequency the [Perf](https://perf.wiki.kernel.org/index.php/Main_Page) subsystem exposes a kernel software event of type CPU clock ([`PERF_COUNT_SW_CPU_CLOCK`](https://elixir.bootlin.com/linux/v6.8.5/source/include/uapi/linux/perf_event.h#L119)) with user APIs. Luckily, eBPF programs can be attached to those events.

![perf-event-software-cpu-clock-trigger-bpf](https://raw.githubusercontent.com/maxgio92/notes/7e1e10ea843e5289390d5b89037dfd7589d1d847/content/images/perf-cpu-clock-sw-event-trigger.svg)

So, after the program is loaded:

```go
import (
	bpf "github.com/aquasecurity/libbpfgo"
	"github.com/pkg/errors"
	"golang.org/x/sys/unix"implements access to ELF object files.
)

func loadAndAttach(probe []byte) error {
	bpfModule, err := bpf.NewModuleFromBuffer(probe, "sample_stack_trace")
	// ...
	defer bpfModule.Close()

	if err := bpfModule.BPFLoadObject(); err != nil {
		// ...
	}

	prog, err := bpfModule.GetProgram("sample_stack_trace")
	if err != nil {
		// ...
	}

	// ...
}
```

this Perf event can be leveraged to run the sampler by interrupting the CPUs every x milliseconds independently of the process running.
Because Perf exposes user APIs, the userspace program can prepare the clock software events and attach the loaded [BPF_PROG_TYPE_PERF_EVENT](https://ebpf-docs.dylanreimerink.nl/linux/program-type/BPF_PROG_TYPE_PERF_EVENT/) eBPF program to them:

```go
import (
	bpf "github.com/aquasecurity/libbpfgo"
	"github.com/pkg/errors"
	"golang.org/x/sys/unix"
)

func loadAndAttach(probe []byte) error {
	// Load the program...

	cpus := runtime.NumCPU()

	for i := 0; i < cpus; i++ {
		attr := &unix.PerfEventAttr{
			Type: unix.PERF_TYPE_SOFTWARE,		// If type is PERF_TYPE_SOFTWARE, we are measuring software events provided by the kernel.
			Config: unix.PERF_COUNT_SW_CPU_CLOCK,	// This reports the CPU clock, a high-resolution per-CPU timer.
			
			// A "sampling" event is one that generates an overflow notification every N events,
			// where N is given by sample_period.
			// sample_freq can be used if you wish to use frequency rather than period.
			// sample_period and sample_freq are mutually exclusive.
			// The kernel will adjust the sampling period to try and achieve the desired rate.
            // Prime numbers are recommended to avoid collisions with other periodical tasks.
			Sample: 11 * 1000 * 1000,
		}
		
		// Create the perf event file descriptor that corresponds to one event that is measured.
		// We're measuring a clock timer software event just to run the program on a periodic schedule.
		// When a specified number of clock samples occur, the kernel will trigger the program.
		evt, err := unix.PerfEventOpen(
			attr,	// The attribute set.
			-1,	// All the tasks.
			i,	// on the Nth CPU.
			-1,	// The group_fd argument allows event groups to be created.
			0,	// The flags.
		)
		// ...
		https://blog.px.dev/static/7b13192052f268bfd22577215d0c9f01/sample-stack-trace-function.png
		// Attach the BPF program to the sampling perf event.
		if _, err = prog.AttachPerfEvent(evt); err != nil {
			return errors.Wrap(err, "error attaching the BPF probe to the sampling perf event")
		}
	}

	return nil
}
```

> In this example we're using the [libbpfgo](https://github.com/aquasecurity/libbpfgo) library.

## Wrapping up

The user program loads the eBPF program, attaches it to the Perf event in order to be triggered periodically, and samples stack traces. Trace instruction pointers are resolved into symbols and before returning, the statistics about residency fraction are calculated with data stored in the histogram.

The statistics are finally printed out like below:

```
80% main();foo();bar()
20% main();foo();baz()
```

You can see a full working example at [github.com/maxgio92/yap](https://github.com/maxgio92/yap). YAP is a sampling-based, low overhead kernel-assisted profiler I started for learning eBPF and how a program is executed by the CPU.

## Next

I personally would like to use statistics to build graph structures, like [flamegraphs](https://github.com/brendangregg/FlameGraph).

Also, I'd like to investigate other ways to extend symbolization support for stripped binaries and collect traces when binaries are built without frame pointers.

## Thanks

Thanks for your time, I hope you enjoyed this blog.

I want to special thank [Pixie](https://github.com/pixie-io/) for their knowledge sharing on their [blog](https://blog.px.dev/), and the Linux project for BPF code [samples](https://github.com/torvalds/linux/blob/v6.8/samples/bpf).

Any form of feedback is more than welcome. Hear from you soon!

## References

* https://blog.px.dev/cpu-profiling/
* https://github.com/torvalds/linux/blob/v6.8/samples/bpf/trace_event_kern.c
* https://refspecs.linuxbase.org/elf/
* https://groups.google.com/g/golang-nuts/c/wtw0Swe0CAY
* https://0xax.gitbooks.io/linux-insides/content/index.html
* https://www.polarsignals.com/blog/posts/2022/01/13/fantastic-symbols-and-where-to-find-them
