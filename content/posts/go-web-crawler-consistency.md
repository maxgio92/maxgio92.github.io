---
title: "How I improved consistency in a Go web crawler with retry logics and tuning the HTTP client"
date: 2023-08-30T20:05:00+02:00
tags: [go, software]
categories: [go]
slug: how-i-improved-consistency-go-web-crawler-with-retry-tuning-http-client
draft: true 
---

# Introduction

[wfind](https://github.com/maxgio92/wfind) is a simple web crawler for files and folders in web pages hyerarchies. The goal is basically the same of [GNU find](https://www.gnu.org/software/findutils/manual/html_mono/find.html) for file systems.
At the same time it's inspired by [GNU wget](https://www.gnu.org/software/wget/manual/html_node/index.html), and it merges the `find` features applied to files and directories exposed as HTML web resources.

In this blog we'll go through the way I improved consistency in this crawler, by implementing retry logics and tuning network and transport in the HTTP client.

## Parallelism and concurrency

As a crawler, `wfind` is vital to efficiently do its work scraping web pages in parallel routines.

For scraping web pages wfind leverages [go-colly](https://go-colly.org/), that allows run its [collector](https://go-colly.org/docs/introduction/start/#collector) in [asynchronous mode](https://go-colly.org/docs/examples/parallel/).
That mode simply [`fetches`](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L440) HTTP objects inside [dedicated goroutines](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L573).

From the user perspective (i.e. `wfind`), the synchronization is as simple as invoking the [`Wait`](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L812) function before completing. 
The API is provided by the Colly collector and it wraps around the standard [`WaitGroup`](https://pkg.go.dev/sync#WaitGroup)'s `Wait()`, from the Go standard library's [`sync`](https://pkg.go.dev/sync) package, waiting for all the fetch goroutines to complete.

As the go-colly implementation does not provide cap on the parallelism, the implementation can lead to the common concurrency problems, racing for OS and runtime resources client-side, server-side, and physical medium-side.

Client-side, the maxmimum allowed open connections could prevent the client to open and then establish new ones during the scraping.
The server could limit resource usage and we cannot predict the strategies and logics followed server-side.
Also, the connection mean in the physical layer is another point of failure; for example latency might cause the HTTP client to time out during go-colly's [`Visit`](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L440C20-L440C27) waiting for a response.

At the end of the day a retry logics was fundamental in order to improve the consistency in the crawling.
Furthermore, verifying the consistency through end-to-end functional tests is required to guarantee the expected behaviour of the program.

## End-to-end tests

As end-to-end functional tests treat the program as a black-box and ensures that provide the value as expected, interacting with the real actors in the expected scenarios, I wrote tests again real CentOS kernel.org mirrors, looking for repository metadata files, as an example use case of `wfind`.

I used [GinkGo](https://onsi.github.io/ginkgo/) as I like how it easily enables to design and implement the specifications of the program as you write tests. 

Moreover, regardless of whether or not you follow BDD, tests tend to appear self-explanatory.

Indeed, Ginkgo with Gomega matchers provide a DSL for writing tests in general like integration tests but also white-box and black-box unit tests.

```go
package find_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/maxgio92/wfind/internal/network"
	"github.com/maxgio92/wfind/pkg/find"
)

const (
	seedURL         = "https://mirrors.edge.kernel.org/centos/8-stream"
	fileRegexp      = "repomd.xml$"
	expectedResults = 155
)

var _ = Describe("File crawling", func() {
	Context("Async", func() {
		var (
			search = find.NewFind(
				find.WithAsync(true),
				find.WithSeedURLs([]string{seedURL}),
				find.WithFilenameRegexp(fileRegexp),
				find.WithFileType(find.FileTypeReg),
				find.WithRecursive(true),
			)
			actual        *find.Result
			err           error
			expectedCount = expectedResults
		)
		BeforeEach(func() {
			actual, err = search.Find()
		})
		It("Should not fail", func() {
			Expect(err).To(BeNil())
		})
		It("Should stage results", func() {
			Expect(actual.URLs).ToNot(BeEmpty())
			Expect(actual.URLs).ToNot(BeNil())
		})
		It("Should stage exact result count", func() {
			Expect(len(actual.URLs)).To(Equal(expectedCount))
		})
	})
})
```

As you can see, the order in which results are returned is not important and thus not tested.

## Retry logics

The first concrete goal of the retry logics was to start to see green flags from the GinkGo output.

So I expected to start by seeing tests to fail:

```shell
$ ginkgo --focus "File crawling" pkg/find
...
FAIL! ...
```

Then, in order to make tests to pass, it was needed a way to ensure that requests failed would have been retried.

Fortunately go-colly provide way to register a callback, that as per the documentation it registers a function that will be executed if an error occurs during the HTTP request, with [`OnError`](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L917).

That way it's possible to run a custom handler as the response (and the request) object and the error are available in context of the helper, as for the [signature](https://github.com/gocolly/colly/blob/v2.1.0/colly.go#L146).

### Dumb retrier

The first implementation of the retry could have been as simple as retry for a fixed amount of times, after a fixed amount of period.

For example:

```go
collector.OnError(func(resp *colly.Response, err error) {
  time.Sleep(2 * time.Second)
  resp.Request.Retry()
})
```

For sure this wasn't enough to improve the probability to make failing requests to succeed.

### Retry with exponential backoff

At first, a single retry might not be enough, and also, the optimal backoff size should vary depending on the failure cause and the context. Furthermore, it would be good to be increased as time passes in order to avoid overload on the actors.

So I decided to leverage the community projects and digging around backoff implementations. After that, I picked and imported [`github.com/cenkalti/backoff`](https://github.com/cenkalti/backoff) package.
I liked the design as it respects all the SOLID principles and because it provides API to a tunable exponential backoff algorithm. Also, it allows to mix and match with different custom backoff algorithms, without needing to implement a ticker.

Furthermore, I wanted to provide knobs to enable the retry behaviour for specific errors encountered doing HTTP requests. So I ended up including new dedicated options to the `wfind/pkg/find`'s ones:

```go
package find

// ...

// Options represents the options for the Find job.
type Options struct {
	// ...

	// ConnResetRetryBackOff controls the error handling on responses.
	// If not nil, when the connection is reset by the peer (TCP RST), the request
	// is retried with an exponential backoff interval.
	ConnResetRetryBackOff *ExponentialBackOffOptions

	// TimeoutRetryBackOff controls the error handling on responses.
	// If not nil, when the connection times out (based on client timeout), the request
	// is retried with an exponential backoff interval.
	TimeoutRetryBackOff *ExponentialBackOffOptions

	// ContextDeadlineExceededRetryBackOff controls the error handling on responses.
	// If not nil, when the request context deadline exceeds, the request
	// is retried with an exponential backoff interval.
	ContextDeadlineExceededRetryBackOff *ExponentialBackOffOptions
}

// ...

// crawlFiles returns a list of file names found from the seed URL,
// filtered by file name regex.
func (o *Options) crawlFiles() (*Result, error) {

	// Create the collector.
	co := colly.NewCollector(coOptions...)

	// Add the callback to Visit the linked resource, for each HTML element found
	co.OnHTML(HTMLTagLink, func(e *colly.HTMLElement) {
		// ...
	})

	// Manage errors.
	co.OnError(o.handleError)

	// ...

	// Wait until colly goroutines are finished.
	co.Wait()

	return &Result{BaseNames: files, URLs: urls}, nil
}

// handleError handles an error received making a colly.Request.
// It accepts a colly.Response and the error.
func (o *Options) handleError(response *colly.Response, err error) {
	switch {
	// Context timed out.
	case errors.Is(err, context.DeadlineExceeded):
		if o.ContextDeadlineExceededRetryBackOff != nil {
			retryWithExponentialBackoff(response.Request.Retry, o.TimeoutRetryBackOff)
		}
	// Request has timed out.
	case os.IsTimeout(err):
		if o.TimeoutRetryBackOff != nil {
			retryWithExponentialBackoff(response.Request.Retry, o.TimeoutRetryBackOff)
		}
	// Connection has been reset (RST) by the peer.
	case errors.Is(err, unix.ECONNRESET):
		if o.ConnResetRetryBackOff != nil {
			retryWithExponentialBackoff(response.Request.Retry, o.ConnResetRetryBackOff)
		}
	// Other failures.
	default:
		// ...
	}
}
```

With the implementation of the retry leveraging the `cenkalti/backoff` package, following the [example](https://github.com/cenkalti/backoff/blob/v4/example_test.go#L42C1-L71C2) provided:

```go
// retryWithExtponentialBackoff retries with an exponential backoff a function.
// Exponential backoff can be tuned with options accepted as arguments to the function.
func retryWithExponentialBackoff(retryF func() error, opts *ExponentialBackOffOptions) {
	ticker := backoff.NewTicker(
		utils.NewExponentialBackOff(
			utils.WithClock(opts.Clock),
			utils.WithInitialInterval(opts.InitialInterval),
			utils.WithMaxInterval(opts.MaxInterval),
			utils.WithMaxElapsedTime(opts.MaxElapsedTime),
		),
	)

	var err error

	// Ticks will continue to arrive when the previous retryF is still running,
	// so operations that take a while to fail could run in quick succession.
	for range ticker.C {
		if err = retryF(); err != nil {
			// Retry.
			continue
		}

		ticker.Stop()
		break
	}

	if err != nil {
		// Retry has failed.
		return
	}

	// Retry is successful.
}
```

And the end-to-end test could have been updated by enabling the retry behaviour for the context deadline exceeded, HTTP client transport's timeout, connection reset by peer cases:

```go
var _ = Describe("File crawling", func() {
	Context("Async", func() {
		var (
			search = find.NewFind(
				find.WithAsync(true),
				find.WithSeedURLs([]string{seedURL}),
				find.WithClientTransport(network.DefaultClientTransport),
				find.WithFilenameRegexp(fileRegexp),
				find.WithFileType(find.FileTypeReg),
				find.WithRecursive(true),

				// Enable retry backoff with default parameters.
				find.WithContextDeadlineExceededRetryBackOff(find.DefaultExponentialBackOffOptions),
				find.WithConnTimeoutRetryBackOff(find.DefaultExponentialBackOffOptions),
				find.WithConnResetRetryBackOff(find.DefaultExponentialBackOffOptions),
			)
			actual        *find.Result
			err           error
			expectedCount = expectedResults
		)
		BeforeEach(func() {
			actual, err = search.Find()
		})
		It("Should not fail", func() {
			Expect(err).To(BeNil())
		})
		It("Should stage results", func() {
			Expect(actual.URLs).ToNot(BeEmpty())
			Expect(actual.URLs).ToNot(BeNil())
		})
		It("Should stage exact result count", func() {
			Expect(len(actual.URLs)).To(Equal(expectedCount))
		})
	})
})
```

And I re-run the e2e test again:

```shell
$ ginkgo --focus "File crawling" pkg/find
```

But the tests took too much time consuming a lot of memory until it was out-of-memory killed.
Likely a memory leak or simply not efficient memory management was already present, but without retry logics nor performance tests it hadn't shown up.

So, a heap memory profile for the find run was then needed. The run specifics of the end-to-end test in example was enough.

## Memory profiling: entering pprof

Long story short, pprof is a standard library's package that serves via its HTTP server runtime profiling data in the format expected by the pprof visualization tool.

> I recommend the official documentation of the package, and this great [Julia Evans' blog](https://jvns.ca/blog/2017/09/24/profiling-go-with-pprof/).

So, I simply linked pprof package:

```go
package find

import (
  /// ...
  _ "net/http/pprof"

  // ...
)
```

modified the tested function to run in parallel its webserver:

```go
package find

// ...

func (o *Options) Find() (*Result, error) {
	go func() {
		log.Println(http.ListenAndServe("localhost:6060", nil))
	}()

	if err := o.Validate(); err != nil {
		return nil, errors.Wrap(err, "error validating find options")
	}

	switch o.FileType {
	case FileTypeReg:
		return o.crawlFiles()
	case FileTypeDir:
		return o.crawlFolders()
	default:
		return o.crawlFiles()
	}
}
```

and finally run the tests again:

```shell
$ ginkgo --focus "File crawling" pkg/find
```

and immediately invoke the pprof go tool to download the heap memory profile as a PNG image:

```shell
$ go tool pprof http://localhost:6060/debug/pprof/heap
(pprof) png
Generating report in profile001.png
```

Looking at the profile function call graph it was evident that a great amount of memory mapping was request by a reading: `io.ReadAll()`, called from `colly.Do()`:

![image](https://github.com/maxgio92/notes/assets/7593929/0e6da0f0-929d-456c-bc6f-ce5300750265)

So digging into the go-colly HTTP backend `Do` implementation, the [offending line](https://github.com/gocolly/colly/blob/v2.1.0/http_backend.go#L209) was:

```go
package colly

//...

func (h *httpBackend) Do(request *http.Request, bodySize int, checkHeadersFunc checkHeadersFunc) (*Response, error) {
	// ...
	res, err := h.Client.Do(request)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	// ...
	var bodyReader io.Reader = res.Body
	if bodySize > 0 {
		bodyReader = io.LimitReader(bodyReader, int64(bodySize))
	}
	// ...
	body, err := ioutil.ReadAll(bodyReader)
	// ...
}
```

So, a first solution was to limit the size of the response body which was being read.

### Max HTTP body size

Fortunately, go-colly provides a way to set the requests' maximum body size that will be read, so I ended up exposing an option:

```go
package find

// Options represents the options for the Find job.
type Options struct {
	// ...
	// MaxBodySize is the limit in bytes of each of the retrieved response body.
	MaxBodySize int
	// ...
}
```

which then would have fill the colly collector setting:

```go
package find

// ...

// crawlFiles returns a list of file names found from the seed URL, filtered by file name regex.
func (o *Options) crawlFiles() (*Result, error) {
	// ...

	// Create the collector settings
	coOptions := []func(*colly.Collector){
		// ...
		colly.MaxBodySize(o.MaxBodySize),
	}
```

Finally I updated the end-to-end test, tuning the parameter with an expected maximum value, considering the HTML nature of expected response body:

```go
var _ = Describe("File crawling", func() {
	Context("Async", func() {
		var (
			search = find.NewFind(
				find.WithAsync(true),
				find.WithSeedURLs([]string{seedURL}),
				find.WithFilenameRegexp(fileRegexp),
				find.WithFileType(find.FileTypeReg),
				find.WithRecursive(true),
				find.WithMaxBodySize(1024*512),
				find.WithConnTimeoutRetryBackOff(find.DefaultExponentialBackOffOptions),
				find.WithConnResetRetryBackOff(find.DefaultExponentialBackOffOptions),
			)
			actual        *find.Result
			err           error
			expectedCount = expectedResults
		)
		BeforeEach(func() {
			actual, err = search.Find()
		})
		It("Should not fail", func() {
			Expect(err).To(BeNil())
		})
		It("Should stage results", func() {
			Expect(actual.URLs).ToNot(BeEmpty())
			Expect(actual.URLs).ToNot(BeNil())
		})
		It("Should stage exact result count", func() {
			Expect(len(actual.URLs)).To(Equal(expectedCount))
		})
	})
}
```

and run again the tests:

```shell
$ ginkgo --focus "File crawling" pkg/find
...
Ran 3 of 3 Specs in 7.552 seconds
SUCCESS! -- 3 Passed | 0 Failed | 0 Pending | 0 Skipped
```

Now tests passed in just less than 8 seconds!

## More tuning: HTTP client's Transport

Another important network and connection parameters are provided with the go [`net/http Transport`](https://pkg.go.dev/net/http).
Connection timeout, TCP keep alive interval, TLS handshake timeout, Go net/http idle connnection pool maximum size, idle connections timeout are just some of them.

The [connection pool](https://github.com/golang/go/blob/go1.21.0/src/net/http/transport.go#L925) size here is fundamental to be tuned in order to satisfy the level of concurrency enabled by the asynchronous mode of go-colly, hence of wfind.

In detail, Go [`net/http`](https://pkg.go.dev/net/http) `Get` keeps the connection pool as a cache of TCP connections, but when all are in use it opens another one.
If the parallelism is greater than the limit of idle connections, the program is going to be [regularly discarding connections](https://github.com/golang/go/blob/go1.21.0/src/net/http/transport.go#L999) and opening new ones, the latters ending up in `TIME_WAIT` TCP state for two minutes, tying up that connection.

> About `TIME_WAIT` TCP state I recommend [this blog](https://vincent.bernat.ch/en/blog/2014-tcp-time-wait-state-linux) by Vincent Bernat.

From the Go standard library [`net/http`](https://pkg.go.dev/net/http) package:

```go
package http

type Transport struct {
	// ...

	// MaxIdleConns controls the maximum number of idle (keep-alive)
	// connections across all hosts. Zero means no limit.
	MaxIdleConns int

	// MaxIdleConnsPerHost, if non-zero, controls the maximum idle
	// (keep-alive) connections to keep per-host. If zero,
	// DefaultMaxIdleConnsPerHost is used.
	MaxIdleConnsPerHost int
```

As so, it was very useful to provide way to inject a client Transport configured for specific use cases:

```go
package find

// Options represents the options for the Find job.
type Options struct {
	// ...

	// ClientTransport represents the Transport used for the HTTP client.
	ClientTransport http.RoundTripper

	// ...
}
```

and in the go-colly collector to set up the client with the provided Transport:

```go
package find

// crawlFiles returns a list of file names found from the seed URL, filtered by file name regex.
func (o *Options) crawlFiles() (*Result, error) {
	...

	// Create the collector settings
	coOptions := []func(*colly.Collector){
		colly.AllowedDomains(allowedDomains...),
		colly.Async(o.Async),
		colly.MaxBodySize(o.MaxBodySize),
	}

	...

	// Create the collector.
	co := colly.NewCollector(coOptions...)
	if o.ClientTransport != nil {
		co.WithTransport(o.ClientTransport)
	}
```

## Wrapping up

As `wfind` main command is the first consumer, from its perspective, the command `Run` would consume it as so:

```go
func (o *Command) Run(_ *cobra.Command, args []string) error {
	...

	// Network client dialer.
	dialer := network.NewDialer(
		network.WithTimeout(o.ConnectionTimeout),
		network.WithKeepAlive(o.KeepAliveInterval),
	)

	// HTTP client transport.
	transport := network.NewTransport(
		network.WithDialer(dialer),
		network.WithIdleConnsTimeout(o.IdleConnTimeout),
		network.WithTLSHandshakeTimeout(o.TLSHandshakeTimeout),
		network.WithMaxIdleConns(o.ConnPoolSize),
		network.WithMaxIdleConnsPerHost(o.ConnPoolPerHostSize),
	)

	// Wfind finder.
	finder := find.NewFind(
		find.WithSeedURLs(o.SeedURLs),
		find.WithFilenameRegexp(o.FilenameRegexp),
		find.WithFileType(o.FileType),
		find.WithRecursive(o.Recursive),
		find.WithVerbosity(o.Verbose),
		find.WithAsync(o.Async),
		find.WithClientTransport(transport),
	)
```

for which default command's flag default values are provided by wfind for its specific use case.

## Conclusion

The retry logics allowed to provide consistency, and network and transport tuning in the HTTP client improved the efficiency and performance.

As usual, there's alwasy something to learn and it's cool how deep we can dig into things. I was curious about the reason why so much connections in `TIME_WAIT` state were left during the scraping, even if they're not a problem. So learning how Go runtime manages the connections keeping a cache pool of them was the key to understand more and how to optimize the management in cases like this, where there may be high parallalism and probably high concurrency as well, on OS network stack's resources.

Moreover, I like Go every day more, as already the standard library provides often all you need with primitives, and in this case for network and for synchronization.

### Thank you!

I hope this was interesting for you as it was for me. Please, feel free to reach out!

[Twitter](https://twitter.com/maxgio92)
[Mastodon](https://hachyderm.io/@maxgio92)
[Github](https://github.com/maxgio92)
[Linkedin](https://linkedin.com/in/maxgio)
