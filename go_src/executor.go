package main

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

const SendInput = 1
const SendOutput = 2
const Output = 3
const Input = 4
const CloseInput = 5
const OutputEOF = 6
const CommandEnv = 7
const Pid = 8
const StartError = 9

// This size is *NOT* related to pipe buffer size
// 4 bytes for payload length + 1 byte for tag
const BufferSize = (1 << 16) - 5

// fixed buffer for IO
var buf = make([]byte, BufferSize+5)

type Packet struct {
	tag  uint8
	data []byte
}

type InputDispatcher func(Packet)

type OutPacket func() (Packet, bool)

func execute(workdir string, args []string) error {
	writerDone := make(chan struct{})
	// must be buffered so that function can close without blocking
	stdinClose := make(chan struct{}, 1)
	sigs := make(chan os.Signal)

	// Capture common signals.
	// Setting notify for SIGPIPE is important to capture and without that
	// we won't be able to handle abrupt beam vm terminations
	// Also, SIGPIPE behavior in golang is complex,
	//
	// see: https://pkg.go.dev/os/signal@go1.22.4#hdr-SIGPIPE
	signal.Notify(sigs, os.Interrupt, syscall.SIGINT, syscall.SIGTERM, syscall.SIGPIPE)

	proc := exec.Command(args[0], args[1:]...)
	proc.Dir = workdir
	proc.Env = append(os.Environ(), readEnvFromStdin()...)

	cmdExit := runPipeline(proc, writerDone, stdinClose)
	err := waitPipelineTermination(proc, cmdExit, sigs, stdinClose, writerDone)

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

func runPipeline(proc *exec.Cmd, writerDone chan struct{}, stdinClose chan struct{}) chan error {
	cmdInput := make(chan Packet, 1)
	cmdOutputDemand := make(chan Packet)
	cmdInputDemand := make(chan Packet)
	cmdExit := make(chan error)

	cmdOutput := startCommandPipeline(proc, cmdInput, cmdInputDemand, cmdOutputDemand)

	// go handleSignals(input, outputDemand, done)
	go stdinReader(cmdInput, cmdOutputDemand, writerDone, stdinClose)
	go stdoutWriter(proc.Process.Pid, cmdOutput, cmdInputDemand, writerDone)

	go func() {
		cmdExit <- proc.Wait()
	}()

	return cmdExit
}

func stdinReader(cmdInput chan<- Packet, cmdOutputDemand chan<- Packet, writerDone <-chan struct{}, stdinClose chan<- struct{}) {
	// closeChan := closeInputHandler(input)
	defer func() {
		close(cmdInput)
		close(cmdOutputDemand)
		close(stdinClose)
	}()

	for {
		select {
		case <-writerDone:
			return
		default:
		}

		packet, readErr := readPacketFromStdin()
		if readErr == io.EOF {
			return
		} else if readErr != nil {
			fatal(readErr)
		}

		switch packet.tag {
		case SendOutput:
			cmdOutputDemand <- packet
		default:
			cmdInput <- packet
		}
	}
}

func stdoutWriter(pid int, cmdStdout <-chan Packet, cmdInputDemand <-chan Packet, writerDone chan<- struct{}) {
	var ok bool
	var packet Packet
	var buf [4]byte

	defer func() {
		close(writerDone)
	}()

	// we first write pid before writing anything
	writeUint32Be(buf[:], uint32(pid))
	writePacketToStdout(Pid, buf[:])

	for {
		select {
		case packet, ok = <-cmdInputDemand:
		case packet, ok = <-cmdStdout:
		}

		if !ok {
			return
		}

		if len(packet.data) > BufferSize {
			fatal("Invalid payloadLen")
		}

		writePacketToStdout(packet.tag, packet.data)
	}
}

func waitPipelineTermination(proc *exec.Cmd, cmdExit <-chan error, sigs <-chan os.Signal, stdinClose <-chan struct{}, writerDone <-chan struct{}) error {
	var err error

	select {
	case e := <-cmdExit:
		// a program might exit without any IO
		err = e

	case sig := <-sigs:
		logger.Printf("Received OS Signal: %v\n", sig)
		err = safeExit(proc, cmdExit)

	case <-stdinClose:
		// When stdin closes it imply that VM is down or process GenServer
		// is killed so we must prepare for termination.
		//
		// Not that stdin close for middleware is different from stdin close
		// for the external program (CloseInput)
		err = safeExit(proc, cmdExit)

	case <-writerDone:
		err = safeExit(proc, cmdExit)
	}

	return err
}

func safeExit(proc *exec.Cmd, procErr <-chan error) error {
	logger.Printf("safe exit\n")

	select {
	case err := <-procErr:
		return err
	case <-time.After(3 * time.Second):
		if err := proc.Process.Kill(); err != nil {
			logger.Fatal("failed to kill process: ", err)
		}
		logger.Println("process killed as timeout reached")
		return nil
	}
}

func writeStartError(reason string) {
	writePacketToStdout(StartError, []byte(reason))
}

func readEnvFromStdin() []string {
	// first packet must be env
	packet, err := readPacketFromStdin()
	if err != nil {
		fatal(err)
	}

	if packet.tag != CommandEnv {
		fatal("First packet must be command Env")
	}

	var env []string
	var length int
	data := packet.data

	for i := 0; i < len(data); {
		length = int(binary.BigEndian.Uint16(data[i : i+2]))
		i += 2

		entry := string(data[i : i+length])
		env = append(env, entry)

		i += length
	}

	logger.Printf("Command Env: %v\n", env)

	return env
}

func readPacketFromStdin() (Packet, error) {
	var readErr error
	var length uint32
	var tag uint8

	buf := make([]byte, BufferSize)

	length, readErr = readUint32(os.Stdin)
	if readErr == io.EOF {
		return Packet{}, io.EOF
	} else if readErr != nil {
		return Packet{}, readErr
	}

	dataLen := length - 1
	if dataLen < 0 || dataLen > BufferSize { // payload must be atleast tag size
		return Packet{}, errors.New("input payload size is invalid")
	}

	tag, readErr = readUint8(os.Stdin)
	if readErr != nil {
		return Packet{}, readErr
	}

	_, readErr = io.ReadFull(os.Stdin, buf[:dataLen])
	if readErr != nil {
		return Packet{}, readErr
	}

	return Packet{tag, buf[:dataLen]}, nil
}

func writePacketToStdout(tag uint8, data []byte) {
	payloadLen := len(data) + 1

	writeUint32Be(buf[:4], uint32(payloadLen))
	writeUint8Be(buf[4:5], tag)
	copy(buf[5:], data)

	_, writeErr := os.Stdout.Write(buf[:payloadLen+4])
	if writeErr != nil {
		switch writeErr.(type) {
		// ignore broken pipe or closed pipe errors here.
		// currently readCommandStdout closes output chan, making the
		// flow break.
		case *os.PathError:
			logger.Printf("os.PathError: %v\n", writeErr)
			return
		default:
			fatal(writeErr)
		}
	}
	// logger.Printf("stdout written bytes: %v\n", bytesWritten)
}

func readUint32(stdin io.Reader) (uint32, error) {
	var buf [4]byte

	bytesRead, readErr := io.ReadFull(stdin, buf[:])
	if readErr != nil {
		return 0, io.EOF
	} else if bytesRead == 0 {
		return 0, readErr
	}
	return binary.BigEndian.Uint32(buf[:]), nil
}

func readUint8(stdin io.Reader) (uint8, error) {
	var buf [1]byte

	bytesRead, readErr := io.ReadFull(stdin, buf[:])
	if readErr != nil {
		return 0, io.EOF
	} else if bytesRead == 0 {
		return 0, readErr
	}
	return uint8(buf[0]), nil
}

func writeUint32Be(data []byte, num uint32) {
	binary.BigEndian.PutUint32(data, num)
}

func writeUint8Be(data []byte, num uint8) {
	data[0] = byte(num)
}
