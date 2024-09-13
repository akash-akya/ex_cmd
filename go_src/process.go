package main

import (
	"io"
	"os"
	"os/exec"
)

func startCommandPipeline(proc *exec.Cmd, input <-chan []byte, inputDemand chan<- Packet, outputDemand <-chan Packet) chan []byte {
	logger.Printf("Command: %v\n", proc.String())

	cmdInput, err := proc.StdinPipe()
	fatalIf(err)

	cmdOutput, err := proc.StdoutPipe()
	fatalIf(err)

	cmdError, err := proc.StderrPipe()
	fatalIf(err)

	execErr := proc.Start()
	fatalIf(execErr)

	go writeToCommandStdin(cmdInput, input, inputDemand)

	go printStderr(cmdError)

	output := make(chan []byte)
	go readCommandStdout(cmdOutput, outputDemand, output)

	return output
}

func writeToCommandStdin(cmdInput io.WriteCloser, input <- chan []byte, inputDemand chan<- Packet) {
	var data []byte
	var ok bool

	defer func() {
		cmdInput.Close()
	}()

	for {
		inputDemand <- Packet{SendInput, make([]byte, 0)}

		select {
		case data, ok = <-input:
			if !ok {
				return
			}
		}

		// blocking
		_, writeErr := cmdInput.Write(data)
		if writeErr != nil {
			switch writeErr.(type) {
			// ignore broken pipe or closed pipe errors
			case *os.PathError:
				return
			default:
				fatal(writeErr)
			}
		}
	}
}

func readCommandStdout(cmdOutput io.ReadCloser, outputDemand <-chan Packet, output chan<- []byte) {
	var buf [BufferSize]byte
	var packet Packet
	var ok bool

	cmdOutputClosed := false

	for {
		select {
		case packet, ok = <-outputDemand:
			if !ok {
				return
			}
		}

		switch packet.tag {
		case CloseOutput:
			if !cmdOutputClosed {
				logger.Printf("close command output")
				// we don't actually have to close the pipe.
				// proc.Wait() internally closes all pipes
				cmdOutput.Close()
				cmdOutputClosed = true
				output <- make([]byte, 0)
			} else {
				fatal("close command on closed command output")
			}

		case SendOutput:
			if cmdOutputClosed {
				fatal("asking output while command output is closed")
			}

			// blocking
			bytesRead, readErr := cmdOutput.Read(buf[:])
			if bytesRead > 0 {
				output <- buf[:bytesRead]
			} else if readErr == io.EOF || bytesRead == 0 {
				logger.Printf("cmdStdout return %v", readErr)
				cmdOutputClosed = true
				output <- make([]byte, 0)
				return
			} else {
				fatal(readErr)
			}
		}
	}
}

func printStderr(cmdError io.ReadCloser) {
	var buf [BufferSize]byte

	defer func() {
		cmdError.Close()
	}()

	for {
		bytesRead, readErr := cmdError.Read(buf[:])
		if bytesRead > 0 {
			logger.Printf(string(buf[:bytesRead]))
		} else if readErr == io.EOF || bytesRead == 0 {
			return
		} else {
			fatal(readErr)
		}
	}
}
