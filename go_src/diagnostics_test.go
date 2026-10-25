package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestPrivateCommandDiagnostics(t *testing.T) {
	const secret = "SYNTHETIC_GO_ENV_ARG_NOT_A_CREDENTIAL"
	var output bytes.Buffer
	previousLogger := logger
	logger = log.New(&output, "", 0)
	defer func() { logger = previousLogger }()
	previousVersion := *protocolVersionFlag
	*protocolVersionFlag = ProtocolVersion
	defer func() { *protocolVersionFlag = previousVersion }()
	validateArgs([]string{"sh", secret})
	input, err := os.CreateTemp(t.TempDir(), "environment")
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	entry := []byte("EX_CMD_SYNTHETIC=" + secret)
	payload := make([]byte, len(entry)+2)
	binary.BigEndian.PutUint16(payload, uint16(len(entry)))
	copy(payload[2:], entry)
	if err := binary.Write(input, binary.BigEndian, uint32(len(payload)+1)); err != nil {
		t.Fatal(err)
	}
	input.Write([]byte{CommandEnv})
	input.Write(payload)
	input.Seek(0, 0)
	previousInput := os.Stdin
	os.Stdin = input
	defer func() { os.Stdin = previousInput }()
	env := readEnvFromStdin()
	if len(env) != 1 || env[0] != string(entry) {
		t.Fatalf("private payload changed")
	}
	command := exec.Command("sh", "-c", "exit 0", secret)
	command.Env = append(os.Environ(), env...)
	in := make(chan []byte)
	close(in)
	demand := make(chan Packet, 1)
	out := make(chan Packet)
	close(out)
	startCommandPipeline(command, in, demand, out, "disable")
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), secret) {
		t.Fatal("private launch values reached Go diagnostics")
	}
	if !strings.Contains(output.String(), "values redacted") {
		t.Fatal("diagnostic path not exercised")
	}
}

// Exercise the shipped native executable with optional stderr logging enabled.
func TestNativePrivateDiagnostics(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell fixture requires Unix")
	}
	const secret = "SYNTHETIC_NATIVE_DIAGNOSTIC_NOT_A_CREDENTIAL"
	name := "odu_" + runtime.GOOS + "_" + runtime.GOARCH
	executable, err := filepath.Abs(filepath.Join("..", "priv", name))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-log", "|2", "-protocol_version", "1.0", "-stderr", "disable", "--", "sh", "-c", `printf '%s|%s' "$EX_CMD_SYNTHETIC" "$0"`, secret)
	var input, output, diagnostics bytes.Buffer
	packet := func(tag byte, data []byte) {
		binary.Write(&input, binary.BigEndian, uint32(len(data)+1))
		input.WriteByte(tag)
		input.Write(data)
	}
	entry := []byte("EX_CMD_SYNTHETIC=" + secret)
	var env bytes.Buffer
	binary.Write(&env, binary.BigEndian, uint16(len(entry)))
	env.Write(entry)
	packet(CommandEnv, env.Bytes())
	request := make([]byte, 4)
	binary.BigEndian.PutUint32(request, 1024)
	packet(SendOutput, request)
	packet(CloseInput, nil)
	command.Stdin, command.Stdout, command.Stderr = &input, &output, &diagnostics
	if err := command.Run(); err != nil {
		t.Fatalf("native fixture failed: %T", err)
	}
	if !bytes.Contains(output.Bytes(), []byte(secret+"|"+secret)) {
		t.Fatal("child payload changed")
	}
	if bytes.Contains(diagnostics.Bytes(), []byte(secret)) {
		t.Fatal("native diagnostics exposed private values")
	}
	if !strings.Contains(diagnostics.String(), "environment entries: 1 (values redacted)") {
		t.Fatal("optional logger not exercised")
	}
}
