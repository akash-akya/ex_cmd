package main

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
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

type Packet struct {
	tag  uint8
	data []byte
}

type InputDispatcher func(Packet)

func stdinReader(dispatch InputDispatcher, done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		default:
		}

		packet, readErr := readPacket()
		if readErr == io.EOF {
			return
		}
		fatalIf(readErr)

		dispatch(packet)
	}
}

type OutPacket func() (Packet, bool)

func stdoutWriter(pid int, fn OutPacket, done <-chan struct{}) {
	var ok bool
	var packet Packet

	var buf [4]byte

	// we first write pid before writing anything
	writeUint32Be(buf[:], uint32(pid))
	writePacket(Pid, buf[:])

	for {
		packet, ok = fn()
		if !ok {
			return
		}

		if len(packet.data) > BufferSize {
			fatal("Invalid payloadLen")
		}

		writePacket(packet.tag, packet.data)
	}
}

func writeStartError(reason string) {
	writePacket(StartError, []byte(reason))
}

func readEnvFromStdin() []string {
	// first packet must be env
	packet, err := readPacket()
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

func readPacket() (Packet, error) {
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

var buf = make([]byte, BufferSize+5)

func writePacket(tag uint8, data []byte) {
	payloadLen := len(data) + 1

	writeUint32Be(buf[:4], uint32(payloadLen))
	writeUint8Be(buf[4:5], tag)
	copy(buf[5:], data)

	_, writeErr := os.Stdout.Write(buf[:payloadLen+4])
	if writeErr != nil {
		switch writeErr.(type) {
		// ignore broken pipe or closed pipe errors
		case *os.PathError:
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
