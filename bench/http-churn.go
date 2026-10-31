// A small HTTP/1.1 connection-churn client. Validate every status/body and
// require one successful dial per response; keep-alive and HTTP/2 are disabled.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	url := flag.String("url", "", "HTTP URL serving hello world")
	duration := flag.Duration("duration", 3*time.Second, "load duration")
	concurrency := flag.Int("concurrency", 64, "simultaneous connections")
	threads := flag.Int("threads", 2, "Go scheduler threads")
	rate := flag.Int("rate", 1000, "Total new connections per second (0 for unrestricted saturation)")
	reset := flag.Bool("reset-on-close", false, "Reset TCP after reading the response to avoid TIME_WAIT port exhaustion")
	flag.Parse()
	if *url == "" || *duration <= 0 || *concurrency < 1 || *threads < 1 || *rate < 0 {
		fmt.Fprintln(os.Stderr, "invalid benchmark arguments")
		os.Exit(2)
	}
	runtime.GOMAXPROCS(*threads)
	var dials atomic.Int64
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		DisableKeepAlives: true,
		ForceAttemptHTTP2: false,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := dialer.DialContext(ctx, network, address)
			if err == nil {
				if *reset {
					if tcp, ok := conn.(*net.TCPConn); ok {
						if err = tcp.SetLinger(0); err != nil {
							conn.Close()
							return nil, err
						}
					}
				}
				dials.Add(1)
			}
			return conn, err
		},
	}
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	latencies := make([][]int64, *concurrency)
	failures := make([]int, *concurrency)
	firstErrors := make([]string, *concurrency)
	var group sync.WaitGroup
	start := time.Now()
	deadline := start.Add(*duration)
	stop, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	var tokens <-chan time.Time
	if *rate > 0 {
		ticker := time.NewTicker(time.Second / time.Duration(*rate))
		defer ticker.Stop()
		tokens = ticker.C
	}
	for i := 0; i < *concurrency; i++ {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			for time.Now().Before(deadline) {
				if tokens != nil {
					select {
					case <-stop.Done():
						return
					case <-tokens:
					}
				}
				before := time.Now()
				req, _ := http.NewRequest("GET", *url, nil)
				req.Close = true
				res, err := client.Do(req)
				if err == nil {
					var body [12]byte
					var n int
					n, err = io.ReadFull(res.Body, body[:])
					res.Body.Close()
					if res.StatusCode != 200 || n != 11 || string(body[:n]) != "hello world" || err != io.ErrUnexpectedEOF {
						err = fmt.Errorf("invalid response: status=%d bytes=%d read=%v", res.StatusCode, n, err)
					} else {
						err = nil
					}
				}
				if err != nil {
					failures[index]++
					if firstErrors[index] == "" {
						firstErrors[index] = err.Error()
					}
				} else {
					latencies[index] = append(latencies[index], time.Since(before).Nanoseconds())
				}
			}
		}(i)
	}
	group.Wait()
	elapsed := time.Since(start).Seconds()
	transport.CloseIdleConnections()
	var samples []int64
	failed := 0
	firstError := ""
	for i, rows := range latencies {
		samples = append(samples, rows...)
		failed += failures[i]
		if firstError == "" {
			firstError = firstErrors[i]
		}
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	percentile := func(p float64) float64 {
		if len(samples) == 0 {
			return 0
		}
		return float64(samples[int(p*float64(len(samples)-1))]) / 1e6
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"req_s": float64(len(samples)) / elapsed, "elapsed_s": elapsed,
		"complete_requests": len(samples), "failed_requests": failed,
		"connections": dials.Load(), "first_error": firstError, "reset_on_close": *reset, "rate_limit": *rate,
		"latency_ms": map[string]float64{"50": percentile(.50), "99": percentile(.99)},
	})
	if failed != 0 || len(samples) == 0 || dials.Load() != int64(len(samples)) {
		os.Exit(1)
	}
}
