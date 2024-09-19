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
const CloseOutput = 10
const Kill = 11
const ExitStatus = 12

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

func execute(workdir string, args []string, stderrConfig string) error {
	writerDone := make(chan struct{})
	// must be buffered so that function can close without blocking
	stdinClose := make(chan struct{}, 1)
	kill := make(chan bool, 1)
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

	runPipeline(proc, writerDone, stdinClose, kill, stderrConfig)
	err := waitPipelineTermination(proc, sigs, stdinClose, writerDone, kill)

	if err == nil {
		writeCmdExitCode(0)
		return nil
	}

	if exitError, ok := err.(*exec.ExitError); ok {
		writeCmdExitCode(exitError.ExitCode())
		return nil
	}

	return err
}

func runPipeline(proc *exec.Cmd, writerDone chan struct{}, stdinClose chan struct{}, kill chan<- bool, stderrConfig string) {
	cmdInput := make(chan []byte, 1)
	cmdOutputDemand := make(chan Packet)
	cmdInputDemand := make(chan Packet)

	cmdOutput := startCommandPipeline(proc, cmdInput, cmdInputDemand, cmdOutputDemand, stderrConfig)

	// go handleSignals(input, outputDemand, done)
	go stdinReader(cmdInput, cmdOutputDemand, writerDone, stdinClose, kill)
	go stdoutWriter(proc.Process.Pid, cmdOutput, cmdInputDemand, writerDone)
}

func stdinReader(cmdInput chan<- []byte, cmdOutputDemand chan<- Packet, writerDone <-chan struct{}, stdinClose chan<- struct{}, kill chan<- bool) {
	// closeChan := closeInputHandler(input)
	cmdInputClosed := false
	killCommand := false

	defer func() {
		if !cmdInputClosed {
			close(cmdInput)
		}
		close(cmdOutputDemand)
	}()

	for {
		select {
		case <-writerDone:
			return
		default:
		}

		packet, readErr := readPacketFromStdin()
		if readErr == io.EOF {
			close(stdinClose)
			return
		} else if readErr != nil {
			fatal(readErr)
		}

		switch packet.tag {
		case Kill:
			if !killCommand {
				kill <- true
				killCommand = true
			}

		case CloseInput:
			if !cmdInputClosed {
				close(cmdInput)
				cmdInputClosed = true
			} else {
				logger.Printf("close on closed command input")
			}

		case SendOutput:
			cmdOutputDemand <- packet

		case CloseOutput:
			cmdOutputDemand <- packet

		case Input:
			if cmdInputClosed {
				fatal("trying to send input on closed command input stream")
			}
			cmdInput <- packet.data
		}
	}
}

func stdoutWriter(pid int, cmdStdout <-chan []byte, cmdInputDemand <-chan Packet, writerDone chan<- struct{}) {
	var ok bool
	var packet Packet
	var buf [4]byte
	var data []byte

	cmdOutputClosed := false

	defer func() {
		if !cmdOutputClosed {
			writePacketToStdout(OutputEOF, make([]byte, 0))
		}
		logger.Printf("writerDone")
		close(writerDone)
	}()

	// we first write pid before writing anything
	writeUint32Be(buf[:], uint32(pid))
	writePacketToStdout(Pid, buf[:])

	for {
		select {
		case packet, ok = <-cmdInputDemand:
			if !ok {
				return
			}
			writePacketToStdout(packet.tag, packet.data)

		case data, ok = <-cmdStdout:
			if cmdOutputClosed == true {
				fatal("data on closed cmdOutput stream")
			}

			if !ok {
				fatal("error on cmdStdout")
			}

			if len(data) > BufferSize {
				fatal("Invalid payloadLen")
			} else if len(data) == 0 {
				// if we are getting EOF then we are done here
				// there won't be anymore command coming
				writePacketToStdout(OutputEOF, make([]byte, 0))
				cmdOutputClosed = true
				return
			} else {
				writePacketToStdout(Output, data)
			}
		}
	}
}

func waitPipelineTermination(proc *exec.Cmd, sigs <-chan os.Signal, stdinClose <-chan struct{}, writerDone <-chan struct{}, kill <-chan bool) error {
	timeout := 1 * time.Second

	select {
	case sig := <-sigs:
		logger.Printf("Received OS Signal: %v\n", sig)
	case <-stdinClose:
		// When stdin closes it imply that VM is down or process GenServer
		// is killed so we must prepare for termination.
		//
		// Not that stdin close for middleware is different from stdin close
		// for the external program (CloseInput)
	case <-writerDone:
	case <-kill:
		timeout = 0
	}

	cmdExit := make(chan error)

	go func() {
		cmdExit <- proc.Wait()
	}()

	return safeExit(proc, cmdExit, kill, timeout)
}

func safeExit(proc *exec.Cmd, procErr <-chan error, kill <-chan bool, timeout time.Duration) error {
	logger.Printf("Attempt graceful exit\n")

	select {
	case err := <-procErr:
		logger.Printf("Cmd completed with err: %v", err)
		return err
	case <-kill:
		if err := proc.Process.Kill(); err != nil {
			logger.Fatal("failed to kill process: ", err)
			return err
		}
		logger.Println("process killed by user signal")
		return <-procErr
	case <-time.After(timeout):
		if err := proc.Process.Kill(); err != nil {
			logger.Fatal("failed to kill process: ", err)
			return err
		}
		logger.Println("process killed as exit timeout reached")
		return <-procErr
	}
}

func writeStartError(reason string) {
	writePacketToStdout(StartError, []byte(reason))
}

func writeCmdExitCode(code int) {
	exitCode := uint32(code)
	logger.Printf("Command exited with exit status: %v", exitCode)

	binExitCode := make([]byte, 4)
	binary.BigEndian.PutUint32(binExitCode, exitCode)

	writePacketToStdout(ExitStatus, binExitCode)
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
