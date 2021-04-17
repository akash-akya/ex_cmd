package main

import (
	"io"
	"os"
	"os/exec"
)

func startCommandPipeline(proc *exec.Cmd, input <-chan Packet, inputDemand chan<- Packet, outputDemand <-chan Packet) <-chan Packet {
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

	output := make(chan Packet)
	go readCommandStdout(cmdOutput, outputDemand, output)

	return output
}

func writeToCommandStdin(cmdInput io.WriteCloser, input <-chan Packet, inputDemand chan<- Packet) {
	var packet Packet
	var ok bool

	defer func() {
		cmdInput.Close()
		// close(inputDemand)
	}()

	for {
		inputDemand <- Packet{SendInput, make([]byte, 0)}

		select {
		case packet, ok = <-input:
			if !ok {
				return
			}
		}

		switch packet.tag {
		case CloseInput:
			return

		case Input:
			// blocking
			_, writeErr := cmdInput.Write(packet.data)
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
}

func readCommandStdout(cmdOutput io.ReadCloser, outputDemand <-chan Packet, output chan<- Packet) {
	var buf [BufferSize]byte

	defer func() {
		output <- Packet{OutputEOF, make([]byte, 0)}
		cmdOutput.Close()
		close(output)
	}()

	for {
		select {
		case _, ok := <-outputDemand:
			if !ok {
				return
			}
		}

		// blocking
		bytesRead, readErr := cmdOutput.Read(buf[:])
		if bytesRead > 0 {
			output <- Packet{Output, buf[:bytesRead]}
		} else if readErr == io.EOF || bytesRead == 0 {
			return
		} else {
			fatal(readErr)
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
