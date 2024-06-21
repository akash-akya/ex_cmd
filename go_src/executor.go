package main

import (
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

func execute(workdir string, args []string) error {
	done := make(chan struct{})

	sigs := make(chan os.Signal, 1)
	input := make(chan Packet, 1)
	outputDemand := make(chan Packet)
	inputDemand := make(chan Packet)

	proc := exec.Command(args[0], args[1:]...)
	proc.Dir = workdir
	proc.Env = append(os.Environ(), readEnvFromStdin()...)

	logger.Printf("Command path: %v\n", proc.Path)

	output := startCommandPipeline(proc, input, inputDemand, outputDemand)

	// Capture common signals.
	// Setting notify for SIGPIPE is important to capture and without that
	// we won't be able to handle abrupt beam vm terminations
	// Also, SIGPIPE behaviour in golang is bit complex,
	// see: https://pkg.go.dev/os/signal@go1.22.4#hdr-SIGPIPE
	signal.Notify(sigs, os.Interrupt, syscall.SIGINT, syscall.SIGTERM, syscall.SIGPIPE)

	// go handleSignals(input, outputDemand, done)
	go dispatchStdin(input, outputDemand, done)
	go collectStdout(proc.Process.Pid, output, inputDemand, sigs, done)

	// wait for pipline to exit
	<-done

	err := safeExit(proc)
	if e, ok := err.(*exec.Error); ok {
		// This shouldn't really happen in practice because we check for
		// program existence in Elixir, before launching odu
		logger.Printf("Command exited with error: %v\n", e)
		os.Exit(3)
	}
	// TODO: return Stderr and exit status to beam process
	logger.Printf("Command exited\n")
	return err
}

func dispatchStdin(input chan<- Packet, outputDemand chan<- Packet, done chan struct{}) {
	// closeChan := closeInputHandler(input)
	var dispatch = func(packet Packet) {
		switch packet.tag {
		case SendOutput:
			outputDemand <- packet
		default:
			input <- packet
		}
	}

	defer func() {
		close(input)
		close(outputDemand)
	}()

	stdinReader(dispatch, done)
}

func collectStdout(pid int, output <-chan Packet, inputDemand <-chan Packet, sigs <-chan os.Signal, done chan struct{}) {
	defer func() {
		close(done)
	}()

	merged := func() (Packet, bool) {
		select {
		case sig := <-sigs:
			logger.Printf("Received OS Signal: ", sig)
			return Packet{}, false

		case v, ok := <-inputDemand:
			return v, ok

		case v, ok := <-output:
			return v, ok
		}
	}

	stdoutWriter(pid, merged, done)
}

func safeExit(proc *exec.Cmd) error {
	done := make(chan error, 1)
	go func() {
		done <- proc.Wait()
	}()
	select {
	case <-time.After(3 * time.Second):
		if err := proc.Process.Kill(); err != nil {
			logger.Fatal("failed to kill process: ", err)
		}
		logger.Println("process killed as timeout reached")
		return nil
	case err := <-done:
		return err
	}
}
