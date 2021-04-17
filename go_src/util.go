package main

import (
	"fmt"
	"io"
	"os"
)

func die(reason string) {
	if logger != nil {
		logger.Printf("dying: %v\n", reason)
	}
	fmt.Fprintln(os.Stderr, reason)
	os.Exit(-1)
}

func dieUsage(reason string) {
	if logger != nil {
		logger.Printf("dying: %v\n", reason)
	}

	writeStartError(reason)

	fmt.Fprintf(os.Stderr, "%v\n%v\n", reason, usage)
	os.Exit(-1)
}

func fatal(any interface{}) {
	if logger == nil {
		fmt.Fprintf(os.Stderr, "%v\n", any)
		os.Exit(-1)
	}
	logger.Panicf("%v\n", any)
}

func fatalIf(any interface{}) {
	if logger == nil {
		fmt.Fprintf(os.Stderr, "%v\n", any)
		os.Exit(-1)
	}
	if any != nil {
		logger.Panicf("%v\n", any)
	}
}

type NullReadWriteCloser struct {
	Signal chan struct{}
}

func (w NullReadWriteCloser) Write(p []byte) (n int, err error) {
	select {
	case <-w.Signal:
		return 0, new(os.PathError)
	default:
		return len(p), nil
	}
}

func (w NullReadWriteCloser) Read(p []byte) (n int, err error) {
	select {
	case <-w.Signal:
		return 0, io.EOF
	}
}

func (w NullReadWriteCloser) Close() (err error) {
	select {
	case <-w.Signal:
	default:
		close(w.Signal)
	}
	return nil
}
